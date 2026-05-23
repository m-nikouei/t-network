# Fail-Closed Split-Tunnel Firewall for an Untrusted Agent (Qubes OS)

A design + build guide for running an autonomous agent (e.g. an **OpenClaw** computer-use
agent) inside a Qubes OS qube that is **fail-closed**, **identity-sealed**, and from which
data can only leave through an **audited, network-free path**:

- If the anonymizing tunnels are down, **nothing leaves** (no clearnet fallback).
- The agent qube never learns the host's real/public IP.
- The agent qube **cannot reach, leak to, or even discover** your home/LAN network.
- Traffic is split by protocol: **TCP → Tor**, **UDP (non-DNS) → ProtonVPN**, **DNS → Tor**.
- Data is moved out of the agent qube via `qvm-copy` (qrexec, human-approved) into an
  **offline vault qube**, never over the network or a shared folder.

> **Status:** planning/build document. Placeholders are `CAPS` / `# CHANGE ME`. The agent
> is treated as **hostile even with root inside its qube**. Read §11 before relying on this.

---

## 1. Why Qubes (and the one thing it does *not* give you)

Qubes OS is a type-1 (Xen) hypervisor where every workload is a *qube* (VM) and the admin
domain **dom0 has no network at all**. This is a much harder boundary than VirtualBox: the
agent's qube is isolated by Xen, the network hardware lives in its own `sys-net` qube, and
data movement between qubes is mediated by dom0 over qrexec rather than shared memory.

**What Qubes gives you for free:** strong VM isolation, a no-network admin domain, a
built-in Tor gateway (`sys-whonix`), disposable VMs, and an audited inter-qube file-copy.

**What it does *not* give you:** the **TCP-Tor / UDP-ProtonVPN split**. `sys-whonix` is
Tor-only and drops UDP. Because *both* tunnels (Tor circuits and the WireGuard handshake)
need raw clearnet transport, you cannot chain them (WireGuard-over-Tor can't even
handshake). The split must therefore live in **one custom ProxyVM, `sys-split`**, that sits
directly above the clearnet path and runs Tor + WireGuard + the kill-switch firewall
itself. Qubes provides the isolation around it; this guide provides the split.

---

## 2. Threat model & goals

| Goal | How it's achieved |
|------|-------------------|
| Agent cannot discover the host's external IP | `sys-net` (which holds the real IP) is two qubes upstream and NAT'd at each Qubes link. The agent only ever sees `sys-split`'s gateway address. |
| Agent cannot reach the home/LAN network | Agent's only netvm is `sys-split`, which **drops all RFC1918/LAN destinations** and forces TCP→Tor, UDP→VPN. Neither tunnel can address a local device. |
| Agent cannot even *learn the LAN exists* | It only sees Qubes' internal `10.137.x.x` link to `sys-split`; scans/ARP/DNS to `192.168.x/10.x/172.16.x` are dropped or anonymized. |
| No clearnet leaks, ever | `sys-split` firewall is **default DROP** on forward/output. Egress allowed *only* to the ProtonVPN endpoint and the `debian-tor` user. |
| No DNS / IPv6 leaks | Port 53 REDIRECTed to Tor `DNSPort`; IPv6 disabled; firewall is `inet` (v4+v6). |
| Data leaves only through a controlled path | `qvm-copy` over qrexec (human-approved in dom0) into an **offline** vault qube; no network, no shared folder, no clipboard exfil. See §8. |

**Out of scope:** a Xen/Qubes 0-day escape, a malicious host before you wipe it, hardware
implants, and a global passive adversary correlating the Tor exit vs. ProtonVPN IP (§11).

---

## 3. Architecture (Qubes qube chain)

