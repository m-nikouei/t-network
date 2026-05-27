# Automating the build

Two scripts provision the system from [README.md](README.md):

```
setup.sh    # host bash provisioner (imperative, idempotent) — run as root on Ubuntu
verify.sh   # host self-test (asserts the seal holds) — run as root on Ubuntu
```

There is no Salt / Ansible tree in this repo. The original Qubes design had one
because qubesctl was the right tool there; on a single Ubuntu host, an
idempotent bash script is a smaller TCB and easier to audit. If you want
Ansible later, it's straightforward to lift `setup.sh` into a role.

## Manual prerequisites (cannot/should not be automated)

1. **Install Ubuntu 26.04 LTS Server** on the wiped laptop. Verify the ISO
   checksum, enable full-disk encryption (LUKS2), choose the minimal install,
   and skip every "featured server snap." (OS install is not automated.)
2. **Download the ProtonVPN free WireGuard config** (web login) — this is the
   one secret. It is never stored in the repo; you install it by hand (see
   below).
3. **Download a Debian 13 netinst ISO** for the agent and triage VMs and place
   it at `/var/agent/seeds/agent-debian-13.iso` after `setup.sh` runs.

## Getting the repo onto the host

```bash
git clone https://github.com/m-nikouei/t-network.git
cd t-network
```

## Path A — host provisioner (`setup.sh`)

```bash
sudo ./setup.sh
```

It installs the packages, writes `/etc/tor/torrc`, plants a placeholder
`/etc/wireguard/wg0.conf` (if you don't have one yet), defines the
`agent-mark-route.service` and the libvirt network `agent-net`, writes the
kill-switch to `/etc/nftables.d/agent-killswitch.nft` and includes it from
`/etc/nftables.conf`, orders `tor@default` after `libvirtd` + the policy
route, and lays out `/var/agent/{images,seeds,shares/{in,out,clean}}`.

Re-running is safe — every step is guarded:
- packages: `apt-get install` is a no-op if installed,
- config files: overwritten in place,
- libvirt network: `virsh net-info` check before `net-define`,
- nftables include line: `grep` before `printf >>`,
- services: `systemctl enable --now` is idempotent.

The endpoint pin in the firewall is **auto-derived from `wg0.conf`**, so a
placeholder config pins to `0.0.0.0:51820` (i.e. the firewall accepts nothing
useful and the host stays fail-closed). After you install a real config,
re-run `setup.sh` to re-render the endpoint and enable the services.

## Installing the secret (`wg0.conf`)

```bash
# Edit your downloaded Proton config: add 'Table = off', delete any 'DNS = ...'.
sudo install -m 600 -o root -g root /path/to/your.conf /etc/wireguard/wg0.conf
sudo ./setup.sh                       # re-renders the nftables endpoint pin
```

The script will enable `wg-quick@wg0` and `tor@default` on this second pass.

## Building the guest VMs (interactive)

`setup.sh` does **not** build `agent-vm` or `triage-vm` automatically because the
Debian installer is interactive. The script prints the exact `virt-install`
commands at the end of its run. Reproduced here for reference:

```bash
# Place the Debian 13 netinst ISO first:
sudo install -m 0644 -o libvirt-qemu -g kvm \
  ~/Downloads/debian-13.x.x-amd64-netinst.iso \
  /var/agent/seeds/agent-debian-13.iso

# Agent VM (4 GB)
sudo qemu-img create -f qcow2 /var/agent/images/agent.qcow2 20G
sudo virt-install --name agent-vm \
  --memory 4096 --vcpus 2 --machine q35 --boot uefi --osinfo debian13 \
  --disk path=/var/agent/images/agent.qcow2,format=qcow2,bus=virtio,discard=unmap \
  --cdrom /var/agent/seeds/agent-debian-13.iso \
  --network network=agent-net,model=virtio \
  --memorybacking source.type=memfd,access.mode=shared \
  --controller type=virtio-serial \
  --rng /dev/urandom \
  --graphics spice,clipboard.copypaste=no,filetransfer.enable=no \
  --noautoconsole

# Triage VM (2 GB, no NIC)
sudo qemu-img create -f qcow2 /var/agent/images/triage.qcow2 10G
sudo virt-install --name triage-vm \
  --memory 2048 --vcpus 2 --machine q35 --boot uefi --osinfo debian13 \
  --disk path=/var/agent/images/triage.qcow2,format=qcow2,bus=virtio \
  --cdrom /var/agent/seeds/agent-debian-13.iso \
  --network none \
  --memorybacking source.type=memfd,access.mode=shared \
  --graphics spice,clipboard.copypaste=no,filetransfer.enable=no \
  --noautoconsole
```

After install, follow README §7c (add the two virtio-fs shares to `agent-vm`)
and §8b (add the `from_agent` / `clean` shares to `triage-vm`). `virt-install`
cannot add `<filesystem>` devices that point at runtime-shared directories in
the same call; they are added with `virsh edit <vm>` once the guest is built.

Then harden the guest interior per README §7d.

## What the self-test checks (`verify.sh`)

Host-side (automated):
- bridge `virbr-agent` exists with `10.13.13.1/24`
- `tor` listens on `10.13.13.1:9040` (TCP) and `10.13.13.1:5300` (UDP+TCP)
- nftables `table inet ks` is loaded, `forward` chain is `policy drop`,
  redirect rules are present
- `ip rule` has `fwmark 0x2 → table 200`, table 200 has `default dev wg0`
  and `blackhole default` (the UDP fail-closed mechanism)
- `wg0` has a recent (`< 5 min`) handshake
- libvirt network `agent-net` is active
- `agent-vm` exists, has exactly 1 NIC, the NIC is bound to `agent-net`,
  no SPICE clipboard / filetransfer is enabled
- `triage-vm` exists and has **zero** NICs
- `ip_forward=1`, IPv6 disabled

With `--killswitch`: stops `tor@default` briefly and confirms the listener
disappears (the redirect target closes, the TCP path fails closed), then
restarts.

Guest-side (manual): the script prints a copy-paste block for you to run
inside `agent-vm` — TCP-via-Tor reachability, LAN unreachability, DNS
resolution, the read-only `/mnt/in` check, and the writable `/mnt/out`.
We deliberately do **not** keep a host→guest control channel
(no `qemu-guest-agent`, no SSH) so the host has no privileged exec path
into the agent; the operator runs these commands themselves.

Exit code is non-zero if any host-side check fails, so the script slots into
a post-build gate.

## Notes

- **Secrets:** only `wg0.conf` is sensitive; keep it out of git.
- **Re-running:** `setup.sh` is safe to re-run; `verify.sh` makes no
  destructive changes (except briefly with `--killswitch`).
- **Feeding the agent / extracting data:** see README §8 — drop input files
  into `/var/agent/shares/in/` on the host before starting the agent; the
  agent writes outputs to `/mnt/out` (= `/var/agent/shares/out/` on the
  host); triage them inside `triage-vm`.
