#!/bin/bash
# Prove the seal holds. RUN IN dom0 after wg0.conf is installed.
#   ./verify.sh              # non-disruptive checks
#   ./verify.sh --killswitch # also drops Tor briefly to confirm fail-closed
set -uo pipefail
AGENT=agent-vm
PROXY=sys-split
PASS=0; FAIL=0
ok(){ printf '  \033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
ina(){ qvm-run --pass-io "$AGENT" "$1" 2>/dev/null; }

echo "[1] TCP egress is Tor"
if ina 'curl -s --max-time 30 https://check.torproject.org/api/ip' | grep -q '"IsTor":true'; then
  ok "check.torproject.org reports IsTor:true"
else no "Tor not confirmed (TCP tunnel down?)"; fi

echo "[2] Home/LAN is unreachable from the agent"
reached=""
for ip in 192.168.1.1 192.168.0.1 10.0.0.1 172.16.0.1; do
  ina "ping -c1 -W2 $ip" >/dev/null 2>&1 && reached="$reached $ip"
done
[ -z "$reached" ] && ok "no RFC1918 host reachable" || no "agent reached private address(es):$reached"

echo "[3] DNS resolves (via Tor)"
ina 'getent hosts example.com' >/dev/null 2>&1 && ok "name resolution works" || no "DNS broken"

echo "[4] UDP path up (WireGuard handshake present)"
if qvm-run --pass-io -u root "$PROXY" 'wg show wg0 latest-handshakes' 2>/dev/null \
     | awk '{if ($2+0 > 0) found=1} END{exit found?0:1}'; then
  ok "WireGuard has a recent handshake"
else no "no WireGuard handshake (UDP/Proton path down — install wg0.conf?)"; fi

if [ "${1:-}" = "--killswitch" ]; then
  echo "[5] kill-switch: stop Tor, agent TCP must fail"
  qvm-run -u root "$PROXY" 'pkill -u debian-tor tor' 2>/dev/null || true
  sleep 2
  if ina 'curl -s --max-time 10 https://example.com' >/dev/null 2>&1; then
    no "agent STILL had TCP egress with Tor down (LEAK!)"
  else ok "TCP blocked while Tor down (fail-closed)"; fi
  qvm-run -u root "$PROXY" 'sudo -u debian-tor tor -f /rw/config/torrc --runasdaemon 1' 2>/dev/null || true
fi

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