```
   dom0  (admin domain — NO network, controls everything, never touches the agent)

   sys-net      ── physical NIC / Wi-Fi; holds the REAL IP + sees the home LAN
      ▲
   sys-firewall ── stock Qubes firewall qube
      ▲
   sys-split    ── *** the custom ProxyVM you build ***
      │             • Tor  TransPort 9040 / DNSPort 5300   (TCP + DNS)
      │             • WireGuard wg0 → ProtonVPN free        (UDP)
      │             • nftables: DEFAULT DROP + LAN-block (kill switch)
      │             eth0 = uplink (to sys-firewall) ; vif* = downstream (agent)
      ▲
   agent-vm     ── runs OpenClaw (UNTRUSTED); netvm = sys-split; no other net
      │
      └── qvm-copy (qrexec, dom0-approved) ──▶ agent-out  (OFFLINE vault, netvm=none)
                                                    │
                                                    └─ inspect / qvm-convert-pdf /
                                                       open in DisposableVM, then
                                                       move only sanitized results out
```

**Traffic flow from the agent:**

```
 TCP  ──▶ sys-split redirect ──▶ Tor TransPort ──▶ Tor circuit ──▶ Internet
 DNS  ──▶ sys-split redirect ──▶ Tor DNSPort  ──▶ Tor circuit ──▶ resolve
 UDP  ──▶ sys-split mark+route ─▶ wg0 ──▶ ProtonVPN ──▶ Internet
 LAN / clearnet / tunnels-down ───────────────────────────────────▶ DROP
```

---

## 4. Prerequisites

- A laptop you can **wipe** that meets Qubes hardware requirements: 64-bit, **VT-x + VT-d
  (IOMMU)**, ≥16 GB RAM recommended, ≥64 GB SSD. Check the Qubes HCL before committing.
- Qubes OS **4.2** installer (verify the signature per Qubes docs before flashing USB).
- A **ProtonVPN free** account. Free supports manual WireGuard but with limits: free-tier
  servers only, **one** connection, no port-forwarding/P2P, possibly slower; the only
  config toggle is VPN Accelerator.
- Comfort with a terminal in dom0 and in a Debian-based template.

---

## 5. Install Qubes & lay out the qubes

1. Flash the verified Qubes 4.2 ISO, boot the laptop from it, and install (full-disk
   encryption on; this becomes the dedicated host). Complete the first-boot wizard — it
   creates `dom0`, `sys-net`, `sys-firewall`, default templates, and (optionally) Whonix.
2. Update everything: **Qubes Manager → update**, or in dom0
   `sudo qubes-dom0-update` and update each template.
3. You will create three new qubes:
   - **`sys-split`** — the ProxyVM that does the Tor/VPN split (built in §6).
   - **`agent-vm`** — the untrusted AppVM running OpenClaw (§7).
   - **`agent-out`** — an **offline** vault qube for receiving data (§8).

Use a dedicated **template clone** for `sys-split` so the Tor/WireGuard packages don't end
up in your other qubes. In dom0:
```bash
qvm-clone debian-12 t-split        # template just for the proxy
```

---

## 6. Build `sys-split` (Tor + ProtonVPN split + kill switch)

### 6a. Install software into the template
Open a terminal in the **`t-split` template** (Qubes Manager → t-split → Run Terminal):
```bash
sudo apt update
sudo apt install -y tor wireguard nftables
sudo systemctl disable tor      # we start it ourselves, per-qube, from /rw
sudo poweroff
```

### 6b. Create the ProxyVM
In dom0:
```bash
qvm-create --class AppVM --template t-split --label red sys-split
qvm-prefs sys-split provides_network True     # makes it usable as a netvm
qvm-prefs sys-split netvm sys-firewall        # its own uplink = clearnet path
qvm-prefs sys-split memory 600
qvm-prefs sys-split maxmem 1024
```

### 6c. Persistent config lives in `/rw` (ProxyVM root is not persistent)
Everything system-level in a qube resets on reboot **except** its private volume `/rw`.
Qubes runs two persistent hooks for us:
- `/rw/config/rc.local` — root script at startup (start Tor + WireGuard, set routes).
- `/rw/config/qubes-firewall-user-script` — runs after Qubes sets up its firewall (load
  our nftables). This is the correct, conflict-free place for custom rules.

Open a terminal in **`sys-split`** and create the files below.

