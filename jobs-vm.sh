#!/bin/bash
# Build (or rebuild) the job VM non-interactively from a Debian cloud image.
# No installer: the cloud image boots, cloud-init creates the 'ops' user with your
# SSH key, mounts the virtio-fs share, and seals DNS/IPv6. The VM's only NIC is on
# the isolated 'jobs-net' bridge, so all of its egress is forced through Tor/VPN.
#
#   sudo SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" DATA_DISK=900G ./jobs-vm.sh
#   (or DATA_DEV=/dev/sdX to hand the VM a raw block device for /data — fastest)
#
# Requires: setup.sh already run (jobs-net + /var/jobs exist). Root.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo $0)"; exit 1; }

VM="${VM:-jobs-vm}"
RAM_MB="${RAM_MB:-3072}"
VCPUS="${VCPUS:-2}"
DISK="${DISK:-30G}"                         # OS root disk (small — scratch goes on /data)
DATA_DISK="${DATA_DISK:-900G}"              # big scratch disk mounted at /data in the VM
DATA_DEV="${DATA_DEV:-}"                    # optional: pass a host block device/LV/partition
                                            # instead of an image file (best for performance)
DATA_FS="${DATA_FS:-xfs}"                   # filesystem for /data (xfs handles large/parallel)
JOBS_ROOT="/var/jobs"
IMG="$JOBS_ROOT/images/jobs.qcow2"
DATA_IMG="$JOBS_ROOT/images/data.img"
BASE="$JOBS_ROOT/images/base-debian13.qcow2"
CLOUDIMG_URL="${CLOUDIMG_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2}"

