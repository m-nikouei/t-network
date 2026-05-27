# Fail-Closed Split-Tunnel Firewall for an Untrusted Agent (Ubuntu + KVM)

A design + build guide for running an autonomous agent (e.g. an **OpenClaw** computer-use
agent) inside a KVM virtual machine on a hardened Ubuntu host, where the host enforces
a **fail-closed**, **identity-sealed**, network-split firewall and the agent can only
exfiltrate through an **audited, network-free path**:

- If the anonymizing tunnels are down, **nothing leaves** (no clearnet fallback).
- The agent VM never learns the host's real/public IP.
- The agent VM **cannot reach, leak to, or even discover** your home/LAN network.
- Traffic is split by protocol: **TCP → Tor**, **UDP (non-DNS) → ProtonVPN**, **DNS → Tor**.
- Data is moved out of the agent VM via a host-mediated, one-direction virtio-fs share,
  triaged inside a transient **offline triage VM**, never over the network or a shared
  clipboard.

> **Status:** planning/build document. Placeholders are `CAPS` / `# CHANGE ME`. The agent
> is treated as **hostile even with root inside its VM**. Read §11 before relying on this.

This is a redesign of the earlier Qubes-OS-based plan; that design needed ≥16 GB RAM and
a Qubes-compatible Wi-Fi chipset. This one targets an **8 GB Ubuntu-capable laptop**.

---

## 1. Why Ubuntu + KVM (and what you give up vs Qubes)

KVM is a **type-2** hypervisor: a Linux host kernel exposes hardware-virtualized guests via
`kvm.ko` plus `qemu`. Guests are isolated by the same Intel VT-x / AMD-V boundary Qubes
uses, but the host kernel is shared between the management plane, the network plane, and
the host's own admin tools. Compared with Qubes:

**What KVM still gives you:** a hardware-enforced VM boundary around the agent (the agent's
guest kernel cannot read host RAM, host disk, or other guests); libvirt's sVirt (SELinux/
AppArmor labels per-guest) further confines QEMU; isolated bridges per-network; per-guest
disk images; live attach/detach of devices.

**What KVM does *not* give you that Qubes did:**
- **No dom0 / netless admin domain.** On Qubes, the admin domain (`dom0`) had no network at
  all; networking lived in `sys-net`. Here, the same kernel handles agent virtualization,
  Tor/WireGuard, and the host's own outbound (updates, SSH). A successful guest-to-host
  escape lands on a machine *with* internet.
- **No qrexec.** Inter-domain RPC with a central policy file does not exist. The closest
  equivalent here is a **one-direction virtio-fs share** plus an operator-in-the-loop triage
  step (§8).
- **One VM-boundary instead of two.** Qubes also isolated the network code (`sys-split`,
  `sys-net`) from the agent in separate VMs. Here the network code runs on the host.

The Qubes design was stronger. This design is the practical floor for 8 GB hardware that
won't boot Qubes; §11 lists what that costs you. If you can get an Atheros AR9271 USB Wi-Fi
adapter (~$20) onto a 16 GB Qubes-compatible laptop, go back to Qubes.

---

## 2. Threat model & goals

| Goal | How it's achieved |
|------|-------------------|
| Agent cannot discover the host's external IP | The agent VM's only NIC is on `virbr-agent`, an isolated bridge with private RFC1918 addressing. Its default route is the bridge IP. The host's real IP lives on `eth0`/`wlan0`, which the agent cannot ARP, route to, or send packets to. |
| Agent cannot reach the home/LAN network | nftables on the host **drops** any agent packet whose destination is in RFC1918 / link-local / CGNAT / multicast — including 10.13.13.0/24 sibling addresses other than the gateway itself. |
| Agent cannot even *learn the LAN exists* | The agent only sees `10.13.13.0/24`. Scans/ARP/DNS to your real LAN (`192.168.x/10.x/172.16.x`) are dropped at the host's forward chain; DNS goes through Tor and never resolves RFC1918 names. |
| No clearnet leaks, ever | Host nftables **default DROP** on the forward chain for agent traffic; only marked UDP via `wg0` and REDIRECTed TCP to local Tor are permitted. If Tor or `wg0` is down, the REDIRECT lands on a closed port and the route table 200 blackholes marked UDP. |
| No DNS / IPv6 leaks | Port 53 REDIRECTed to Tor `DNSPort`; IPv6 disabled on the bridge and on the guest; firewall is `inet` (v4+v6). |
| Data leaves only through a controlled path | One-direction virtio-fs share into a host-owned dropbox. Inspection happens inside a transient **triage-vm** with no network. Operator promotes only sanitized output. See §8. |