**`/rw/config/torrc`:**
```ini
User debian-tor
DataDirectory /var/lib/tor
SocksPort 0
TransPort 0.0.0.0:9040
DNSPort   0.0.0.0:5300
AutomapHostsOnResolve 1
VirtualAddrNetworkIPv4 10.192.0.0/10
```
(Binding `0.0.0.0` is safe: the firewall only lets downstream `vif*` clients reach these
ports.)

### 6d. ProtonVPN (free) WireGuard config
On any trusted qube, sign in at **account.protonvpn.com → Downloads → WireGuard
configuration**, name it short (**<15 chars**, letters/underscores), pick a **free**
server, download the `.conf`, then `qvm-copy` it into `sys-split`. Place it at
**`/rw/config/wg0.conf`** and edit:
```ini
[Interface]
PrivateKey = CHANGE_ME
Address = 10.2.0.2/32
# DNS = ...        ← DELETE (DNS goes through Tor, not Proton)
Table = off         ← ADD (we route UDP into wg0 ourselves; no catch-all route)

[Peer]
PublicKey = CHANGE_ME
AllowedIPs = 0.0.0.0/0
Endpoint = PROTON_SERVER_IP:51820   # record this IP + port for the firewall
```
```bash
sudo chmod 600 /rw/config/wg0.conf
```

### 6e. Startup hook — `/rw/config/rc.local`
```sh
#!/bin/sh
# Tor (transparent TCP + DNS), running as debian-tor so the firewall can key on its UID
install -d -o debian-tor -g debian-tor /var/lib/tor
pkill -u debian-tor tor 2>/dev/null
sudo -u debian-tor tor -f /rw/config/torrc --runasdaemon 1

# ProtonVPN WireGuard (Table=off → does not touch the main route table)
wg-quick up /rw/config/wg0.conf

# Policy routing: packets marked 0x2 (workstation UDP) leave via the VPN tunnel
ip rule add fwmark 0x2 table 200 2>/dev/null || true
ip route replace default dev wg0 table 200
# Fail-closed at the routing layer too: if wg0 drops, its route vanishes and marked
# UDP hits this blackhole instead of falling through to clearnet.
ip route add blackhole default metric 1000 table 200 2>/dev/null || true
```
```bash
sudo chmod +x /rw/config/rc.local
```

### 6f. Kill-switch firewall — `/rw/config/qubes-firewall-user-script`
These rules are **additive** to Qubes' own firewall: we add a separate `inet ks` table
whose base chains use `policy drop`, so a packet must be explicitly accepted by *our* rules
*and* survive Qubes' rules — most-restrictive wins. Fill in the two `VPN_*` defines.

```sh
#!/bin/sh
nft -f - <<'EOF'
table inet ks { }            # idempotent: drop any previous version
delete table inet ks
table inet ks {
    # private/LAN ranges the agent must never reach (10.137/16 ⊂ 10/8 also blocks
    # sibling qubes); excludes nothing we legitimately need on egress.
    define LAN_BLOCK = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, 224.0.0.0/4 }
    define VPN_ENDPOINT = 1.2.3.4      # CHANGE ME: ProtonVPN Endpoint IP
    define VPN_PORT     = 51820        # CHANGE ME: ProtonVPN Endpoint port

    # mark downstream (agent) UDP, except DNS, for routing into wg0
    chain mark {
        type filter hook prerouting priority -150; policy accept;
        iifname "vif*" udp dport != 53 meta mark set 0x2
    }
    # transparent redirect: TCP→Tor TransPort, DNS→Tor DNSPort
    chain nat_pre {
        type nat hook prerouting priority -150; policy accept;
        iifname "vif*" tcp dport 53 redirect to :5300
        iifname "vif*" udp dport 53 redirect to :5300
        iifname "vif*" meta l4proto tcp redirect to :9040
    }
    # let the agent reach only the local Tor listeners (additive accept)
    chain input {
        type filter hook input priority 0; policy accept;
        iifname "vif*" tcp dport { 9040, 5300 } accept
        iifname "vif*" udp dport 5300 accept
    }
    # FORWARD: default drop. Only marked UDP to the VPN tunnel; LAN blocked.
    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept
        ct state invalid drop
        iifname "vif*" ip daddr $LAN_BLOCK drop
        iifname "vif*" oifname "wg0" meta mark 0x2 accept
    }
    # OUTPUT: default drop. Only WireGuard→Proton and Tor's own connections; LAN blocked.
    chain output {
        type filter hook output priority 0; policy drop;
        oifname "lo" accept
        ct state established,related accept
        oifname "eth0" ip daddr $VPN_ENDPOINT udp dport $VPN_PORT accept
        oifname "eth0" ip daddr $LAN_BLOCK drop
        oifname "eth0" meta skuid "debian-tor" accept
    }
    # SNAT the agent's UDP onto the tunnel address (10.2.0.2) so ProtonVPN accepts it
    # and return traffic routes back. Without this, UDP-via-VPN silently fails.
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "wg0" masquerade
    }
}
EOF
```
```bash
sudo chmod +x /rw/config/qubes-firewall-user-script
```