say(){ printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m!! %s\033[0m\n' "$*"; exit 1; }

[ -n "${SSH_PUBKEY:-}" ] || die "set SSH_PUBKEY to your public key, e.g. SSH_PUBKEY=\"\$(cat ~/.ssh/id_ed25519.pub)\""
virsh net-info jobs-net >/dev/null 2>&1 || die "jobs-net not defined — run ./setup.sh first"

# Refuse to clobber a running VM silently.
if virsh dominfo "$VM" >/dev/null 2>&1; then
  die "$VM already exists. To rebuild: sudo virsh destroy $VM 2>/dev/null; sudo virsh undefine --nvram $VM; then re-run."
fi

say "1/4  fetch base cloud image (verify the published checksum yourself)"
if [ ! -s "$BASE" ]; then
  curl -fL --retry 3 -o "$BASE" "$CLOUDIMG_URL"
  echo "    downloaded $BASE"
  echo "    NOTE: verify against $(dirname "$CLOUDIMG_URL")/SHA512SUMS before trusting it."
else
  echo "    reusing $BASE"
fi

say "2/5  build the OS root disk ($DISK) from the base image"
cp --reflink=auto "$BASE" "$IMG"
qemu-img resize "$IMG" "$DISK"
chown libvirt-qemu:kvm "$IMG"

say "3/5  provision the big scratch disk for /data"
if [ -n "$DATA_DEV" ]; then
  [ -b "$DATA_DEV" ] || die "DATA_DEV=$DATA_DEV is not a block device"
  echo "    using host block device $DATA_DEV (raw passthrough — best performance)"
  DATA_DISK_SPEC="path=$DATA_DEV,format=raw,bus=virtio,cache=none,io=native,discard=unmap"
else
  if [ ! -s "$DATA_IMG" ]; then
    # Preallocate (not sparse): predictable space, less fragmentation under heavy disk use.
    avail=$(df -BG --output=avail "$JOBS_ROOT/images" | tail -1 | tr -dc '0-9')
    want=$(echo "$DATA_DISK" | tr -dc '0-9')
    [ "${avail:-0}" -gt "$want" ] || die "only ${avail}G free in $JOBS_ROOT/images but DATA_DISK=$DATA_DISK — shrink DATA_DISK or free space"
    echo "    preallocating $DATA_IMG ($DATA_DISK) ..."
    fallocate -l "$DATA_DISK" "$DATA_IMG"
    chown libvirt-qemu:kvm "$DATA_IMG"
  else
    echo "    reusing $DATA_IMG"
  fi
  DATA_DISK_SPEC="path=$DATA_IMG,format=raw,bus=virtio,cache=none,io=native,discard=unmap"
fi

say "4/5  render cloud-init user-data"
USERDATA="$(mktemp)"
trap 'rm -f "$USERDATA"' EXIT
cat >"$USERDATA" <<EOF
#cloud-config
hostname: jobs
preserve_hostname: false
users:
  - name: ops
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $SSH_PUBKEY
write_files:
  - path: /etc/sysctl.d/60-no-ipv6.conf
    content: |
      net.ipv6.conf.all.disable_ipv6 = 1
      net.ipv6.conf.default.disable_ipv6 = 1
  - path: /etc/sysctl.d/61-jobs-concurrency.conf
    content: |
      # The workload opens many short-lived connections: widen ephemeral ports and
      # let TIME_WAIT sockets be reused so we don't run out under high concurrency.
      net.ipv4.ip_local_port_range = 10240 65535
      net.ipv4.tcp_tw_reuse = 1
      fs.file-max = 2097152
  - path: /etc/security/limits.d/jobs.conf
    content: |
      # Raise the open-file ceiling for the workload (many concurrent sockets/files).
      ops soft nofile 1048576
      ops hard nofile 1048576
  - path: /etc/resolv.conf
    content: |
      # DNS goes to the host gateway, which redirects it into Tor.
      nameserver 10.13.13.1
mounts:
  - [ share, /mnt/share, virtiofs, "rw,nosuid,nodev", "0", "0" ]
  # /dev/vdb is the big scratch disk; noatime cuts write amplification under heavy I/O.
  - [ /dev/vdb, /data, $DATA_FS, "defaults,noatime,nofail", "0", "2" ]
packages:
  - rsync
  - curl
  - xfsprogs
package_update: true
runcmd:
  - [ sysctl, --system ]
  # Format the scratch disk on first boot only if it has no filesystem yet.
  - [ bash, -c, "blkid /dev/vdb >/dev/null 2>&1 || mkfs.$DATA_FS -q /dev/vdb" ]
  - [ mkdir, -p, /data ]
  - [ mount, /data ]
  - [ bash, -c, "chown ops:ops /data" ]
  - [ mkdir, -p, /mnt/share/in, /mnt/share/out ]
  - [ chattr, +i, /etc/resolv.conf ]
EOF

say "5/5  virt-install --import (no installer): OS disk + scratch disk + virtio-fs share"
virt-install \
  --name "$VM" \
  --memory "$RAM_MB" --vcpus "$VCPUS" \
  --cpu host-passthrough \
  --machine q35 \
  --osinfo debian13 \
  --import \
  --disk path="$IMG",format=qcow2,bus=virtio,discard=unmap \
  --disk "$DATA_DISK_SPEC" \
  --cloud-init user-data="$USERDATA" \
  --network network=jobs-net,model=virtio \
  --memorybacking access.mode=shared,source.type=memfd \
  --filesystem source="$JOBS_ROOT/share",target=share,driver.type=virtiofs \
  --rng /dev/urandom \
  --graphics none \
  --noautoconsole

cat <<EOM

  $VM is booting. cloud-init runs on first boot (give it a minute), then:

    ssh ops@10.13.13.10            # from THIS host; your key was provisioned

  Run jobs as 'ops'. All TCP/DNS -> Tor, all UDP -> ProtonVPN.
    * Heavy scratch / working set  ->  /data   (the big native disk; native speed)
    * Final results to keep        ->  /mnt/share/out/   (small; do NOT put the
                                       full working set here — virtio-fs is slower)

  Results appear on the host at $JOBS_ROOT/share/out/ . Pull them over the LAN:
    rsync -av ops@<box-LAN-ip>:$JOBS_ROOT/share/out/ ~/job-results/\$(date +%F)/

  Verify the seal:  sudo ./verify.sh   (add --killswitch for the disruptive test)
EOM