**Out of scope:** a KVM/Linux-kernel 0-day escape from the agent VM (this is more impactful
here than on Qubes — see §11), a malicious host before you wipe it, hardware implants,
firmware persistence below the OS, and a global passive adversary correlating the Tor exit
vs. the ProtonVPN IP.

---

## 3. Architecture

```
   host (Ubuntu 24.04 LTS, minimal, FDE, AppArmor)
   ─────────────────────────────────────────────────────────────────────────
    physical NIC (eth0 / wlan0) ── real IP, sees home LAN, host updates here
        │
        ├── tor.service           (debian-tor user)
        │     TransPort 10.13.13.1:9040      TCP + DNS over Tor
        │     DNSPort   10.13.13.1:5300
        │
        ├── wg-quick@wg0          (ProtonVPN free)
        │     wg0 = 10.2.0.2/32, Table=off, endpoint pinned
        │     ip rule fwmark 0x2 → table 200 → default dev wg0 / blackhole
        │
        ├── nftables (table inet ks)
        │     forward: DROP by default; allow only iif virbr-agent → oif wg0
        │              (marked 0x2); LAN_BLOCK; established/related return.
        │     input:   from virbr-agent allow only :9040 (tcp) and :5300.
        │     nat:     iif virbr-agent  tcp → redirect :9040
        │                                udp/53 → redirect :5300
        │                                udp != 53 → mark 0x2 (routing picks wg0)
        │              oif wg0 masquerade  (so Proton sees wg0's address)
        │
        ├── libvirt + KVM
        │     net "agent-net"  →  bridge virbr-agent  (10.13.13.1/24, forward=open)
        │       └── agent-vm    Debian minimal, untrusted, OpenClaw runs here
        │             • only vNIC: vnet0 on virbr-agent (10.13.13.10)
        │             • virtio-fs ro:  /var/agent-in     →  /mnt/in    (inputs)
        │             • virtio-fs rw:  /var/agent-out/box →  /mnt/out   (exfil)
        │
        └── /var/agent-out/box   ← host-side directory; the only place the agent can write
                  │                  to the host filesystem. Inspect-on-demand in triage.
                  ▼
            triage-vm  (started ONLY when extracting; netvm=none equivalent: no NIC)
                  • virtio-fs ro:  /var/agent-out/box        →  /mnt/from-agent
                  • virtio-fs rw:  /var/agent-out/clean      →  /mnt/clean
                  • tools: qpdf, pdftotext, ImageMagick, file, strings
                  • sanitize → write only safe artifacts to /mnt/clean → shut down
                  • host then moves /var/agent-out/clean/* to your real work device
```

**Traffic flow from the agent:**

```
 TCP  ──▶ host nftables redirect ──▶ tor TransPort ──▶ Tor circuit ──▶ Internet
 DNS  ──▶ host nftables redirect ──▶ tor DNSPort  ──▶ Tor circuit ──▶ resolve
 UDP  ──▶ host nftables mark+route ▶ wg0 ──▶ ProtonVPN ──▶ Internet
 LAN / clearnet / tunnels-down ─────────────────────────────────────▶ DROP
```

---

## 4. Prerequisites

- A laptop you can **wipe**, with: 64-bit CPU, **VT-x + VT-d** (IOMMU), ≥8 GB RAM, ≥64 GB
  SSD. Confirm `egrep -c '(vmx|svm)' /proc/cpuinfo` returns non-zero on the live USB.
- **Ubuntu 24.04 LTS Server** install media (verify the SHA256 against
  `ubuntu.com/download/server` before flashing). Server, not Desktop: smaller TCB, no GUI
  on the host. A minimal XFCE comes later only if you actually need a GUI for `virt-manager`.
- A **ProtonVPN free** account. Free supports manual WireGuard but with limits: free-tier
  servers only, **one** connection, no port-forwarding/P2P, possibly slower.
- A **Debian 13** netinst ISO (for the agent and triage guests).
- Comfort with `nft`, `ip`, `systemd`, and `virsh`/`virt-install`.

---

## 5. Install Ubuntu & harden the host

1. Boot the verified Ubuntu 24.04 LTS Server installer. During install:
   - **Encrypt the root LVM** (LUKS2). This is your data-at-rest seal.
   - Minimal install: do **not** select Docker, Kubernetes, etc. snaps.
   - Only OpenSSH if you actually need remote access; otherwise leave it off.