Disable IPv6 in `sys-split` (and `agent-vm`) by adding to `/rw/config/rc.local`:
```sh
sysctl -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
```
Reboot the qube: `qvm-shutdown --wait sys-split` then start it. Confirm `wg show` lists a
recent handshake and `ss -ltnp | grep 9040` shows Tor listening.

> The hardcoded VPN endpoint IP means `sys-split` needs **no DNS** to come up, and the
> kill switch keys to that exact endpoint — a stale/retired free server simply fails closed.

---

## 7. `agent-vm` (the untrusted OpenClaw qube)

In dom0:
```bash
qvm-create --class AppVM --template debian-12 --label orange agent-vm
qvm-prefs agent-vm netvm sys-split        # its ONLY network path
qvm-firewall agent-vm reset               # then lock to deny-all outbound at Qubes layer
qvm-firewall agent-vm add action=drop     # belt-and-suspenders; sys-split already enforces
```
Hardening for the hostile agent:
- **netvm = sys-split only.** No second interface, no direct `sys-net`.
- **No qrexec to arbitrary qubes.** We lock the file-copy policy in §8 so the agent can only
  push data to `agent-out`.
- **Restrict clipboard.** Qubes' inter-qube clipboard (Ctrl+Shift+C/V) is manual, but you
  can deny it from the agent in dom0 `/etc/qubes/policy.d/30-agent.policy`:
  ```
  qubes.ClipboardPaste  *  agent-vm  @anyvm  deny
  ```
- **No block-device / USB attach** to this qube. Don't pass it any PCI or USB device.
- **Snapshot-by-design:** an AppVM's root resets on reboot; keep the agent's working data in
  its `/home` only, and reboot it between runs to discard root-level tampering.

Install/run OpenClaw inside `agent-vm` as you would normally; all of its traffic is now
Tor/VPN-split and fail-closed.

---

## 8. Moving data OUT of the agent qube — the secure path

The agent is untrusted, so two risks must be handled at once: (a) the agent must not use
data movement as a covert exfil/identity channel, and (b) the data files themselves may be
booby-trapped to attack whatever opens them. The Qubes-native answer addresses both.

**Principle: never move data over the network, a shared folder, or the clipboard. Use
`qvm-copy` (qrexec), which is mediated by dom0 and works even though the agent is network-
sealed — it travels over a vchan through dom0, not over IP.**

### 8a. Create an offline vault to receive data
```bash
qvm-create --class AppVM --template debian-12 --label black agent-out
qvm-prefs agent-out netvm none        # AIR-GAPPED: no network at all
```
A booby-trapped file from the agent detonates here, in a qube that cannot phone home.

