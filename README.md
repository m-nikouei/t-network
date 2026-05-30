# Identity-Sealed Job Runner (Ubuntu + KVM, TCP→Tor / UDP→ProtonVPN)

A simple build guide for an **old laptop** that runs heavy, long-running jobs on the
internet **without leaking your network identity**, while keeping it **easy to move the
results back onto your home network**.

- All job traffic to the internet is split by protocol: **TCP → Tor**, **DNS → Tor**,
  **UDP → ProtonVPN (free)**.
- The job VM never learns the host's real/public IP, and has no route to the internet
  except through the tunnels.
- **Fail-closed:** if Tor or the VPN is down, the job's traffic stops — it never falls
  back to your real IP.
- Data moves out through a plain **shared folder** to the host, and you **pull it over the
  LAN** from your workstation when you want it.

> **Threat model:** the jobs are **not adversarial**. We are protecting your *identity*
> against the remote services the jobs talk to — not defending the host against malicious
> code running inside the VM. That assumption is what makes this build small. If you need
> to run hostile code, see §10; this is not that document.

This replaces an earlier, much heavier design (a hostile-agent sandbox with a second
"triage" VM, a one-way data diode, and interactive guest installs). Everything that existed
only to contain hostile code has been removed.

---

## 1. What you get (and what you give up)

**You get:**
- One Ubuntu host + one job VM, both provisioned by scripts.
- A fail-closed firewall so a dropped tunnel can never expose your real IP.
- Non-interactive VM creation from a cloud image (no clicking through an installer).
- A **big native scratch disk** (≈900 GB, your whole 1 TB) for high-disk workloads, plus a
  small share + trivial `rsync`-over-LAN path for the outputs you keep.
- Host + guest pre-tuned for **high connection concurrency** (conntrack, ports, fds, Tor
  conn limits) — see §8b for the inherent Tor/VPN throughput ceilings.

**You give up (vs. the old hostile-agent design):**
- The job VM is isolated for *networking*, but it shares the host kernel boundary like any
  KVM guest — fine for trusted jobs, **not** a containment boundary for hostile code.
- No second VM, no file sanitization step. Output files are trusted as authored.
- The host has internet (Tor and the VPN need it) and sees your LAN. Keep it patched and
  don't put unrelated secrets on it.

---

## 2. Goals

