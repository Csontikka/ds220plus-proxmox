#!/bin/sh
# Writes a ZFSBootMenu build into slot A or B of the DS220+ DOM, on the running Proxmox.
#   syno-zbm-slot.sh a|b <dir with vmlinuz-bootmenu, initramfs-bootmenu.img, SHA256SUMS>
# Slot A: DOM p2 /zbm (kernel + initramfs). Slot B: kernel on DOM p1 /zbmb, initramfs
# on DOM p2 /zbmb (p2 is too small for both copies).
# Order that keeps the box bootable at every moment: the other slot must be marked ok;
# this slot's ok marker goes first, then the old files, then the new ones; the marker
# comes back only after the checksums match. GRUB boots a slot only while its marker exists.
# Update A first, reboot and test it, and only then copy the same build into B.
set -eu
slot="${1:-}"; src="${2:-}"
[ -f "$src/SHA256SUMS" ] || { echo "usage: $0 a|b <build dir>"; exit 64; }
(cd "$src" && sha256sum -c SHA256SUMS) >/dev/null || { echo "build checksum mismatch"; exit 1; }
K=$(grep vmlinuz-bootmenu "$src/SHA256SUMS" | cut -c1-64)
I=$(grep initramfs-bootmenu.img "$src/SHA256SUMS" | cut -c1-64)

D1=$(blkid -U 10EE-589C); D2=$(blkid -U 45e5b07d-4783-4867-a369-f99c0cd1e610)
mkdir -p /mnt/dom1 /mnt/dom2
mount "$D1" /mnt/dom1; mount "$D2" /mnt/dom2
trap 'umount /mnt/dom1 /mnt/dom2 2>/dev/null' EXIT

case "$slot" in
a) kdir=/mnt/dom2/zbm; idir=/mnt/dom2/zbm; mark=/mnt/dom2/zbm/ok; other=/mnt/dom2/zbmb/ok ;;
b) kdir=/mnt/dom1/zbmb; idir=/mnt/dom2/zbmb; mark=/mnt/dom2/zbmb/ok; other=/mnt/dom2/zbm/ok ;;
*) echo "usage: $0 a|b <build dir>"; exit 64 ;;
esac
[ -e "$other" ] || { echo "the other slot is not marked ok: refusing to touch this one"; exit 1; }

rm -f "$mark"; sync
rm -f "$kdir/vmlinuz-bootmenu" "$idir/initramfs-bootmenu.img"; sync
mkdir -p "$kdir" "$idir"
cp "$src/vmlinuz-bootmenu" "$kdir/"; cp "$src/initramfs-bootmenu.img" "$idir/"; sync
echo 3 > /proc/sys/vm/drop_caches
[ "$(sha256sum < "$kdir/vmlinuz-bootmenu" | cut -c1-64)" = "$K" ] || { echo "kernel checksum mismatch after write, slot left unmarked"; exit 1; }
[ "$(sha256sum < "$idir/initramfs-bootmenu.img" | cut -c1-64)" = "$I" ] || { echo "initramfs checksum mismatch after write, slot left unmarked"; exit 1; }
: > "$mark"; sync
echo "slot $slot written and marked ok"
df -h /mnt/dom1 /mnt/dom2 | tail -2