### 8b. Lock down where the agent may copy (dom0 qrexec policy)
Create `/etc/qubes/policy.d/30-agent-data.policy` in **dom0** (covers both directions;
first-match wins, so the `allow`/`ask` lines precede the broad `deny`):
```
## OUTBOUND: the agent may push files only to the offline vault, with a dom0 prompt
qubes.Filecopy  *  agent-vm       agent-out  ask default_target=agent-out
qubes.Filecopy  *  agent-vm       @anyvm     deny
## INBOUND: only your trusted staging qube may hand files to the agent, with a prompt
qubes.Filecopy  *  agent-staging  agent-vm   ask default_target=agent-vm
qubes.Filecopy  *  @anyvm         agent-vm   deny
```
`ask` surfaces a dom0 confirmation you must approve for every copy (use `allow` only if you
want it silent). The agent can therefore push files **only** to `agent-out`, and **only**
`agent-staging` can hand files to the agent — nothing else in either direction.

### 8c. Copy, then sanitize before anything trusted touches it
From inside `agent-vm` (or its file manager → "Copy to other qube"):
```bash
qvm-copy ~/work/results.pdf ~/work/output.csv
```
Files arrive in `agent-out` under `~/QubesIncoming/agent-vm/`. In `agent-out`:
- **Inspect** text/CSV/logs directly — it's offline, so even if you trip something it can't
  exfiltrate.
- **Sanitize risky formats.** For documents/images, use Qubes' trusted-conversion tools,
  which rasterize the file inside a throwaway DisposableVM and emit a flattened, safe copy:
  ```bash
  qvm-convert-pdf ~/QubesIncoming/agent-vm/results.pdf      # → trusted, de-fanged PDF
  # (and qvm-convert-img for images)
  ```
- **Open unknown files in a DisposableVM**, never in a long-lived trusted qube:
  ```bash
  qvm-open-in-dvm ~/QubesIncoming/agent-vm/unknown.html
  ```
  The dispVM is destroyed on close, taking any exploit with it.

### 8d. Promote only the sanitized result
Only after sanitizing, `qvm-copy` the *cleaned* artifact from `agent-out` to your real work
qube. The untrusted original never touches your trusted environment.

> **Why not a shared folder or the network?** A shared folder is a persistent host↔guest
> channel the agent can abuse continuously; the network is exactly what we sealed. `qvm-copy`
> is a one-shot, human-approved, dom0-mediated transfer — the smallest possible surface.

### 8e. Putting data INTO the agent (e.g. a JSON input file)
Same qrexec path, reversed. This is the one *trusted → untrusted* flow, so it's lower risk
to you than extraction — but keep it one-shot (`qvm-copy`), never a persistent share.

1. Author the JSON in a trusted, offline staging qube:
   ```bash
   qvm-create --class AppVM --template debian-12 --label gray agent-staging
   qvm-prefs agent-staging netvm none        # offline; it only stages input files
   ```