2. First-boot hardening, as root:
   ```bash
   apt update && apt full-upgrade -y
   apt install -y unattended-upgrades apparmor apparmor-utils \
                  tor wireguard wireguard-tools nftables \
                  qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients \
                  virtinst virt-manager ovmf swtpm virtiofsd
   dpkg-reconfigure -plow unattended-upgrades       # enable auto-updates
   systemctl enable --now apparmor
   systemctl mask ufw                                # we use nftables directly
   systemctl disable --now tor                       # we start it via a custom unit (§6)
   ```
3. Disable IPv6 host-wide (we don't carry v6 through the tunnels and don't want leaks):
   ```bash
   cat >/etc/sysctl.d/60-no-ipv6.conf <<'EOF'
   net.ipv6.conf.all.disable_ipv6 = 1
   net.ipv6.conf.default.disable_ipv6 = 1
   net.ipv4.ip_forward = 1
   EOF
   sysctl --system
   ```
4. Add your user to `libvirt` and `kvm`:
   ```bash
   usermod -aG libvirt,kvm "$USER"
   ```
   Log out and back in (or `newgrp libvirt`).

---

## 6. Build the host network plane (Tor + WireGuard + nftables)

### 6a. Tor configuration

Write `/etc/tor/torrc.d/agent-split.conf` (Tor on Debian/Ubuntu reads files in
`/etc/tor/torrc.d/` if you `%include` them; simpler is to overwrite `/etc/tor/torrc`):

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

Binding to **`10.13.13.1`** (the bridge gateway) — not `0.0.0.0` — means only packets that
arrive on `virbr-agent` can reach Tor. The host's external NIC cannot inadvertently expose
the ports.

`tor.service` is the stock Debian unit; it's already configured to drop privileges to
`debian-tor`. Do **not** enable it yet — the bridge `virbr-agent` does not exist at boot
order time and Tor will fail to bind. We sequence it after libvirt in §6e.

### 6b. WireGuard / ProtonVPN

On a trusted device, sign in at **account.protonvpn.com → Downloads → WireGuard
configuration**, name it short (letters/underscores, <15 chars), pick a **free** server,
download the `.conf`, then copy it to `/etc/wireguard/wg0.conf` on the host. Edit:

```ini
[Interface]
PrivateKey = CHANGE_ME
Address = 10.2.0.2/32
# DNS = ...     ← DELETE (DNS goes through Tor)
Table = off     ← ADD (we route into wg0 by fwmark; no catch-all)

[Peer]
PublicKey = CHANGE_ME
AllowedIPs = 0.0.0.0/0
Endpoint = PROTON_SERVER_IP:51820   # record IP + port for the firewall
```

```bash
chmod 600 /etc/wireguard/wg0.conf
chown root:root /etc/wireguard/wg0.conf
```

> **Why a numeric `Endpoint`:** the firewall keys on the literal IP, so the tunnel can come
> up without DNS, and a stale/retired free server simply fails closed.

### 6c. Policy routing for marked UDP

Marked traffic (`fwmark 0x2`) must use a dedicated routing table whose default goes out
`wg0` and whose fallback is a blackhole, so a downed tunnel cannot fall through to clearnet:

```bash
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
```

### 6d. The libvirt isolated bridge

We define the agent's network with `forward mode='open'`: libvirt creates the bridge and
assigns the gateway IP, but adds **no iptables/nftables rules of its own**. We own all
the firewall logic.

```bash
cat >/etc/libvirt/qemu/networks/agent-net.xml <<'EOF'
<network>
  <name>agent-net</name>
  <forward mode='open'/>
  <bridge name='virbr-agent' stp='off' delay='0'/>
  <ip address='10.13.13.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='10.13.13.10' end='10.13.13.10'/>
    </dhcp>
  </ip>
</network>
EOF
virsh net-define /etc/libvirt/qemu/networks/agent-net.xml
virsh net-autostart agent-net
virsh net-start agent-net
ip -4 addr show virbr-agent          # confirm 10.13.13.1/24 is up
```

### 6e. nftables kill-switch

The agent's bridge is the only interface this table cares about — host-to-internet flows
are unchanged. The chain priorities and `policy drop` are what make this fail-closed.

Write `/etc/nftables.d/agent-killswitch.nft`:

