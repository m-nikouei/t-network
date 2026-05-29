#!/bin/bash
# Provision the identity-sealed job-runner host plane on Ubuntu.
# TCP/DNS -> Tor, UDP -> ProtonVPN, fail-closed kill-switch.
# Idempotent: safe to re-run. Does NOT install Ubuntu, fetch the Proton config,
# or build the job VM (use jobs-vm.sh for the VM).
#
# Requires: Ubuntu Server LTS (or similar), root.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo $0)"; exit 1; }

UPLINK="${UPLINK:-eth0}"        # override: UPLINK=wlan0 ./setup.sh
BRIDGE="virbr-jobs"
BRIDGE_NET="10.13.13.0/24"
BRIDGE_IP="10.13.13.1"
JOBS_IP="10.13.13.10"
JOBS_ROOT="/var/jobs"

say(){ printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m!! %s\033[0m\n' "$*"; }

say "1/8  packages"
export DEBIAN_FRONTEND=noninteractive
apt-get -q update
apt-get -y install \
  tor wireguard wireguard-tools nftables \
  qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients \
  virtinst virtiofsd cloud-image-utils \
  unattended-upgrades curl
systemctl disable --now tor 2>/dev/null || true   # re-enabled with the right ordering below
systemctl mask ufw 2>/dev/null || true
systemctl enable --now unattended-upgrades libvirtd

say "2/8  sysctl (IPv6 off, ip_forward on)"
cat >/etc/sysctl.d/60-jobs-host.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null

say "3/8  tor: TransPort/DNSPort on $BRIDGE_IP only"
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

say "4/8  wireguard placeholder (if absent or still CHANGE_ME)"
if [ ! -s /etc/wireguard/wg0.conf ]; then
  install -d -m 0700 /etc/wireguard
  cat >/etc/wireguard/wg0.conf <<'EOF'
# PLACEHOLDER — replace with a real ProtonVPN free WireGuard config.
# 1) account.protonvpn.com -> Downloads -> WireGuard configuration (free server)
# 2) Edit: add 'Table = off'; delete any 'DNS =' line; keep a NUMERIC Endpoint
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
fi

# Re-runs are safe before the real Proton config arrives: while CHANGE_ME is present
# we keep the tunnels disabled and the endpoint pinned to 0.0.0.0 (fail-closed).
WG_PLACEHOLDER=0
grep -q 'CHANGE_ME' /etc/wireguard/wg0.conf && WG_PLACEHOLDER=1

# Pin the firewall to the numeric endpoint from wg0.conf.
WG_EP_LINE="$(awk -F'= *' '/^Endpoint/ {print $2; exit}' /etc/wireguard/wg0.conf | tr -d ' ')"
WG_EP_IP="${WG_EP_LINE%:*}"
WG_EP_PORT="${WG_EP_LINE##*:}"
: "${WG_EP_PORT:=51820}"

say "5/8  policy-route service (fwmark 0x2 -> table 200 -> wg0 / blackhole)"
cat >/etc/systemd/system/jobs-mark-route.service <<'EOF'
[Unit]
Description=Policy routing for job-VM-marked UDP via wg0
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
systemctl enable jobs-mark-route.service

say "6/8  libvirt network 'jobs-net' (bridge $BRIDGE, $BRIDGE_NET, forward=open)"
mkdir -p /etc/libvirt/qemu/networks
cat >/etc/libvirt/qemu/networks/jobs-net.xml <<EOF
<network>
  <name>jobs-net</name>
  <forward mode='open'/>
  <bridge name='$BRIDGE' stp='off' delay='0'/>
  <ip address='$BRIDGE_IP' netmask='255.255.255.0'>
    <dhcp>
      <range start='$JOBS_IP' end='$JOBS_IP'/>
    </dhcp>
  </ip>
</network>
EOF
if ! virsh net-info jobs-net >/dev/null 2>&1; then
  virsh net-define /etc/libvirt/qemu/networks/jobs-net.xml
fi
virsh net-autostart jobs-net >/dev/null
virsh net-start jobs-net 2>/dev/null || true

say "7/8  nftables kill-switch (table inet ks)"
mkdir -p /etc/nftables.d
cat >/etc/nftables.d/jobs-killswitch.nft <<EOF
#!/usr/sbin/nft -f
table inet ks
delete table inet ks
table inet ks {
    define BRIDGE = "$BRIDGE"
    define UPLINK = "$UPLINK"
    define VPN_ENDPOINT = $WG_EP_IP
    define VPN_PORT     = $WG_EP_PORT

    # Mark all VM UDP (except DNS) for fwmark routing into wg0.
    chain premark {
        type filter hook prerouting priority -150; policy accept;
        iifname \$BRIDGE udp dport != 53 meta mark set 0x2
    }
    # Transparent redirect: VM TCP -> local Tor; DNS -> Tor DNSPort.
    chain nat_pre {
        type nat hook prerouting priority -150; policy accept;
        iifname \$BRIDGE tcp dport 53 redirect to :5300
        iifname \$BRIDGE udp dport 53 redirect to :5300
        iifname \$BRIDGE meta l4proto tcp redirect to :9040
    }
    # VM -> host: only the Tor ports on the bridge IP; everything else from the VM dropped.
    chain input {
        type filter hook input priority 0; policy accept;
        iifname \$BRIDGE tcp dport { 9040, 5300 } accept
        iifname \$BRIDGE udp dport 5300 accept
        iifname \$BRIDGE ct state established,related accept
        iifname \$BRIDGE drop
    }
    # Forward: default drop. Only marked UDP onto wg0 is allowed out.
    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept
        ct state invalid drop
        iifname \$BRIDGE oifname "wg0" meta mark 0x2 accept
    }
    # SNAT VM UDP onto wg0's address so Proton accepts it and replies route back.
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "wg0" masquerade
    }
}
EOF