2. From `agent-staging`, copy the file into the agent (or file manager → "Copy to other
   qube" → `agent-vm`):
   ```bash
   qvm-copy-to-vm agent-vm ~/task-input.json
   ```
   Approve the dom0 prompt. It lands in `agent-vm` at
   `~/QubesIncoming/agent-staging/task-input.json`; point OpenClaw at that path (or move it
   to a fixed location inside the agent).
3. **Scrub the contents first.** The agent is untrusted, so treat everything in the JSON as
   something the agent *will* know and could try to exfiltrate (it can only do so through
   the anonymized tunnels, but least-privilege still applies). Do **not** include your real
   IP, home-network details, hostnames, personal identifiers, or identity-linked
   credentials — only the task's actual inputs and throwaway tokens.

---

## 9. Verification & leak tests

Run on **`agent-vm`** unless noted.

**TCP via Tor:**
```bash
curl -s https://check.torproject.org/api/ip      # expect {"IsTor":true,"IP":"<exit>"}
```
**DNS via Tor:** `dig example.com` succeeds; in `sys-split`, `sudo tcpdump -ni eth0 port 53`
shows nothing in clear.

**UDP via ProtonVPN:** in `sys-split` run `sudo tcpdump -ni wg0 udp`, then from `agent-vm`
generate UDP (HTTP/3/QUIC) and confirm it appears on `wg0`; a UDP-path IP check reports the
Proton IP, distinct from the Tor exit.

**LAN-seal (critical):** from `agent-vm`, everything below must FAIL:
```bash
ping -c2 192.168.1.1        # your router
ping -c2 192.168.1.50       # any home device
nmap -sn 192.168.1.0/24     # must discover nothing
```
**Kill-switch:** in `sys-split`, `sudo pkill -u debian-tor tor` → agent TCP fails (not
clearnet); `sudo wg-quick down /rw/config/wg0.conf` → agent UDP blackholes. Restart the qube
to restore.

**Data path:** confirm `qvm-copy` from `agent-vm` to a non-`agent-out` qube is **denied**,
and to `agent-out` requires the dom0 prompt.

---

## 10. Operational notes

- **Boot order:** `sys-net → sys-firewall → sys-split → agent-vm`. Qubes starts netvms
  first automatically.
- **Free-server rotation:** if Proton retires your free server, re-download the config,
  replace `/rw/config/wg0.conf`, update `VPN_ENDPOINT`/`VPN_PORT` in the firewall script,
  and restart `sys-split`.
- **Secrets:** `wg0.conf` holds your WireGuard private key — `0600`, stays in `sys-split`'s
  `/rw` only, never in a shared/synced location.
- **Clock:** Qubes syncs time over qrexec (not the network), so Tor's clock stays sane.
- **Updates:** keep dom0 and all templates updated; template updates flow into qubes on
  their next boot.

---

## 11. Limitations & caveats

- **Two egress identities.** TCP exits as a Tor relay, UDP as a ProtonVPN IP; an adversary
  observing both could correlate that one machine uses both. The split exists because Tor
  can't carry UDP — capability, not anonymity gain. If you don't need UDP, just set
  `agent-vm`'s netvm to **`sys-whonix`** and skip `sys-split` entirely (Tor-only, simpler,
  more audited).
- **`sys-split` is custom code in the trust path.** Unlike `sys-whonix`, you built it; review
  the rules. The fail-closed property rests on the `policy drop` forward/output chains.
- **Free ProtonVPN constraints:** limited servers, one connection, no port-forwarding,
  variable speed — fine for low-bandwidth agent UDP, not heavy use.
- **Application-layer leaks persist.** Logins, browser fingerprinting, and identifying file
  metadata defeat network anonymity regardless. Give the agent only throwaway credentials.
- **Not unbreakable.** A Xen/Qubes escape defeats all of this; keep Qubes patched. Still,
  this is materially stronger than VirtualBox/KVM for an untrusted agent.
- **You trust** ProtonVPN for UDP and the Tor network for TCP.

---

## 12. Quick build checklist

- [ ] Qubes 4.2 installed on the wiped laptop (verified ISO, FDE on)
- [ ] `t-split` template: `tor wireguard nftables` installed, system `tor` disabled
- [ ] `sys-split`: `provides_network=True`, netvm=`sys-firewall`, IPv6 off
- [ ] `/rw/config/torrc` (TransPort 9040 / DNSPort 5300, User debian-tor)
- [ ] `/rw/config/wg0.conf` (free Proton, `Table=off`, no `DNS=`, endpoint recorded, 0600)
- [ ] `/rw/config/rc.local` (start Tor + wg-quick + `fwmark 0x2 → table 200 → wg0`)
- [ ] `/rw/config/qubes-firewall-user-script` (default-drop kill switch + LAN_BLOCK)
- [ ] `agent-vm`: netvm=`sys-split`, clipboard denied, no USB/PCI, deny-all Qubes firewall
- [ ] `agent-out`: netvm=`none` (offline vault, for extracted data)
- [ ] `agent-staging`: netvm=`none` (offline, for authoring JSON inputs)
- [ ] dom0 `30-agent-data.policy`: out → only `agent-out`; in → only from `agent-staging`; all else deny
- [ ] Verified: Tor TCP ✓, Tor DNS ✓, Proton UDP ✓, LAN unreachable ✓, kill-switch ✓, copy locked ✓

---

Sources for ProtonVPN free-tier WireGuard config availability:
- [How to download WireGuard configuration files — Proton VPN](https://protonvpn.com/support/wireguard-configurations)
- [How to manually configure WireGuard on Linux — Proton VPN](https://protonvpn.com/support/wireguard-linux)
