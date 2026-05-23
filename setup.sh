#!/bin/bash
# Provision the fail-closed split-tunnel system on Qubes OS. RUN IN dom0.
# Idempotent: safe to re-run. Does NOT install Qubes itself or fetch the Proton config.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/salt/t-network/files" && pwd)"
SPLIT_TPL=t-split
PROXY=sys-split
AGENT=agent-vm
VAULT=agent-out
STAGE=agent-staging

say(){ printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
exists(){ qvm-check --quiet "$1" >/dev/null 2>&1; }
# push <localfile> <vm> <destpath> <mode>  — write a dom0 file into a qube as root
push(){ qvm-run --pass-io -u root "$2" "cat > '$3'" < "$1"; qvm-run -u root "$2" "chmod $4 '$3'"; }

say "1/7  proxy template ($SPLIT_TPL)"
exists "$SPLIT_TPL" || qvm-clone debian-12 "$SPLIT_TPL"

say "2/7  install tor/wireguard/nftables into $SPLIT_TPL"
qvm-run -u root "$SPLIT_TPL" 'apt-get -q update && DEBIAN_FRONTEND=noninteractive apt-get -y install tor wireguard nftables && systemctl disable tor'
qvm-shutdown --wait "$SPLIT_TPL" || true

say "3/7  proxy qube ($PROXY) + /rw/config"
exists "$PROXY" || qvm-create --class AppVM --template "$SPLIT_TPL" --label red "$PROXY"
qvm-prefs "$PROXY" provides_network True
qvm-prefs "$PROXY" netvm sys-firewall
qvm-prefs "$PROXY" maxmem 1024
qvm-prefs "$PROXY" memory 600
qvm-start --skip-if-running "$PROXY"
push "$SRC/torrc"                      "$PROXY" /rw/config/torrc 644
push "$SRC/rc.local"                   "$PROXY" /rw/config/rc.local 755
push "$SRC/qubes-firewall-user-script" "$PROXY" /rw/config/qubes-firewall-user-script 755
if ! qvm-run -u root "$PROXY" 'test -s /rw/config/wg0.conf' 2>/dev/null; then
  push "$SRC/wg0.conf.template" "$PROXY" /rw/config/wg0.conf 600
  WG_PLACEHOLDER=1
fi

say "4/7  untrusted agent ($AGENT)"
exists "$AGENT" || qvm-create --class AppVM --template debian-12 --label orange "$AGENT"
qvm-prefs "$AGENT" netvm "$PROXY"

say "5/7  offline vault ($VAULT) + staging ($STAGE)"
exists "$VAULT" || qvm-create --class AppVM --template debian-12 --label black "$VAULT"
qvm-prefs "$VAULT" netvm ''
exists "$STAGE" || qvm-create --class AppVM --template debian-12 --label gray "$STAGE"
qvm-prefs "$STAGE" netvm ''

say "6/7  dom0 qrexec data policy"
sudo cp "$SRC/30-agent-data.policy" /etc/qubes/policy.d/30-agent-data.policy

say "7/7  restart proxy to load the firewall"
qvm-shutdown --wait "$PROXY" || true
qvm-start "$PROXY"

if [ "${WG_PLACEHOLDER:-0}" = 1 ]; then
  cat <<EOM

  !!! ACTION REQUIRED — ProtonVPN secret not installed yet (placeholder in place).
   1. account.protonvpn.com -> Downloads -> WireGuard configuration (free server).
   2. Edit it: add 'Table = off'; delete any 'DNS =' line.
   3. qvm-copy-to-vm $PROXY wg0.conf   # then in $PROXY: sudo mv it to /rw/config/wg0.conf && sudo chmod 600 /rw/config/wg0.conf
   4. qvm-shutdown --wait $PROXY && qvm-start $PROXY
  Until then the proxy stays fail-closed (it never matches a real endpoint).
EOM
fi
say "Done. After wg0.conf is in place, run ./verify.sh   (add --killswitch for the full test)."
