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

say "2/8  sysctl + conntrack (IPv6 off, ip_forward on, high-concurrency tuning)"
# The host NATs/redirects every TCP connection the VM opens, so a high-concurrency
# workload (crawler/scraper: many short connections) is bounded by the conntrack table,
# the ephemeral port range, and open file descriptors. Tune all three.
echo nf_conntrack >/etc/modules-load.d/nf_conntrack.conf
modprobe nf_conntrack 2>/dev/null || true
echo 'options nf_conntrack hashsize=262144' >/etc/modprobe.d/nf_conntrack.conf
cat >/etc/sysctl.d/60-jobs-host.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv4.ip_forward = 1
# High-concurrency (many short-lived connections) tuning:
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
fs.file-max = 2097152
EOF
sysctl --system >/dev/null

say "3/8  tor: TransPort/DNSPort on $BRIDGE_IP only (+ high-concurrency conn limits)"
cat >/etc/tor/torrc <<EOF
User debian-tor
DataDirectory /var/lib/tor
# SOCKS5 for app-aware proxying (qBittorrent peer/tracker connections). Bound to the
# bridge IP only (jobs-net reachable, not external). NO per-destination isolation:
# IsolateDestAddr/DestPort forces a separate circuit per peer, which churns and drops
# BitTorrent's many short connections before the metadata/handshake completes. Default
# (shared circuits) is what works for BT — matches a standard desktop Tor SOCKS setup.
SocksPort $BRIDGE_IP:9050
TransPort $BRIDGE_IP:9040
DNSPort   $BRIDGE_IP:5300
# ControlPort for the host dashboard (circuit view + NEWNYM exit rotation). Local only,
# cookie auth. The dashboard user must be in the 'debian-tor' group to read the cookie
# at /run/tor/control.authcookie. Kept here so re-running setup.sh doesn't drop it.
ControlPort 127.0.0.1:9051
CookieAuthentication 1
AutomapHostsOnResolve 1
VirtualAddrNetworkIPv4 10.192.0.0/10
ExitRelay 0
ClientOnly 1
# Many concurrent streams from the workload: raise the fd/conn ceiling (default 1000)
# and let more circuits build in parallel. LimitNOFILE is bumped in the unit (step 8).
ConnLimit 8192
MaxClientCircuitsPending 128
# Your exit IP rotates when Tor retires a dirty circuit (default 600s). For a scraper that
# means the source IP changes ~every 10 min. Raise to pin an IP longer, lower to rotate
# faster (e.g. to spread across rate limits):
# MaxCircuitDirtiness 600
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

say "5/8  policy-route service + watchdog (fwmark 0x2 -> table 200 -> wg0 / blackhole)"

# Idempotent reconciler — (re)asserts the marked-UDP policy route into wg0 with a
# fail-closed blackhole fallback. Safe to run repeatedly; used by BOTH the oneshot
# service and the watchdog timer below so the rule self-heals if the kernel ever loses
# it WITHOUT a wg0 restart. (Observed failure: the oneshot showed active/exited while the
# fwmark rule was gone from the kernel, so every VM UDP/DHT/tracker packet fell to the
# uplink route, missed the wg0-only accept, and was silently dropped by the kill-switch.)
install -m 755 /dev/stdin /usr/local/sbin/jobs-mark-route <<'EOF'
#!/bin/sh
# Re-assert fwmark 0x2 -> table 200 (default via wg0) with a blackhole fail-closed route.
ip rule list | grep -q 'fwmark 0x2 lookup 200' || ip rule add fwmark 0x2 table 200
ip route replace blackhole default metric 1000 table 200
# Only (re)install the wg0 default while the interface exists; when wg0 is down the kernel
# drops its routes and the lower-priority blackhole keeps marked UDP fail-closed (no leak).
if ip link show wg0 >/dev/null 2>&1; then
    ip route replace default dev wg0 table 200
fi
EOF

cat >/etc/systemd/system/jobs-mark-route.service <<'EOF'
[Unit]
Description=Policy routing for job-VM-marked UDP via wg0
After=wg-quick@wg0.service
Wants=wg-quick@wg0.service
# PartOf: a wg0 restart (VPN reconnect) restarts this unit too, re-applying the rule.
PartOf=wg-quick@wg0.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/jobs-mark-route
ExecStop=/usr/sbin/ip route flush table 200
ExecStop=-/usr/sbin/ip rule del fwmark 0x2 table 200