```nft
#!/usr/sbin/nft -f
# Idempotent: drop any previous version
table inet ks
delete table inet ks
table inet ks {
    define BRIDGE = "virbr-agent"
    define UPLINK = "eth0"                 # CHANGE ME if you use wlan0
    define VPN_ENDPOINT = 1.2.3.4          # CHANGE ME: ProtonVPN Endpoint IP
    define VPN_PORT     = 51820            # CHANGE ME: ProtonVPN Endpoint port
    define LAN_BLOCK = {
        10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
        100.64.0.0/10, 169.254.0.0/16, 224.0.0.0/4
    }

    # Mark all agent UDP (except DNS) for fwmark routing into wg0
    chain mark {
        type filter hook prerouting priority -150; policy accept;
        iifname $BRIDGE udp dport != 53 meta mark set 0x2
    }

    # Transparent redirect: agent TCP → local Tor TransPort, DNS → Tor DNSPort
    # Allow the bridge gateway 10.13.13.1 to be the dest of the REDIRECT (kernel auto).
    chain nat_pre {
        type nat hook prerouting priority -150; policy accept;
        iifname $BRIDGE tcp dport 53 redirect to :5300
        iifname $BRIDGE udp dport 53 redirect to :5300
        iifname $BRIDGE meta l4proto tcp redirect to :9040
    }

    # Agent → host: only Tor ports on the bridge IP. Everything else dropped at INPUT
    # (we hook with policy drop here, but ONLY for the bridge; non-bridge iif keeps
    # the host's normal policy because we accept-then-return early.)
    chain input {
        type filter hook input priority 0; policy accept;
        iifname $BRIDGE tcp dport { 9040, 5300 } accept
        iifname $BRIDGE udp dport 5300 accept
        iifname $BRIDGE ct state established,related accept
        iifname $BRIDGE drop
    }

    # Forward: default drop. The only permitted agent egress is marked UDP onto wg0.
    # (TCP/DNS never reach forward — they're REDIRECTed into the host's INPUT chain.)
    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept
        ct state invalid drop
        iifname $BRIDGE ip daddr $LAN_BLOCK drop
        iifname $BRIDGE oifname "wg0" meta mark 0x2 accept
    }

    # Output: do NOT change the host's default policy. Only insert a guard so that the
    # HOST itself can reach the VPN endpoint on $UPLINK (wg-quick needs it), and block
    # any agent-induced output that somehow escaped to LAN (defense in depth).
    chain output {
        type filter hook output priority 0; policy accept;
        oifname $UPLINK ip daddr $VPN_ENDPOINT udp dport $VPN_PORT accept
        # If you tighten host egress later, do it here.
    }

    # SNAT agent UDP onto wg0's tunnel address so Proton accepts it and return traffic
    # finds its way back. Without this, UDP-via-VPN silently fails.
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "wg0" masquerade
    }
}
```

Load it at boot via the stock nftables service (which sources `/etc/nftables.conf`):

```bash
cat >>/etc/nftables.conf <<'EOF'

# Agent kill-switch (loaded after main rules; isolated table inet ks)
include "/etc/nftables.d/agent-killswitch.nft"
EOF
mkdir -p /etc/nftables.d
# place the file from above into /etc/nftables.d/agent-killswitch.nft
systemctl enable --now nftables
```

### 6f. Bring it up in the right order

The bridge must exist before Tor binds to its address. Pin the ordering via systemd:

```bash
mkdir -p /etc/systemd/system/tor@default.service.d
cat >/etc/systemd/system/tor@default.service.d/wait-for-bridge.conf <<'EOF'
[Unit]
After=libvirtd.service agent-mark-route.service
Requires=libvirtd.service
EOF
systemctl daemon-reload
systemctl enable --now libvirtd
systemctl enable --now wg-quick@wg0
systemctl enable --now tor@default
```

Confirm:
```bash
wg show wg0                              # latest handshake within ~minutes
ss -ltnp | grep -E ':(9040|5300)\s'      # tor listening on 10.13.13.1
nft list table inet ks | head            # kill-switch loaded
ip rule | grep 0x2                       # fwmark rule present
ip route show table 200                  # default via wg0 + blackhole metric 1000
```

---

## 7. Build the agent VM

### 7a. Storage layout (host paths)

```
/var/agent/
  ├── images/agent.qcow2          # agent root disk (qcow2, 20 GB)
  ├── images/triage.qcow2          # triage root disk (qcow2, 10 GB)
  ├── seeds/agent-debian-13.iso    # Debian netinst (read-only attach for install)
  └── shares/
      ├── in/    (host:rw, agent:ro)   # operator places input files here
      ├── out/   (host:rw, agent:rw)   # agent's exfil dropbox
      └── clean/ (host:rw, triage:rw)  # triage emits sanitized artifacts here
```