| Goal | How it's achieved |
|------|-------------------|
| Jobs cannot reveal the host's real IP to remote services | The VM's only NIC is on an isolated bridge `virbr-jobs` (10.13.13.0/24). Its default route is the host bridge IP. TCP/DNS are transparently redirected into local Tor; UDP is marked and routed into the ProtonVPN tunnel. The real uplink IP is never a reachable next hop for the VM. |
| No clearnet leak, ever | Host nftables `forward` chain is **default-drop**. Only marked UDP onto `wg0` is forwarded; TCP/DNS are REDIRECTed into the host's Tor. If Tor is down the redirect hits a closed port; if `wg0` is down the marked UDP is blackholed. Nothing falls through to the uplink. |
| No DNS / IPv6 leaks | Port 53 from the VM is redirected to Tor's `DNSPort`; IPv6 is disabled on the host and the guest; the firewall is `inet` (v4+v6). |
| Easy data retrieval | The VM writes to a virtio-fs share that the host owns. You `rsync` it from your workstation over the LAN (the firewall governs only the VM bridge, never the host's own LAN/SSH). |

**Out of scope:** containing malicious code inside the VM, a KVM/kernel guest-escape, a
global passive adversary correlating the Tor exit against the ProtonVPN IP, and
application-layer identity leaks (logins, fingerprinting, file metadata) that defeat any
network anonymity.

---

## 3. Architecture

```
  host (Ubuntu Server, minimal, full-disk-encrypted)
  ──────────────────────────────────────────────────────────────────────
   physical NIC (eth0 / wlan0) ── real IP; reaches your LAN + internet
       │                            (host updates + Tor + VPN ride this)
       │
       ├── tor.service           TransPort 10.13.13.1:9040   (TCP + DNS over Tor)
       │                         DNSPort   10.13.13.1:5300
       │
       ├── wg-quick@wg0          ProtonVPN free; Table=off; endpoint pinned
       │                         ip rule fwmark 0x2 → table 200 → wg0 / blackhole
       │
       ├── nftables (table inet ks)
       │     forward: DROP by default; only marked UDP → wg0 is allowed.
       │     nat:     VM tcp → redirect :9040;  udp/53 → redirect :5300;
       │              udp≠53 → mark 0x2 (routing sends it to wg0);
       │              oif wg0 masquerade.
       │
       └── libvirt + KVM
             net "jobs-net" → bridge virbr-jobs (10.13.13.1/24, forward=open)
               └── jobs-vm   (Debian cloud image, auto-provisioned by cloud-init)
                     • only NIC: on virbr-jobs (10.13.13.10) → all egress tunneled
                     • /data   → big native scratch disk (~900 GB, raw virtio-blk)
                     • /mnt/share → small virtio-fs share for finished outputs only

   data out:  jobs-vm writes results → /mnt/share/out → host /var/jobs/share/out
              → you pull over LAN:
              you@workstation$ rsync ops@<box-LAN-ip>:/var/jobs/share/out/ ./
```

**Traffic flow from the job VM:**

```
 TCP  ──▶ host nftables redirect ──▶ tor TransPort ──▶ Tor circuit ──▶ Internet
 DNS  ──▶ host nftables redirect ──▶ tor DNSPort  ──▶ Tor circuit ──▶ resolve
 UDP  ──▶ host nftables mark+route ▶ wg0 ──▶ ProtonVPN ──▶ Internet
 anything else / tunnels-down ──────────────────────────────────────▶ DROP
```

---

## 4. Prerequisites

- A laptop you can **wipe**: 64-bit CPU with **VT-x/AMD-V** (check
  `egrep -c '(vmx|svm)' /proc/cpuinfo` returns non-zero), ≥4 GB RAM, and your **1 TB**
  disk for job data.
- **Ubuntu Server LTS** install media (verify the SHA256 before flashing). Server, not
  Desktop — smaller footprint, no GUI needed.
- A **ProtonVPN free** account (for the UDP path). Free supports manual WireGuard with
  limits: free servers only, one connection, variable speed — fine for low-bandwidth UDP.
- The repo on the host, and comfort with `nft`, `ip`, `systemd`, and `virsh`.

---

## 5. Install Ubuntu & the packages

1. Boot the verified Ubuntu Server installer. During install:
   - **Encrypt the disk** (LUKS2) — your data-at-rest seal for whatever the jobs collect.
   - Minimal install; install **OpenSSH server** (you'll pull data over it on the LAN).
   - **Plan the 1 TB for the scratch disk.** The VM's working set lives on a big disk
     under `/var/jobs`. Either give `/var` (or `/`) ~950 GB so the scratch **image** has
     room, **or** leave ~900 GB unallocated / in an LVM volume and pass it to the VM as a
     raw block device (faster — see §7, `DATA_DEV`). Keep the host root modest (~40–60 GB).
2. Clone the repo and run the host provisioner (it installs everything and writes the
   network plane):
   ```bash
   git clone https://github.com/m-nikouei/t-network.git
   cd t-network
   sudo ./setup.sh                 # idempotent; UPLINK=wlan0 ./setup.sh if on Wi-Fi
   ```
   `setup.sh` installs `tor`, `wireguard`, `nftables`, `qemu`/`libvirt`/`virtinst`,
   `virtiofsd`, etc., disables IPv6, enables `ip_forward`, and lays out `/var/jobs`.

See §6 for what the script writes, and [AUTOMATION.md](AUTOMATION.md) for the script
contract (idempotency, re-run safety).

---

## 6. The host network plane (written by `setup.sh`)

### 6a. Tor — TCP + DNS, bound to the bridge only

`/etc/tor/torrc`:

```ini
User debian-tor
DataDirectory /var/lib/tor
SocksPort 0
TransPort 10.13.13.1:9040
DNSPort   10.13.13.1:5300
AutomapHostsOnResolve 1
VirtualAddrNetworkIPv4 10.192.0.0/10
ExitRelay 0
ClientOnly 1
```

Binding to **`10.13.13.1`** (the bridge gateway), not `0.0.0.0`, means only packets that
arrive on `virbr-jobs` can reach Tor — the host's real NIC never exposes these ports.

### 6b. WireGuard / ProtonVPN (the one secret you install by hand)

On a trusted device, sign in at **account.protonvpn.com → Downloads → WireGuard
configuration**, pick a **free** server, download the `.conf`, edit it, and install it:

```ini
[Interface]
PrivateKey = <yours>
Address = 10.2.0.2/32
# DNS = ...     ← DELETE (DNS goes through Tor)
Table = off     ← ADD (we route into wg0 by fwmark, not a catch-all default route)

[Peer]
PublicKey = <server>
AllowedIPs = 0.0.0.0/0
Endpoint = <PROTON_SERVER_IP>:51820   # keep it NUMERIC — the firewall pins to this IP
```

```bash
sudo install -m 600 -o root -g root your.conf /etc/wireguard/wg0.conf
sudo ./setup.sh        # re-run: it auto-derives the endpoint pin and starts the tunnels
```

Until a real config is present, `setup.sh` plants a placeholder pinned to `0.0.0.0:51820`
and leaves the tunnels disabled, so the host stays fail-closed.

### 6c. Policy routing for marked UDP

Marked traffic (`fwmark 0x2`) uses a dedicated routing table whose default goes out `wg0`
and whose fallback is a **blackhole**, so a downed tunnel can never fall through to
clearnet (`agent-mark-route.service`, written by `setup.sh`):

```
ip rule add fwmark 0x2 table 200
ip route replace default dev wg0 table 200
ip route add blackhole default metric 1000 table 200
```

### 6d. The isolated libvirt bridge

`jobs-net` uses `forward mode='open'`: libvirt creates the bridge and gateway IP but adds
**no firewall rules of its own** — we own all of them.

```xml
<network>
  <name>jobs-net</name>
  <forward mode='open'/>
  <bridge name='virbr-jobs' stp='off' delay='0'/>
  <ip address='10.13.13.1' netmask='255.255.255.0'>
    <dhcp><range start='10.13.13.10' end='10.13.13.10'/></dhcp>
  </ip>
</network>
```

### 6e. nftables kill-switch (`/etc/nftables.d/jobs-killswitch.nft`)

This table only governs the **VM bridge** — your host's own LAN/SSH/updates are untouched.
The `forward` chain `policy drop` plus the blackhole route are what make it fail-closed.

```nft
table inet ks
delete table inet ks
table inet ks {
    define BRIDGE = "virbr-jobs"
    define UPLINK = "eth0"               # CHANGE ME if you use wlan0
    define VPN_ENDPOINT = 1.2.3.4        # auto-pinned from wg0.conf by setup.sh
    define VPN_PORT     = 51820

    # Mark all VM UDP (except DNS) so policy routing sends it into wg0.
    chain premark {
        type filter hook prerouting priority -150; policy accept;
        iifname $BRIDGE udp dport != 53 meta mark set 0x2
    }
    # Transparent redirect: VM TCP → local Tor; DNS → Tor DNSPort.
    chain nat_pre {
        type nat hook prerouting priority -150; policy accept;
        iifname $BRIDGE tcp dport 53 redirect to :5300
        iifname $BRIDGE udp dport 53 redirect to :5300
        iifname $BRIDGE meta l4proto tcp redirect to :9040
    }
    # VM → host: DHCP, Tor ports, established replies; everything else from the VM dropped.
    chain input {
        type filter hook input priority 0; policy accept;
        iifname $BRIDGE udp dport 67 accept
        iifname $BRIDGE tcp dport { 9040, 5300 } accept
        iifname $BRIDGE udp dport 5300 accept
        iifname $BRIDGE ct state established,related accept
        iifname $BRIDGE drop
    }
    # Forward: default drop. Only marked UDP onto wg0 is allowed out.
    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept
        ct state invalid drop
        iifname $BRIDGE oifname "wg0" meta mark 0x2 accept
    }
    # SNAT VM UDP onto wg0's address so Proton accepts it and replies route back.
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "wg0" masquerade
    }
}
```

### 6f. Bring-up order

The bridge must exist before Tor binds to its address; `setup.sh` orders `tor@default`
after `libvirtd` and the policy route, then enables everything. Confirm:

```bash
wg show wg0                              # recent handshake
ss -ltnp | grep -E ':(9040|5300)\s'      # tor listening on 10.13.13.1
nft list table inet ks | head            # kill-switch loaded
ip route show table 200                  # default via wg0 + blackhole
```

---

## 7. Build the job VM (non-interactive, from a cloud image)

`jobs-vm.sh` builds the VM with **no installer**: a Debian cloud image for the OS, a big
**native scratch disk** for the working set, and a small cloud-init that creates your `ops`
user, installs your SSH key, formats/mounts the scratch disk, mounts the output share, and
seals DNS/IPv6.

```bash
# SSH_PUBKEY logs you into the VM; DATA_DISK sizes the scratch disk.
sudo SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" DATA_DISK=900G ./jobs-vm.sh
```

What it does:
- Downloads `debian-13-genericcloud-amd64.qcow2` (verify the published checksum) and makes
  a small OS root disk from it (`DISK`, default **30 GB** — the OS only).
- Provisions the **scratch disk** mounted at `/data` in the VM:
  - default: a preallocated raw image `/var/jobs/images/data.img` of `DATA_DISK`
    (default **900 GB**), attached as a `virtio-blk` device with `cache=none,io=native`
    for throughput under heavy I/O;
  - **faster:** pass a host block device/LVM volume/partition with `DATA_DEV=/dev/…` and it
    is handed to the VM raw (no image-file layer). Best for "all 1 TB used".
  - `DATA_FS` (default `xfs`) is the filesystem; cloud-init formats it on first boot only.
- Renders cloud-init (`ops` + your key, `nameserver 10.13.13.1`, IPv6 off, **ephemeral-port
  + open-file limits raised** for high connection concurrency, `rsync`/`curl`/`xfsprogs`,
  the virtio-fs share at `/mnt/share`).
- Runs `virt-install --import` (OS disk + scratch disk + virtio-fs share, on `jobs-net`).
  The VM DHCPs `10.13.13.10` and points its default route + DNS at the host — so **every**
  packet it sends is forced through the tunnels.

Tunables (env): `DISK` (OS root, 30G), `DATA_DISK` (scratch, 900G), `DATA_DEV` (use a raw
device instead), `DATA_FS` (xfs), `RAM_MB` (3072), `VCPUS` (2), `CLOUDIMG_URL`.

Once it's up:

```bash
ssh ops@10.13.13.10          # from the host (your key was provisioned by cloud-init)
```

Run your jobs as `ops`. All TCP/DNS goes through Tor, all UDP through ProtonVPN. Put the
**heavy working set on `/data`** (native speed); write only the **finished outputs** you
want to keep into `/mnt/share/out/` (virtio-fs is slower — don't run the workload on it).

> **Reset-on-demand:** to wipe job state, `virsh destroy jobs-vm; virsh undefine --nvram
> jobs-vm`, then re-run `jobs-vm.sh`. By default it **reuses** the existing `data.img`
> (your scratch survives); delete it first if you want a clean scratch disk too.

---

## 8. Moving data out — the easy path

The working set stays on `/data` inside the VM. Only the **finished outputs** go through
the virtio-fs share, which the host owns; you pull them over the LAN. No sanitization step
(jobs are trusted), no second VM.

Inside `jobs-vm`:
```bash
# work on /data; copy only the results worth keeping into the share
rsync -a /data/results/ /mnt/share/out/
```

On the host, the same files appear at `/var/jobs/share/out/`. From your workstation:
```bash
rsync -av ops@<box-LAN-ip>:/var/jobs/share/out/ ~/job-results/$(date +%F)/
```

`<box-LAN-ip>` is the host's normal LAN address (e.g. `192.168.1.x`). The kill-switch
table only governs `virbr-jobs`, so the host's own SSH on the LAN works normally. To put
inputs *into* a job, drop them in `/var/jobs/share/in/` on the host; the VM sees them at
`/mnt/share/in/`.

> **Moving the whole `/data` later?** This design keeps the bulk on `/data` and moves only
> outputs, per your setup. If you ever need the entire scratch disk on your network, shut
> the VM down (`virsh shutdown jobs-vm`) and loop-mount the image read-only on the host
> (`mount -o ro,loop /var/jobs/images/data.img /mnt/x`), then `rsync` it over the LAN.
> Never mount it while the VM is running — concurrent writers corrupt the filesystem.

---

## 8b. Throughput & limits (high network + disk usage)

Read this before you scale up — two ceilings are inherent to the design, and a few knobs
are already tuned for you.

- **Tor is the TCP bottleneck.** All TCP/DNS rides Tor. For **many small connections**
  (crawling/scraping) that's workable: it's latency-bound, not bandwidth-bound, and the
  high concurrency is handled. Expect per-request latency of a few hundred ms to a couple
  of seconds (circuit setup + relays), and modest aggregate throughput. Bulk multi-MB/s
  transfers over Tor are a different story — slow and discouraged on the network.
- **Your exit IP rotates.** Tor retires "dirty" circuits about every 10 minutes
  (`MaxCircuitDirtiness`, default 600 s), so a scraper's apparent source IP changes
  periodically. That can help (spreads load across IPs) or hurt (breaks IP-pinned
  sessions). Tune it in `/etc/tor/torrc` — raise to hold an IP longer, lower to rotate
  faster — then `systemctl reload tor@default`.
- **Connection-table headroom (already tuned by `setup.sh`).** The host NATs/redirects
  every connection the VM opens, so high concurrency is bounded by conntrack, ephemeral
  ports, and file descriptors. `setup.sh` raises `nf_conntrack_max` (1M) with a shorter
  `TIME_WAIT`, widens `ip_local_port_range`, and bumps Tor's `ConnLimit` (8192) +
  `LimitNOFILE`. The VM raises its own ephemeral-port range and `nofile` limit for `ops`.
  If you push connection counts very high, watch `nft list ruleset | grep -i conntrack`
  and `dmesg | grep -i conntrack` (table-full drops) on the host.
- **Disk.** `/data` is a raw `virtio-blk` device with `cache=none,io=native` and `noatime`
  — the right shape for sustained heavy I/O. For the very best throughput when "all 1 TB is
  used", back it with a real partition/LVM volume via `DATA_DEV=` rather than an image file.
- **ProtonVPN free** gives one connection and throttled, variable speed — fine for the UDP
  side of a small-connection workload, not for bulk.

---

## 9. Verification & leak tests

`sudo ./verify.sh` checks the host plane (bridge, Tor listeners, kill-switch loaded,
`forward` policy drop, fwmark route + blackhole, recent `wg0` handshake, the VM has exactly
one NIC on `jobs-net`, IPv6 off, `ip_forward=1`). Add `--killswitch` to briefly stop Tor
and confirm the redirect target disappears (fail-closed).

Run these **inside `jobs-vm`** (the script prints them too):

```bash
# TCP via Tor — expect {"IsTor":true,"IP":"<exit>"}
curl -s https://check.torproject.org/api/ip

# DNS via Tor
getent hosts example.com

# UDP via ProtonVPN — should report the Proton IP, distinct from the Tor exit
curl --http3-only -s https://cloudflare-quic.com/ | head

# No route to your real IP / LAN (these MUST fail or time out)
ping -c2 -W2 192.168.1.1
ip neigh                     # should show only 10.13.13.1
```

On the host, confirm nothing leaks in clear while a job runs:
```bash
sudo tcpdump -ni eth0 'port 53'      # MUST be silent (DNS only via Tor)
```

---

## 10. Operational notes

- **Free-server rotation:** when Proton retires your server, re-download the config,
  replace `/etc/wireguard/wg0.conf`, then `sudo ./setup.sh` (re-pins the endpoint) and
  `systemctl restart wg-quick@wg0`.
- **Secrets:** `wg0.conf` holds the WireGuard private key — `0600 root:root`, on the
  encrypted disk, never in git.
- **Updates:** `unattended-upgrades` handles the host. Update the VM yourself
  (`apt update && apt upgrade` inside it — it goes through Tor, slow but correct).
- **Clock:** Tor needs a sane clock. If the laptop loses time on suspend,
  `sudo chronyc -a makestep` after resume.
- **Two egress identities:** TCP exits as a Tor relay, UDP as a ProtonVPN IP. An adversary
  watching both can tell one machine uses both — this is a capability split (Tor can't
  carry UDP), not an anonymity gain. If you don't need UDP, you can drop the WireGuard half
  entirely and run Tor-only.
- **Running hostile code instead of trusted jobs?** This design does **not** contain it:
  the host holds your real IP and your LAN. For that you want a stronger boundary (a second
  network VM, or the earlier Qubes/triage-VM design in this repo's history).

---

## 11. Quick build checklist

- [ ] Ubuntu Server installed (verified ISO, full-disk encryption, OpenSSH server, ~950 GB
      on `/var` for the scratch disk, or ~900 GB free for a `DATA_DEV` block device)
- [ ] `sudo ./setup.sh` run: packages in, IPv6 off, `ip_forward=1`, conntrack/port/fd
      tuning applied, `/var/jobs` laid out
- [ ] `/etc/wireguard/wg0.conf`: free Proton, `Table=off`, no `DNS=`, numeric endpoint, 0600
- [ ] Re-ran `setup.sh` after installing the real `wg0.conf` (tunnels + endpoint pin live)
- [ ] `wg show wg0` shows a recent handshake; Tor listening on 10.13.13.1:9040 / :5300
- [ ] `nft list table inet ks` loaded, `forward` is `policy drop`; `ip route show table 200`
      has `default dev wg0` + `blackhole default`
- [ ] `sudo SSH_PUBKEY=... DATA_DISK=900G ./jobs-vm.sh` built `jobs-vm`; one NIC on
      `jobs-net`; two disks (OS + scratch)
- [ ] `ssh ops@10.13.13.10` works; `df -h /data` shows the scratch disk; `check.torproject.org`
      reports `IsTor:true`
- [ ] LAN/real-IP unreachable from the VM; `tcpdump` on the uplink shows no clear DNS
- [ ] `rsync ops@<box-LAN-ip>:/var/jobs/share/out/ .` retrieves results from your workstation

---

References:
- [ProtonVPN WireGuard configuration](https://protonvpn.com/support/wireguard-configurations) ·
  [manual WireGuard on Linux](https://protonvpn.com/support/wireguard-linux)
- [Debian cloud images](https://cloud.debian.org/images/cloud/) ·
  [cloud-init NoCloud / virt-install `--cloud-init`](https://cloudinit.readthedocs.io/)
- [virtio-fs in libvirt](https://libvirt.org/kbase/virtiofs.html) ·
  [nftables wiki](https://wiki.nftables.org/) ·
  [WireGuard `Table = off`](https://www.wireguard.com/quickstart/)
