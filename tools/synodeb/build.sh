#!/bin/sh
# Builds the DS220+ test Debian (trixie) as a raw USB-stick image. Run as root on a
# Debian 12/13 or Proxmox host:
#   sudo ./build.sh [outdir]
# Put your SSH public key(s) in overlay/root/.ssh/authorized_keys first (see
# authorized_keys.example next to it; the build stops without the file).
# Needs: mmdebstrap, e2fsprogs, dosfstools, mtools, zstd. No loop devices needed.
# Run as REAL root: in an unprivileged container mmdebstrap loses every non-root owner.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/out}"
ROOT_MB=3000        # ext4 root, LABEL=SYNODEB
LOG_MB=64           # vfat log partition, LABEL=SYNOLOG (readable from DSM)
mkdir -p "$OUT"
W="$(mktemp -d "${TMPDIR:-/tmp}/synodeb.XXXXXX")"
trap 'rm -rf "$W"' EXIT

mmdebstrap --mode=root --variant=minbase \
  --components=main,non-free-firmware \
  --include=busybox,systemd-timesyncd,systemd-sysv,udev,dbus,kmod,linux-image-amd64,initramfs-tools,zstd,openssh-server,systemd-resolved,iproute2,iputils-ping,gpiod,python3,python3-libgpiod,firmware-realtek,pciutils,usbutils,smartmontools,i2c-tools,ethtool,less,nano,ca-certificates,dosfstools,e2fsprogs,procps,netbase \
  --customize-hook='cp -a --no-preserve=ownership "'"$HERE"'/overlay/." "$1/"' \
  --customize-hook='mkdir -p "$1/usr/local/lib/synofand" && cp "'"$HERE"'/../../synofand/synofand.py" "$1/usr/local/sbin/" && cp "'"$HERE"'/../../synofand/synofand.service" "$1/etc/systemd/system/" && cp "'"$HERE"'/../../synofand/synofand.toml.example" "$1/etc/synofand.toml"' \
  --customize-hook='chmod 755 "$1/etc/initramfs-tools/hooks/synodeb" "$1/etc/initramfs-tools/scripts/init-premount/synodeb" "$1/etc/initramfs-tools/scripts/init-top/synodeb-gpio" "$1/etc/initramfs-tools/scripts/init-top/synodeb-flag" "$1/usr/local/sbin/synodeb-log" "$1/usr/local/sbin/synodeb-disks" "$1/usr/local/sbin/synofand.py"; chmod 700 "$1/root/.ssh"; chmod 600 "$1/root/.ssh/authorized_keys"' \
  --customize-hook='chroot "$1" systemctl enable systemd-networkd systemd-resolved ssh synodeb-log.timer synodeb-disks synofand' \
  --customize-hook='ln -sf /run/systemd/resolve/stub-resolv.conf "$1/etc/resolv.conf"' \
  --customize-hook='chroot "$1" passwd -l root' \
  --customize-hook='rm -f "$1"/etc/ssh/ssh_host_*; chroot "$1" ssh-keygen -A' \
  --customize-hook='chroot "$1" update-initramfs -u -k all' \
  trixie "$W/rootdir"

# mmdebstrap's tarball output writes every entry as 0/0, so the root is built into a
# directory (real owners kept; mkfs.ext4 -d copies them). Acceptance check first.
chk() { [ "$(stat -c %U:%G "$W/rootdir/$2")" = "$1" ] || { echo "OWNERSHIP CHECK FAILED: $2 is $(stat -c %U:%G "$W/rootdir/$2"), want $1"; exit 1; }; }
chk root:shadow etc/shadow
chk root:shadow usr/sbin/unix_chkpwd
chk root:_ssh usr/bin/ssh-agent
chk root:messagebus usr/lib/dbus-1.0/dbus-daemon-launch-helper
chk root:root etc
chk root:root root/.ssh/authorized_keys
odd="$(find "$W/rootdir" -xdev \( -uid +65000 -o -gid +65000 \) -print | head -5)"
[ -z "$odd" ] || { echo "OWNERSHIP CHECK FAILED: foreign uid/gid on: $odd"; exit 1; }
echo "ownership check ok"

# Kernel and initramfs for the DOM
K="$(ls "$W"/rootdir/boot/vmlinuz-* | sort -V | tail -1)"
I="$W/rootdir/boot/initrd.img-${K##*/vmlinuz-}"
cp "$K" "$OUT/vmlinuz"
cp "$I" "$OUT/initrd.img"
cp "$W/rootdir/boot/config-${K##*/vmlinuz-}" "$OUT/kernel.config"

# Root filesystem image from the directory (no /dev nodes: devtmpfs provides them)
rm -rf "$W"/rootdir/dev/* "$W"/rootdir/proc/* "$W"/rootdir/sys/* "$W"/rootdir/run/*
truncate -s "${ROOT_MB}M" "$W/root.ext4"
mkfs.ext4 -q -L SYNODEB -d "$W/rootdir" "$W/root.ext4"
rm -rf "$W/rootdir"

truncate -s "${LOG_MB}M" "$W/log.vfat"
mkfs.vfat -n SYNOLOG "$W/log.vfat" >/dev/null
echo "synodeb log partition" > "$W/README.TXT"
mcopy -i "$W/log.vfat" "$W/README.TXT" ::README.TXT

# Disk image: MBR, p1 = root, p2 = log
IMG="$W/synodeb.img"
truncate -s "$((1 + ROOT_MB + LOG_MB + 1))M" "$IMG"
sfdisk -q "$IMG" <<SF
label: dos
start=1MiB, size=${ROOT_MB}MiB, type=83, bootable
start=$((1 + ROOT_MB))MiB, size=${LOG_MB}MiB, type=c
SF
dd if="$W/root.ext4" of="$IMG" bs=1M seek=1 conv=notrunc,sparse status=none
dd if="$W/log.vfat" of="$IMG" bs=1M seek=$((1 + ROOT_MB)) conv=notrunc status=none
gzip -1 -c "$IMG" > "$OUT/synodeb.img.gz"
( cd "$OUT" && sha256sum vmlinuz initrd.img synodeb.img.gz > SHA256SUMS )
ls -la "$OUT"
