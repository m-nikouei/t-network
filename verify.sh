#!/bin/bash
# Prove the seal holds on the host. Host-side checks are automated; a few must be
# run by you inside jobs-vm (printed at the end as a copy-paste block).
#   sudo ./verify.sh              # non-disruptive checks
#   sudo ./verify.sh --killswitch # also stops tor briefly to confirm fail-closed
set -uo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo $0)"; exit 1; }

BRIDGE="virbr-jobs"
BRIDGE_IP="10.13.13.1"

PASS=0; FAIL=0
ok(){ printf '  \033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "[1] host network plane"
ip -o link show "$BRIDGE" >/dev/null 2>&1 \
  && ok "bridge $BRIDGE exists" || no "bridge $BRIDGE missing"
ip -4 -o addr show "$BRIDGE" 2>/dev/null | grep -q "$BRIDGE_IP" \
  && ok "$BRIDGE has $BRIDGE_IP" || no "$BRIDGE missing $BRIDGE_IP"
ss -ltn "sport = :9040" 2>/dev/null | grep -q "$BRIDGE_IP:9040" \
  && ok "tor TransPort listening on $BRIDGE_IP:9040" \
  || no "tor TransPort not listening on $BRIDGE_IP:9040"
ss -lun "sport = :5300" 2>/dev/null | grep -q "$BRIDGE_IP:5300" \
  && ok "tor DNSPort listening on $BRIDGE_IP:5300" \
  || no "tor DNSPort not listening on $BRIDGE_IP:5300"

echo "[2] nftables kill-switch"
if nft list table inet ks >/dev/null 2>&1; then
  ok "table inet ks loaded"
  nft -a list chain inet ks forward | grep -q 'policy drop' \
    && ok "forward chain policy drop" || no "forward chain NOT policy drop (LEAK!)"
  nft list chain inet ks forward | grep -q 'oifname "wg0" meta mark 0x2 accept' \
    && ok "wg0 marked-UDP accept rule present" \
    || no "wg0 marked-UDP accept rule missing"
  nft list chain inet ks nat_pre | grep -q 'redirect to :9040' \
    && ok "TCP -> tor redirect rule present" \
    || no "TCP -> tor redirect rule missing"
else
  no "table inet ks NOT loaded (firewall is not protecting the VM)"
fi

echo "[3] policy routing"
ip rule | grep -q 'fwmark 0x2.*lookup 200' \
  && ok "fwmark 0x2 -> table 200" || no "fwmark rule missing"
ip route show table 200 2>/dev/null | grep -q '^default dev wg0' \
  && ok "table 200 default via wg0" || no "table 200 default route missing"
ip route show table 200 2>/dev/null | grep -q 'blackhole default' \
  && ok "table 200 blackhole fallback present" \
  || no "table 200 blackhole fallback missing (UDP could leak if wg0 down)"

echo "[4] wireguard"
if wg show wg0 latest-handshakes 2>/dev/null | awk '{if ($2+0 > 0) found=1} END{exit found?0:1}'; then
  age=$(wg show wg0 latest-handshakes | awk '{print systime()-$2; exit}')
  if [ "$age" -lt 300 ]; then ok "wg0 handshake $age s ago"
  else no "wg0 handshake stale ($age s — Proton free server retired?)"; fi
else
  no "no wg0 handshake yet (placeholder wg0.conf? wg-quick@wg0 not started?)"
fi

echo "[5] libvirt"
virsh net-info jobs-net 2>/dev/null | grep -q 'Active: *yes' \
  && ok "libvirt network jobs-net active" || no "jobs-net not active"
if virsh dominfo jobs-vm >/dev/null 2>&1; then
  ok "jobs-vm defined"
  ifs=$(virsh dumpxml jobs-vm 2>/dev/null | grep -c '<interface ')
  [ "$ifs" -eq 1 ] && ok "jobs-vm has exactly 1 NIC" \
                   || no "jobs-vm has $ifs NICs (must be 1)"
  if virsh dumpxml jobs-vm 2>/dev/null | grep -q "source network='jobs-net'"; then
    ok "jobs-vm NIC bound to jobs-net"
  else
    no "jobs-vm NIC NOT bound to jobs-net (LEAK PATH)"
  fi
else
  no "jobs-vm not defined yet (build it: sudo SSH_PUBKEY=... ./jobs-vm.sh)"
fi

echo "[6] sysctl"
[ "$(sysctl -n net.ipv4.ip_forward)" = 1 ] && ok "ip_forward=1" || no "ip_forward != 1"
[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" = 1 ] \
  && ok "IPv6 disabled" || no "IPv6 NOT disabled (potential leak path)"

if [ "${1:-}" = "--killswitch" ]; then
  echo "[7] kill-switch: stop tor, the redirect target disappears"
  systemctl stop tor@default
  sleep 2
  if ss -ltn | grep -q "$BRIDGE_IP:9040"; then
    no "tor STILL listening after stop (something is wrong)"
  else
    ok "tor port closed; any VM TCP REDIRECT now lands on a closed port"
  fi
  systemctl start tor@default
  sleep 3
  ss -ltn | grep -q "$BRIDGE_IP:9040" \
    && ok "tor restored" || no "tor failed to restart — check journalctl -u tor@default"
fi

cat <<'EOM'

--- Run these INSIDE jobs-vm (ssh ops@10.13.13.10) ---
  # TCP via Tor (should print {"IsTor":true,"IP":"..."})
  curl -s https://check.torproject.org/api/ip

  # UDP via ProtonVPN (should report the Proton IP, distinct from the Tor exit)
  curl --http3-only -s https://cloudflare-quic.com/ | head

  # DNS via Tor
  getent hosts example.com

  # No route to your real IP / LAN (every line MUST fail or time out)
  ping -c2 -W2 192.168.1.1
  nmap -sn 192.168.1.0/24       # discovers nothing
  ip neigh                       # only 10.13.13.1

  # The data share is writable; results land on the host at /var/jobs/share/out
  echo hello > /mnt/share/out/marker && ls -l /mnt/share/out/marker

EOM

echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