# Idempotently include the kill-switch from the main nftables.conf
if ! grep -qF 'jobs-killswitch.nft' /etc/nftables.conf 2>/dev/null; then
  printf '\n# Job-runner kill-switch\ninclude "/etc/nftables.d/jobs-killswitch.nft"\n' >> /etc/nftables.conf
fi
systemctl enable --now nftables
systemctl reload nftables 2>/dev/null || systemctl restart nftables

say "8/8  service ordering + host dirs"
mkdir -p /etc/systemd/system/tor@default.service.d
cat >/etc/systemd/system/tor@default.service.d/wait-for-bridge.conf <<'EOF'
[Unit]
After=libvirtd.service jobs-mark-route.service
Requires=libvirtd.service
EOF
systemctl daemon-reload
if [ "$WG_PLACEHOLDER" -eq 0 ]; then
  systemctl enable --now wg-quick@wg0
  systemctl enable --now tor@default
else
  warn "wg0.conf is a placeholder — leaving wg-quick@wg0 and tor@default DISABLED."
fi

# Host-owned share + image dirs. /var/jobs/share is the data path; you pull from it
# over the LAN. libvirt-qemu must own them so virtiofsd/the VM can read+write.
install -d -m 0750 -o libvirt-qemu -g kvm "$JOBS_ROOT"/{images,share,share/in,share/out}

if [ "$WG_PLACEHOLDER" -eq 1 ]; then
  cat <<EOM

  !!! ACTION REQUIRED — ProtonVPN secret not installed yet (placeholder in place).
   1. account.protonvpn.com -> Downloads -> WireGuard configuration (free server).
   2. Edit it: add 'Table = off'; delete any 'DNS =' line; keep a NUMERIC Endpoint.
   3. sudo install -m 600 -o root -g root <downloaded>.conf /etc/wireguard/wg0.conf
   4. sudo ./setup.sh    # re-run; nftables endpoint pin + tunnels come up.
  Until then the host stays fail-closed (the firewall pins to 0.0.0.0:51820).
EOM
fi

cat <<EOM

  Host plane ready. Next:
    sudo SSH_PUBKEY="\$(cat ~/.ssh/id_ed25519.pub)" DISK=400G ./jobs-vm.sh   # build the VM
    sudo ./verify.sh            # prove the seal (add --killswitch for the disruptive test)
EOM