```bash
install -d -m 0750 -o libvirt-qemu -g kvm /var/agent/{images,seeds,shares/in,shares/out,shares/clean}
qemu-img create -f qcow2 /var/agent/images/agent.qcow2 20G
qemu-img create -f qcow2 /var/agent/images/triage.qcow2 10G
chown libvirt-qemu:kvm /var/agent/images/*.qcow2
```

### 7b. Create the agent VM

Use `virt-install` so we don't need a GUI. The key flags are: `--network network=agent-net`
(only this network, no others), no USB redirection, no shared clipboard, OVMF firmware,
and **no virtio-fs at install time** (we add the shares after install so the installer
doesn't write to them).

```bash
virt-install \
  --name agent-vm \
  --memory 4096 --vcpus 2 \
  --cpu host-passthrough,-vmx \
  --machine q35 --boot uefi \
  --osinfo debian13 \
  --disk path=/var/agent/images/agent.qcow2,format=qcow2,bus=virtio,discard=unmap \
  --cdrom /var/agent/seeds/agent-debian-13.iso \
  --network network=agent-net,model=virtio \
  --memorybacking source.type=memfd,access.mode=shared \
  --controller type=virtio-serial \
  --rng /dev/urandom \
  --graphics spice,clipboard.copypaste=no,filetransfer.enable=no \
  --noautoconsole
```

Install Debian 13 minimal — no desktop, no SSH server, no Avahi, no print services. Set a
strong root password; create one unprivileged user `agent`. After install:

```bash
virsh shutdown agent-vm
# Detach the install ISO:
virsh detach-disk agent-vm --target sda --config
```

**Lock down the libvirt definition** (`virsh edit agent-vm`):
- Remove any USB redirection (`<redirdev>`), SPICE clipboard (`<clipboard>`), filesystem
  passthrough not in §7c, and any extra `<interface>` elements.
- Confirm only ONE `<interface>` exists and it is `source network='agent-net'`.

### 7c. Attach the virtio-fs shares (one-way semantics enforced on host)

virtio-fs requires `<memoryBacking><access mode='shared'/></memoryBacking>` (already set by
`--memorybacking` above) and a `virtiofsd` per share. We use **two** shares with deliberately
asymmetric permissions on the host side:

```bash
# Inputs: host writes, agent reads. Lock by host filesystem mode.
chmod 0755 /var/agent/shares/in
# Outputs: agent writes, host reads later. The agent has no read-back guard here
# because the agent already authored these files — but host scripts must never
# execute anything in /var/agent/shares/out.

# Add the filesystem devices via virsh edit agent-vm, inside <devices>:
```

```xml
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs' queue='1024'/>
  <binary path='/usr/lib/virtiofsd' xattr='off'>
    <sandbox mode='chroot'/>
  </binary>
  <source dir='/var/agent/shares/in'/>
  <target dir='agent_in'/>
  <readonly/>
</filesystem>
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs' queue='1024'/>
  <binary path='/usr/lib/virtiofsd' xattr='off'>
    <sandbox mode='chroot'/>
  </binary>
  <source dir='/var/agent/shares/out'/>
  <target dir='agent_out'/>
</filesystem>
```

Inside the agent (after first boot with the shares attached), make the mount points
permanent in `/etc/fstab`:

```
agent_in   /mnt/in   virtiofs  ro,nosuid,nodev,noexec   0 0
agent_out  /mnt/out  virtiofs  rw,nosuid,nodev,noexec   0 0
```

`noexec` on both is belt-and-suspenders — even if the agent drops a binary in `/mnt/out`,
the host filesystem flags will prevent it from being executed inside the agent. On the host
side, never run anything out of `/var/agent/shares/out` directly; that's what the triage
VM is for (§8).

### 7d. Agent-side hardening

Inside `agent-vm`, before installing OpenClaw:

```bash
# No outbound DNS attempts that bypass /etc/resolv.conf
systemctl disable --now systemd-resolved 2>/dev/null || true
echo 'nameserver 10.13.13.1' > /etc/resolv.conf
chattr +i /etc/resolv.conf

# Disable IPv6 (the firewall already drops it, but no point generating traffic)
cat >/etc/sysctl.d/60-no-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl --system

# Set the default route once (DHCP from libvirt also does this; redundant but explicit)
ip route replace default via 10.13.13.1
```

Install OpenClaw as the `agent` user. All of its traffic now hits the host's nftables
table and is Tor/VPN-split.

> **Snapshot-by-design** is *not* free here as it was in Qubes. To get the same property —
> agent state resets on reboot — back up `agent.qcow2` once after install, then before each
> run: `qemu-img create -f qcow2 -F qcow2 -b agent.qcow2.golden agent.qcow2`. Boot from the
> overlay, discard it when done.

---

## 8. Moving data OUT of the agent VM — the secure path

The agent is untrusted, so two risks coexist: (a) the agent must not use data movement as
a covert exfil/identity channel, and (b) the data files themselves may be booby-trapped to
attack whatever opens them. The Qubes answer was `qvm-copy` + dom0 approval + an offline
vault VM. Here we approximate that with three pieces:

1. A **single, one-way virtio-fs share** is the agent's only path to the host filesystem.
2. A **transient, network-less triage VM** is the only thing that opens those files.
3. The operator **manually promotes** sanitized artifacts out of the triage VM.

### 8a. Why not a clipboard, network share, or SSH

- **Network share / SSH:** would defeat the seal — these are exactly the channels we built
  the firewall to forbid.
- **SPICE clipboard / filetransfer:** disabled in the libvirt definition (§7b); the SPICE
  agent inside the guest is not enabled and these would create a covert channel.
- **Shared block device (raw image attached to both VMs):** dangerous — concurrent mounts
  corrupt filesystems, and there's no human approval step.

### 8b. Build the triage VM

```bash
virt-install \
  --name triage-vm \
  --memory 2048 --vcpus 2 \
  --cpu host-passthrough,-vmx \
  --machine q35 --boot uefi \
  --osinfo debian13 \
  --disk path=/var/agent/images/triage.qcow2,format=qcow2,bus=virtio \
  --cdrom /var/agent/seeds/agent-debian-13.iso \
  --network none \
  --memorybacking source.type=memfd,access.mode=shared \
  --graphics spice,clipboard.copypaste=no,filetransfer.enable=no \
  --noautoconsole
```

Install Debian 13 minimal. After install, detach the ISO and `virsh edit triage-vm` to add
two virtio-fs shares:

```xml
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs' queue='1024'/>
  <binary path='/usr/lib/virtiofsd' xattr='off'><sandbox mode='chroot'/></binary>
  <source dir='/var/agent/shares/out'/>
  <target dir='from_agent'/>
  <readonly/>
</filesystem>
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs' queue='1024'/>
  <binary path='/usr/lib/virtiofsd' xattr='off'><sandbox mode='chroot'/></binary>
  <source dir='/var/agent/shares/clean'/>
  <target dir='clean'/>
</filesystem>
```

Inside triage-vm, install the sanitizers and keep nothing else:

```bash
apt install --no-install-recommends -y poppler-utils qpdf imagemagick file
```

In `/etc/fstab`:
```
from_agent  /mnt/from-agent  virtiofs  ro,nosuid,nodev,noexec  0 0
clean       /mnt/clean       virtiofs  rw,nosuid,nodev,noexec  0 0
```

Confirm `virsh dumpxml triage-vm | grep -c interface` is **0** — no NIC. The triage VM is
air-gapped by design; any exploit detonating in it cannot phone home.

### 8c. The extraction ritual

When the agent has produced something you want to inspect:

```bash
# On the host
virsh start triage-vm
virsh console triage-vm           # or ssh-equivalent via virsh console
```

Inside triage-vm:
```bash
ls /mnt/from-agent/
file /mnt/from-agent/*            # cheap, identifies booby-traps by magic
# Sanitize before anything trusted touches it:
qpdf --linearize /mnt/from-agent/results.pdf /mnt/clean/results.pdf
pdftotext /mnt/from-agent/results.pdf /mnt/clean/results.txt
# For images, re-encode through ImageMagick to flatten EXIF/embedded payloads:
convert /mnt/from-agent/figure.png -strip /mnt/clean/figure.png
```

On the host, after `virsh shutdown triage-vm`, move sanitized artifacts off:
```bash
# /var/agent/shares/clean/ now has only flattened, inspected outputs.
rsync -av /var/agent/shares/clean/ ~/agent-deliverables/$(date +%F)/
```

### 8d. Putting data INTO the agent (e.g. a JSON input file)

This is the one *trusted → untrusted* flow. Author the file on your real workstation, then
drop it into `/var/agent/shares/in/` on the host *before starting the agent run*. The agent
sees it at `/mnt/in/<filename>` (read-only). Do not place secrets, real IPs, hostnames, or
identity-linked credentials in this file — the agent is untrusted and will know whatever
you put in `/mnt/in`.

### 8e. What the agent CANNOT do

- Read `/var/agent/shares/clean` (not shared into agent-vm at all).
- Read or write any other host path (only the two declared virtio-fs targets are visible).
- Open a network socket that escapes Tor or wg0 (the firewall enforces this; §6e).
- Send to the triage VM directly (no shared network; the only shared path is the host-
  owned `out/` directory, and only via a deliberate `virsh start triage-vm` from the
  operator).

---

## 9. Verification & leak tests

Run on **`agent-vm`** unless noted.

**TCP via Tor:**
```bash
curl -s https://check.torproject.org/api/ip   # expect {"IsTor":true,"IP":"<exit>"}
```

**DNS via Tor:** `getent hosts example.com` resolves. On the host:
```bash
sudo tcpdump -ni eth0 'port 53'               # MUST show nothing in clear
sudo tcpdump -ni virbr-agent 'port 5300'      # the redirect target, fine
```

**UDP via ProtonVPN:** on the host `sudo tcpdump -ni wg0 udp`, then from `agent-vm`
generate UDP (HTTP/3/QUIC works, or `dig +tcp=no @1.1.1.1` is blocked, but a real QUIC
client should produce traffic). A UDP-path IP check should report the Proton IP, distinct
from the Tor exit. Quick check from inside the agent:
```bash
curl --http3-only -s https://cloudflare-quic.com/ | head    # exits via wg0
```

**LAN-seal (critical):** from `agent-vm`, all of these must FAIL:
```bash
ping -c2 192.168.1.1        # your router
ping -c2 192.168.1.50       # any home device
nmap -sn 192.168.1.0/24     # must discover nothing
ip neigh                     # must show ONLY 10.13.13.1
```

**Kill-switch:** on the host, drop each tunnel in turn and confirm the agent's traffic stops
without falling back to clearnet:
```bash
sudo systemctl stop tor@default                 # agent TCP must immediately fail
# (do not test by curling from the agent — test by tcpdumping eth0 for any agent-related
#  destination; you should see NONE)
sudo systemctl start tor@default

sudo systemctl stop wg-quick@wg0                # agent UDP must blackhole
sudo systemctl start wg-quick@wg0
```

**Data path:** from `agent-vm`, write a marker into `/mnt/out/`, confirm the host sees it
in `/var/agent/shares/out/`, confirm the **triage-vm cannot see** anything in `/mnt/clean`
written from the agent side (the agent has no mount of `clean/`). Confirm `/mnt/in/` is
read-only inside the agent:
```bash
touch /mnt/in/x   # expect EROFS
```

**Virtualization smoke test:** inside the agent,
```bash
dmidecode -s system-manufacturer 2>/dev/null    # 'QEMU' — confirms it's a guest
ip -4 addr show                                 # only 10.13.13.10/24
ip route                                        # default via 10.13.13.1
```

---

## 10. Operational notes

- **Boot order is enforced by systemd** (§6f). `libvirtd` brings up `virbr-agent`, then
  `agent-mark-route` adds the policy route, then `wg-quick@wg0` connects, then
  `tor@default` binds. Reboot the host and watch `systemd-analyze critical-chain
  tor@default.service` if anything is wrong.
- **Free-server rotation:** when Proton retires your server, re-download the config,
  replace `/etc/wireguard/wg0.conf`, update `VPN_ENDPOINT`/`VPN_PORT` in
  `/etc/nftables.d/agent-killswitch.nft`, then
  `systemctl reload nftables && systemctl restart wg-quick@wg0`.
- **Secrets:** `wg0.conf` holds the WireGuard private key — `0600 root:root`, FDE on the
  host disk, never in git, never in a backup that leaves the device unencrypted.
- **Clock:** chrony/timesyncd over the clearnet uplink is fine. Tor needs a sane clock; if
  the laptop loses time on suspend, `chronyc -a 'makestep'` at resume.
- **Updates:** unattended-upgrades handles the host. Update the agent and triage guests on
  your own schedule — they run minimal Debian; `apt update && apt upgrade` from inside
  each (the agent's updates flow through Tor, which is slow but correct).
- **Suspend/resume:** wg0 typically survives suspend, but Tor circuits do not — they
  rebuild in seconds. The agent will see a brief network blip; that's fine.
- **Two-VM RAM footprint:** ~5.5 GB committed when only `agent-vm` is up; ~7.5 GB when
  triage is also up. On 8 GB hardware, shut down `agent-vm` before starting `triage-vm`
  if you feel pressure.

---

## 11. Limitations & caveats

- **One VM boundary, not two.** Unlike Qubes (`sys-net` + `sys-firewall` + `sys-split` + `agent-vm`
  = three VM boundaries between the agent and the real IP), here a single KVM boundary
  separates the agent from a host that holds the real IP, runs Tor and WireGuard, and
  carries your admin tools. A guest-to-host escape via a KVM/virtio CVE owns everything.
- **No netless admin domain.** The host has internet, by necessity (Tor and WG need it).
  Treat the host as a production target: minimal packages, AppArmor on, unattended-upgrades
  on, no extra services, no personal data, no shared credentials.
- **Two egress identities.** TCP exits as a Tor relay, UDP as a ProtonVPN IP; an adversary
  observing both can correlate that one machine uses both. The split exists because Tor
  cannot carry UDP — it's capability, not anonymity gain. If you don't need UDP, replace
  §6b/§6c/the wg0 rules with **Tor-only** (the simpler subset of §11 in the previous design).
- **Custom code in the trust path.** The nftables ruleset (§6e) is *the* fail-closed
  property. Read it once for every change. The `forward` chain `policy drop` plus the
  `output` blackhole route are the only things preventing a clearnet leak.
- **virtio-fs is shared host code.** `virtiofsd` runs on the host as a separate process and
  is sandboxed (`<sandbox mode='chroot'/>`), but it is still attack surface. The same is
  true for virtio-blk and the SPICE/QXL stack. Keep the host kernel and `qemu`/`virtiofsd`
  current.
- **Free ProtonVPN constraints:** limited servers, one connection, no port-forwarding,
  variable speed — fine for low-bandwidth agent UDP, not heavy use.
- **Application-layer leaks persist.** Logins, browser fingerprinting, identifying file
  metadata defeat network anonymity regardless. Give the agent only throwaway credentials.
- **Not unbreakable.** A Linux/KVM/virtio escape defeats all of this; keep the host
  patched. Still, this is materially stronger than running the agent natively on your
  laptop or in a Docker container.
- **You trust** ProtonVPN for UDP and the Tor network for TCP.

---

## 12. Quick build checklist

- [ ] Ubuntu 24.04 LTS Server installed (verified ISO, FDE on, minimal install)
- [ ] AppArmor + unattended-upgrades enabled; UFW disabled; IPv6 off; `net.ipv4.ip_forward=1`
- [ ] Packages installed: `tor`, `wireguard`, `nftables`, `qemu-system-x86`,
      `libvirt-daemon-system`, `virtinst`, `virtiofsd`, `ovmf`, `swtpm`
- [ ] `/etc/tor/torrc`: `TransPort 10.13.13.1:9040`, `DNSPort 10.13.13.1:5300`,
      `ClientOnly 1`, `ExitRelay 0`
- [ ] `/etc/wireguard/wg0.conf`: free Proton, `Table=off`, no `DNS=`, endpoint recorded, 0600
- [ ] `agent-mark-route.service` enabled (`fwmark 0x2 → table 200 → wg0` + blackhole)
- [ ] libvirt network `agent-net` defined with `forward mode='open'`, bridge `virbr-agent`,
      10.13.13.1/24, single DHCP lease
- [ ] `/etc/nftables.d/agent-killswitch.nft` loaded (table `inet ks`, default-drop forward,
      LAN_BLOCK, VPN endpoint pinned, masquerade on wg0)
- [ ] tor.service ordered `After=libvirtd.service agent-mark-route.service`
- [ ] `agent-vm`: 4 GB RAM, ONE NIC on `agent-net`, OVMF firmware, virtio-fs `in` (ro) and
      `out` (rw), no SPICE clipboard, no USB redirect, no second interface
- [ ] `triage-vm`: 2 GB RAM, **no NIC**, virtio-fs `out` (ro) and `clean` (rw), sanitizer
      tools installed
- [ ] Verified: Tor TCP ✓, Tor DNS ✓, Proton UDP ✓, LAN unreachable ✓, kill-switch ✓,
      `/mnt/in` read-only inside agent ✓, triage has no NIC ✓

---

Sources for ProtonVPN free-tier WireGuard config availability:
- [How to download WireGuard configuration files — Proton VPN](https://protonvpn.com/support/wireguard-configurations)
- [How to manually configure WireGuard on Linux — Proton VPN](https://protonvpn.com/support/wireguard-linux)

References for the host-side mechanisms used above:
- [virtio-fs in libvirt](https://libvirt.org/kbase/virtiofs.html)
- [nftables `inet` family and `nat hook prerouting`](https://wiki.nftables.org/wiki-nftables/index.php/Main_Page)
- [WireGuard `Table = off` semantics](https://www.wireguard.com/quickstart/) and `wg-quick(8)`