[Install]
WantedBy=multi-user.target
EOF

# Watchdog: re-assert the rule every 30s so a silent loss self-heals within seconds —
# the oneshot's RemainAfterExit cannot detect an externally-removed kernel rule.
cat >/etc/systemd/system/jobs-mark-route-watchdog.service <<'EOF'
[Unit]
Description=Re-assert job-VM marked-UDP policy route (watchdog)
After=jobs-mark-route.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/jobs-mark-route
EOF

cat >/etc/systemd/system/jobs-mark-route-watchdog.timer <<'EOF'
[Unit]
Description=Periodically re-assert job-VM marked-UDP policy route

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable jobs-mark-route.service
systemctl enable jobs-mark-route-watchdog.timer

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
        iifname \$BRIDGE udp dport != 53 counter meta mark set 0x2
    }
    # Transparent redirect: VM TCP -> local Tor; DNS -> Tor DNSPort.
    chain nat_pre {
        type nat hook prerouting priority -150; policy accept;
        iifname \$BRIDGE tcp dport 53 redirect to :5300
        iifname \$BRIDGE udp dport 53 redirect to :5300
        # Host-local traffic (VM -> Tor SOCKS/Trans/DNS on the bridge IP) must NOT be
        # redirected into TransPort, or the SOCKS5 path would loop back on itself.
        # The input chain still gates exactly which host ports the VM may reach.
        iifname \$BRIDGE ip daddr $BRIDGE_IP accept
        iifname \$BRIDGE meta l4proto tcp counter redirect to :9040
    }
    # VM -> host: DHCP, Tor ports, established replies; everything else from the VM dropped.
    chain input {
        type filter hook input priority 0; policy accept;
        iifname \$BRIDGE udp dport 67 accept
        iifname \$BRIDGE tcp dport { 9040, 9050, 5300 } accept
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
cat >/etc/systemd/system/tor@default.service.d/wait-for-bridge.conf <<EOF
[Unit]
After=libvirtd.service jobs-mark-route.service
Requires=libvirtd.service
# libvirtd reporting "started" does NOT mean the jobs-net bridge ($BRIDGE_IP on
# virbr-jobs) has its address yet — libvirt brings the network up asynchronously.
# So the ExecStartPre wait below is the real guard; here we just give it a patient
# retry window instead of burning 5 tries in ~0.5s and latching into 'failed'.
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
# Match the raised ConnLimit in torrc so Tor can actually open that many sockets.
LimitNOFILE=16384

# torrc binds SocksPort/TransPort/DNSPort to $BRIDGE_IP. If Tor starts before that
# address exists it dies with "Cannot assign requested address". Wait (up to 60s,
# well within the 5min TimeoutStartSec) for the bridge address to appear first.
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 60); do ip -4 -o addr show | grep -qw $BRIDGE_IP && exit 0; sleep 1; done; echo "tor: timed out waiting for $BRIDGE_IP (virbr-jobs)"; exit 1'

# Backstop: if we still lose the race, retry patiently within the window above.
Restart=on-failure
RestartSec=10
EOF
systemctl daemon-reload
if [ "$WG_PLACEHOLDER" -eq 0 ]; then
  systemctl enable --now wg-quick@wg0
  systemctl enable --now tor@default
else
  warn "wg0.conf is a placeholder — leaving wg-quick@wg0 and tor@default DISABLED."
fi

# Host-owned share + image dirs. images/ is private (qemu only). share/in and share/out
# must be writable by the VM's ops user (uid 1000 in the guest maps directly through
# virtiofsd passthrough, appearing as "other" here); mode 0777 lets the guest write
# without knowing the host uid in advance. CRITICAL: share/ itself must be TRAVERSABLE
# by that uid (0755, o+x) — at 0750 the guest can't enter the 0777 in/out subdirs, which
# breaks the loader's access to magnets.json and the output share.
install -d -m 0750 -o libvirt-qemu -g kvm "$JOBS_ROOT"/images
install -d -m 0755 -o libvirt-qemu -g kvm "$JOBS_ROOT"/share
install -d -m 0777 -o libvirt-qemu -g kvm "$JOBS_ROOT"/share/in "$JOBS_ROOT"/share/out

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
    sudo SSH_PUBKEY="\$(cat ~/.ssh/id_ed25519.pub)" DATA_DISK=900G ./jobs-vm.sh   # build VM
    sudo ./verify.sh            # prove the seal (add --killswitch for the disruptive test)
EOM
