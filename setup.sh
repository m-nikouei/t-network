#!/bin/bash
# Provision the fail-closed split-tunnel system on an Ubuntu host.
# Idempotent: safe to re-run. Does NOT install Ubuntu itself, fetch the Proton
# config, or build the agent/triage guest VMs (those steps are interactive —
# the script prints the virt-install commands at the end).
#
# Requires: Ubuntu 26.04 LTS Server (or similar), root.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo $0)"; exit 1; }

UPLINK="${UPLINK:-eth0}"        # override: UPLINK=wlan0 ./setup.sh
BRIDGE="virbr-agent"
BRIDGE_NET="10.13.13.0/24"
BRIDGE_IP="10.13.13.1"
AGENT_IP="10.13.13.10"
AGENT_ROOT="/var/agent"

say(){ printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m!! %s\033[0m\n' "$*"; }

say "1/9  packages"
export DEBIAN_FRONTEND=noninteractive
apt-get -q update
apt-get -y install \
  tor wireguard wireguard-tools nftables \
  qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients \
  virtinst virt-manager ovmf swtpm virtiofsd \
  apparmor apparmor-utils unattended-upgrades
systemctl disable --now tor 2>/dev/null || true   # we re-enable with the right ordering
systemctl mask ufw 2>/dev/null || true
systemctl enable --now apparmor unattended-upgrades libvirtd

say "2/9  sysctl (IPv6 off, ip_forward on)"
cat >/etc/sysctl.d/60-agent-host.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null

say "3/9  tor: TransPort/DNSPort on $BRIDGE_IP only"
cat >/etc/tor/torrc <<EOF
User debian-tor
DataDirectory /var/lib/tor
SocksPort 0
TransPort $BRIDGE_IP:9040
DNSPort   $BRIDGE_IP:5300
AutomapHostsOnResolve 1
VirtualAddrNetworkIPv4 10.192.0.0/10
ExitRelay 0
ClientOnly 1
EOF

say "4/9  wireguard placeholder (if absent)"
WG_PLACEHOLDER=0
if [ ! -s /etc/wireguard/wg0.conf ]; then
  install -d -m 0700 /etc/wireguard
  cat >/etc/wireguard/wg0.conf <<'EOF'
# PLACEHOLDER — replace with a real ProtonVPN free WireGuard config.
# 1) account.protonvpn.com -> Downloads -> WireGuard configuration (free server)
# 2) Edit: add 'Table = off'; delete any 'DNS =' line; keep numeric Endpoint
# 3) sudo install -m 600 -o root -g root <downloaded>.conf /etc/wireguard/wg0.conf
[Interface]
PrivateKey = CHANGE_ME
Address = 10.2.0.2/32
Table = off

[Peer]
PublicKey = CHANGE_ME
AllowedIPs = 0.0.0.0/0
Endpoint = 0.0.0.0:51820
EOF
  chmod 600 /etc/wireguard/wg0.conf
  WG_PLACEHOLDER=1
fi

# Pull the numeric endpoint out of wg0.conf so the nftables rule pins to it.
WG_EP_LINE="$(awk -F'= *' '/^Endpoint/ {print $2; exit}' /etc/wireguard/wg0.conf | tr -d ' ')"
WG_EP_IP="${WG_EP_LINE%:*}"
WG_EP_PORT="${WG_EP_LINE##*:}"
: "${WG_EP_PORT:=51820}"

say "5/9  policy-route service (fwmark 0x2 -> table 200 -> wg0 / blackhole)"
cat >/etc/systemd/system/agent-mark-route.service <<'EOF'
[Unit]
Description=Policy routing for agent-marked UDP via wg0
After=wg-quick@wg0.service
Requires=wg-quick@wg0.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ip rule add fwmark 0x2 table 200
ExecStart=/usr/sbin/ip route replace default dev wg0 table 200
ExecStart=/usr/sbin/ip route add blackhole default metric 1000 table 200
ExecStop=/usr/sbin/ip route flush table 200
ExecStop=/usr/sbin/ip rule del fwmark 0x2 table 200

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable agent-mark-route.service

say "6/9  libvirt network 'agent-net' (bridge $BRIDGE, $BRIDGE_NET, forward=open)"
mkdir -p /etc/libvirt/qemu/networks
cat >/etc/libvirt/qemu/networks/agent-net.xml <<EOF
<network>
  <name>agent-net</name>
  <forward mode='open'/>
  <bridge name='$BRIDGE' stp='off' delay='0'/>
  <ip address='$BRIDGE_IP' netmask='255.255.255.0'>
    <dhcp>
      <range start='$AGENT_IP' end='$AGENT_IP'/>
    </dhcp>
  </ip>
</network>
EOF
if ! virsh net-info agent-net >/dev/null 2>&1; then
  virsh net-define /etc/libvirt/qemu/networks/agent-net.xml
fi
virsh net-autostart agent-net >/dev/null
virsh net-start agent-net 2>/dev/null || true

say "7/9  nftables kill-switch (table inet ks)"
mkdir -p /etc/nftables.d
cat >/etc/nftables.d/agent-killswitch.nft <<EOF
#!/usr/sbin/nft -f
table inet ks
delete table inet ks
table inet ks {
    define BRIDGE = "$BRIDGE"
    define UPLINK = "$UPLINK"
    define VPN_ENDPOINT = $WG_EP_IP
    define VPN_PORT     = $WG_EP_PORT
    define LAN_BLOCK = {
        10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
        100.64.0.0/10, 169.254.0.0/16, 224.0.0.0/4
    }

    chain premark {
        type filter hook prerouting priority -150; policy accept;
        iifname \$BRIDGE udp dport != 53 meta mark set 0x2
    }
    chain nat_pre {
        type nat hook prerouting priority -150; policy accept;
        iifname \$BRIDGE tcp dport 53 redirect to :5300
        iifname \$BRIDGE udp dport 53 redirect to :5300
        iifname \$BRIDGE meta l4proto tcp redirect to :9040
    }
    chain input {
        type filter hook input priority 0; policy accept;
        iifname \$BRIDGE tcp dport { 9040, 5300 } accept
        iifname \$BRIDGE udp dport 5300 accept
        iifname \$BRIDGE ct state established,related accept
        iifname \$BRIDGE drop
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept
        ct state invalid drop
        iifname \$BRIDGE ip daddr \$LAN_BLOCK drop
        iifname \$BRIDGE oifname "wg0" meta mark 0x2 accept
    }
    chain output {
        type filter hook output priority 0; policy accept;
        oifname \$UPLINK ip daddr \$VPN_ENDPOINT udp dport \$VPN_PORT accept
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "wg0" masquerade
    }
}
EOF

# Idempotently include the kill-switch from the main nftables.conf
if ! grep -qF 'agent-killswitch.nft' /etc/nftables.conf 2>/dev/null; then
  printf '\n# Agent kill-switch\ninclude "/etc/nftables.d/agent-killswitch.nft"\n' >> /etc/nftables.conf
fi
systemctl enable --now nftables
systemctl reload nftables 2>/dev/null || systemctl restart nftables

say "8/9  service ordering: tor waits for libvirtd + the policy route"
mkdir -p /etc/systemd/system/tor@default.service.d
cat >/etc/systemd/system/tor@default.service.d/wait-for-bridge.conf <<'EOF'
[Unit]
After=libvirtd.service agent-mark-route.service
Requires=libvirtd.service
EOF
systemctl daemon-reload
if [ "$WG_PLACEHOLDER" -eq 0 ]; then
  systemctl enable --now wg-quick@wg0
  systemctl enable --now tor@default
else
  warn "wg0.conf is a placeholder — leaving wg-quick@wg0 and tor@default DISABLED."
  warn "Install the real config (see action items below), then re-run this script."
fi

say "9/9  host directory layout for shares"
install -d -m 0750 -o libvirt-qemu -g kvm "$AGENT_ROOT"/{images,seeds,shares/in,shares/out,shares/clean}
# /mnt/in inside the guest is read-only because we declare <readonly/> in the libvirt
# definition — but make the host-side mode reflect the same intent (agent UID can't write).
chmod 0755 "$AGENT_ROOT/shares/in"
chmod 0775 "$AGENT_ROOT/shares/out" "$AGENT_ROOT/shares/clean"

if [ "$WG_PLACEHOLDER" -eq 1 ]; then
  cat <<EOM

  !!! ACTION REQUIRED — ProtonVPN secret not installed yet (placeholder in place).
   1. account.protonvpn.com -> Downloads -> WireGuard configuration (free server).
   2. Edit it: add 'Table = off'; delete any 'DNS =' line; keep a NUMERIC Endpoint.
   3. sudo install -m 600 -o root -g root <downloaded>.conf /etc/wireguard/wg0.conf
   4. sudo ./setup.sh    # re-run; nftables endpoint pin + services come up.
  Until then the host stays fail-closed (the firewall pins to 0.0.0.0:51820).
EOM
fi

cat <<EOM

  Next: build the guest VMs (interactive — Debian netinst). Place the ISO at
  $AGENT_ROOT/seeds/agent-debian-13.iso first, then:

  agent VM:
    qemu-img create -f qcow2 $AGENT_ROOT/images/agent.qcow2 20G
    virt-install --name agent-vm \\
      --memory 4096 --vcpus 2 --machine q35 --boot uefi --osinfo debian13 \\
      --disk path=$AGENT_ROOT/images/agent.qcow2,format=qcow2,bus=virtio,discard=unmap \\
      --cdrom $AGENT_ROOT/seeds/agent-debian-13.iso \\
      --network network=agent-net,model=virtio \\
      --memorybacking source.type=memfd,access.mode=shared \\
      --controller type=virtio-serial \\
      --rng /dev/urandom \\
      --graphics spice,clipboard.copypaste=no,filetransfer.enable=no \\
      --noautoconsole

  After install: detach the ISO, 'virsh edit agent-vm' to add the two virtio-fs
  shares (see README §7c), and lock down the guest interior per README §7d.

  triage VM (no network):
    qemu-img create -f qcow2 $AGENT_ROOT/images/triage.qcow2 10G
    virt-install --name triage-vm \\
      --memory 2048 --vcpus 2 --machine q35 --boot uefi --osinfo debian13 \\
      --disk path=$AGENT_ROOT/images/triage.qcow2,format=qcow2,bus=virtio \\
      --cdrom $AGENT_ROOT/seeds/agent-debian-13.iso \\
      --network none \\
      --memorybacking source.type=memfd,access.mode=shared \\
      --graphics spice,clipboard.copypaste=no,filetransfer.enable=no \\
      --noautoconsole

  Then: sudo ./verify.sh   (add --killswitch for the disruptive test)
EOM
