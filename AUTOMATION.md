# Automating the build

Two ways to provision the system from [README.md](README.md). Use the **bash script** for
a fast first build; keep the **Salt formulas** as the reproducible source of truth.

```
setup.sh                       # dom0 bash provisioner (imperative, idempotent)
verify.sh                      # dom0 self-test (asserts the seal holds)
salt/t-network/
  dom0.sls                     # qubes + prefs + qrexec policy (apply in dom0)
  pkgs.sls                     # template packages (apply inside t-split)
  config.sls                   # /rw/config files (apply inside sys-split)
  files/                       # shared payloads (used by BOTH script and Salt)
    torrc  rc.local  qubes-firewall-user-script  wg0.conf.template  30-agent-data.policy
```

## Manual prerequisites (cannot/should not be automated)
1. **Install Qubes OS 4.3** on the wiped laptop and finish the first-boot wizard; update
   dom0 and templates. (Qube creation is automated; the OS install is not.)
2. **Download the ProtonVPN free WireGuard config** (web login) — this is the one secret.
   It is never stored in the repo or in Salt; you install it by hand (see below).

## Path A — bash script (quick first build)
Get this folder into **dom0** (e.g. from a qube: `qvm-run --pass-io <qube> 'cat t-network.tar' > t-network.tar` then untar). Review it — pulling code into dom0 is a trust decision.
```bash
chmod +x setup.sh verify.sh
./setup.sh
```
It clones `t-split`, installs packages, creates `sys-split` / `agent-vm` / `agent-out` /
`agent-staging`, pushes the `/rw/config` files, and writes the dom0 policy. It then prints
the **ACTION REQUIRED** steps to install your `wg0.conf`. After that:
```bash
./verify.sh --killswitch
```

## Path B — Salt / qubesctl (reproducible rebuilds)
Copy the formula tree into dom0's user-salt root, then apply in order:
```bash
sudo cp -r salt/t-network /srv/user_salt/

qvm-clone debian-13-xfce t-split                                         # one-time prereq
sudo qubesctl --skip-dom0 --targets=t-split  state.apply t-network.pkgs  # template pkgs
qvm-shutdown --wait t-split

sudo qubesctl state.apply t-network.dom0                                 # qubes + policy
sudo qubesctl --skip-dom0 --targets=sys-split state.apply t-network.config  # /rw config
qvm-shutdown --wait sys-split && qvm-start sys-split
```
Re-running any of these is idempotent — that's the point of keeping Salt.

## Installing the secret (`wg0.conf`) — both paths
```bash
# author/edit it in the OFFLINE staging qube, then:
qvm-copy-to-vm sys-split wg0.conf
# in sys-split:
sudo mv ~/QubesIncoming/agent-staging/wg0.conf /rw/config/wg0.conf
sudo chmod 600 /rw/config/wg0.conf
# restart so the firewall reads the endpoint and the tunnel comes up:
qvm-shutdown --wait sys-split   # (from dom0) then qvm-start sys-split
```
The firewall script **auto-derives `VPN_ENDPOINT`/`VPN_PORT` from `wg0.conf`**, so there is
nothing else to wire. Until a real config is present, the proxy stays fail-closed.

## What the self-test checks (`verify.sh`)
- TCP egress is Tor (`check.torproject.org` → `IsTor:true`)
- The agent cannot reach any RFC1918 / home-LAN address
- DNS resolves (through Tor)
- WireGuard has a live handshake (UDP/Proton path is up)
- `--killswitch`: dropping Tor blocks the agent's TCP (no clearnet fallback)

Exit code is non-zero if any check fails, so it slots into a post-build gate.

## Notes
- **Secrets:** only `wg0.conf` is sensitive; keep it out of git and out of Salt.
- **Re-running:** both paths are safe to re-run; Salt is fully declarative, the script is
  guarded with existence checks.
- **Feeding the agent / extracting data:** see README §8 — `qvm-copy` over qrexec only.
