# Automating the build

Three scripts provision the system from [README.md](README.md):

```
setup.sh     # host plane (packages, Tor, WireGuard, nftables kill-switch, libvirt net) — root
jobs-vm.sh   # build the job VM non-interactively from a cloud image (cloud-init)    — root
verify.sh    # self-test: assert the seal holds                                       — root
```

No Salt/Ansible — on a single Ubuntu host, idempotent bash is a smaller, easier-to-audit
TCB. If you want Ansible later, lifting `setup.sh` into a role is straightforward.

## Manual prerequisites (cannot/should not be automated)

1. **Install Ubuntu Server LTS** on the wiped laptop. Verify the ISO checksum, enable
   full-disk encryption (LUKS2), choose the minimal install, **install OpenSSH server**
   (you pull data over it on the LAN), and give `/` (or `/var`) most of the 1 TB.
2. **Download the ProtonVPN free WireGuard config** (web login) — the one secret. It is
   never stored in the repo; you install it by hand (below).
3. Have your **workstation's SSH public key** ready; `jobs-vm.sh` installs it into the VM.

## Getting the repo onto the host

```bash
git clone https://github.com/m-nikouei/t-network.git
cd t-network
```

## Step 1 — host plane (`setup.sh`)

```bash
sudo ./setup.sh                 # UPLINK=wlan0 ./setup.sh if you're on Wi-Fi
```

It installs packages, writes `/etc/tor/torrc`, plants a placeholder
`/etc/wireguard/wg0.conf` (if absent), defines `jobs-mark-route.service` and the libvirt
network `jobs-net`, writes the kill-switch to `/etc/nftables.d/jobs-killswitch.nft` and
includes it from `/etc/nftables.conf`, orders `tor@default` after `libvirtd` + the policy
route, and lays out `/var/jobs/{images,share/{in,out}}`.

Re-running is safe — every step is guarded (packages are no-ops if installed, configs are
overwritten in place, `virsh net-info` gates the net-define, the include line is
`grep`-guarded, `systemctl enable --now` is idempotent).

The endpoint pin in the firewall is **auto-derived from `wg0.conf`**, so a placeholder
config pins to `0.0.0.0:51820` (the host stays fail-closed). After installing a real
config, re-run `setup.sh` to re-render the pin and start the tunnels.

## Step 2 — install the secret (`wg0.conf`)

```bash
# Edit your downloaded Proton config: add 'Table = off', delete any 'DNS = ...'.
sudo install -m 600 -o root -g root /path/to/your.conf /etc/wireguard/wg0.conf
sudo ./setup.sh                 # re-renders the nftables endpoint pin, starts the tunnels
```

## Step 3 — build the job VM (`jobs-vm.sh`)

Unlike the old design, the VM is built **non-interactively** — a Debian cloud image plus
cloud-init, no installer to click through:

```bash
sudo SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" DISK=400G ./jobs-vm.sh
```

It downloads `debian-13-genericcloud-amd64.qcow2` (cached at
`/var/jobs/images/base-debian13.qcow2`), copies it to `jobs.qcow2`, `qemu-img resize`s to
`DISK`, renders a cloud-init `user-data` (user `ops` + your key, `nameserver 10.13.13.1`,
IPv6 off, `rsync`/`curl`, the virtio-fs `share` mounted at `/mnt/share`), and runs
`virt-install --import --cloud-init ... --filesystem ... --network network=jobs-net`.

Tunables via env: `VM`, `RAM_MB` (default 3072), `VCPUS` (2), `DISK` (200G),
`CLOUDIMG_URL`. **Verify** the image against the published `SHA512SUMS` before trusting it.

To rebuild from scratch (wipe job state):
```bash
sudo virsh destroy jobs-vm 2>/dev/null; sudo virsh undefine --nvram jobs-vm
sudo SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" ./jobs-vm.sh
```
Data under `/var/jobs/share` on the host is not touched by a rebuild.

## Step 4 — verify (`verify.sh`)

Host-side (automated):
- bridge `virbr-jobs` exists with `10.13.13.1/24`
- `tor` listens on `10.13.13.1:9040` (TCP) and `:5300` (UDP+TCP)
- `table inet ks` loaded, `forward` is `policy drop`, redirect + wg0-accept rules present
- `ip rule` has `fwmark 0x2 → table 200`; table 200 has `default dev wg0` + `blackhole`
- `wg0` has a handshake `< 5 min` old
- libvirt network `jobs-net` active; `jobs-vm` has exactly 1 NIC bound to `jobs-net`
- `ip_forward=1`, IPv6 disabled

With `--killswitch`: stops `tor@default` briefly, confirms the listener disappears (TCP
path fails closed), then restarts.

Guest-side (manual): the script prints a copy-paste block to run inside `jobs-vm` —
TCP-via-Tor, UDP-via-Proton, DNS, LAN unreachability, and the writable `/mnt/share/out`.

Exit code is non-zero if any host-side check fails, so it slots into a post-build gate.

## Data flow

- **Out:** the VM writes to `/mnt/share/out` → host `/var/jobs/share/out`. From your
  workstation: `rsync -av ops@<box-LAN-ip>:/var/jobs/share/out/ ~/job-results/$(date +%F)/`.
  The kill-switch governs only the VM bridge, so the host's own LAN SSH is unaffected.
- **In:** drop inputs in `/var/jobs/share/in/` on the host; the VM sees them at
  `/mnt/share/in/`.

## Notes

- **Secrets:** only `wg0.conf` is sensitive; keep it out of git, `0600 root:root`, on the
  encrypted disk.
- **Re-running:** `setup.sh` is safe to re-run. `jobs-vm.sh` refuses to clobber an existing
  VM (destroy/undefine first). `verify.sh` makes no changes except briefly with
  `--killswitch`.
- **Not a containment boundary:** jobs are assumed non-adversarial. This seals network
  identity; it does not defend the host against hostile code in the VM. See README §10.
