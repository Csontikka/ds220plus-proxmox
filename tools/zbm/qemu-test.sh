#!/bin/sh
# QEMU test of a ZFSBootMenu build against a copy of a DS220+ DOM image (no KVM needed):
# sets the one-shot "zbm-menu" flag in the copy's p2, boots the ZBM kernel + initramfs
# with the transitional menu's command line, captures the console, and checks that the
# flag was removed. The DS220+ hardware (GPIO, WDAT, Realtek) is not emulated.
#   sh qemu-test.sh <zbm build dir> <DOM image> [seconds]
set -eu
B="$1"; IMG="$2"; T="${3:-420}"
W="$(mktemp -d "${TMPDIR:-/tmp}/zbmqemu.XXXXXX")"
trap 'rm -rf "$W"' EXIT
cp "$IMG" "$W/dom.img"
# p2 of the DS220+ DOM: sectors 67584..239615
dd if="$W/dom.img" of="$W/p2.img" bs=512 skip=67584 count=172032 status=none
: > "$W/empty"
/sbin/debugfs -w -R "write $W/empty zbm-menu" "$W/p2.img" >/dev/null 2>&1
/sbin/debugfs -R "ls -l /" "$W/p2.img" 2>/dev/null | grep -q zbm-menu || { echo "could not set the flag"; exit 1; }
dd if="$W/p2.img" of="$W/dom.img" bs=512 seek=67584 conv=notrunc status=none
echo "flag set in the copy; booting ZBM for up to $T s (TCG, slow)"
timeout "$T" qemu-system-x86_64 -m 2048 -smp 2 -nographic -no-reboot \
	-kernel "$B/vmlinuz-bootmenu" -initrd "$B/initramfs-bootmenu.img" \
	-append "ro console=ttyS0,115200 loglevel=6 zbm.show panic=30 syno.wd efi=noruntime" \
	-device qemu-xhci -drive if=none,id=dom,file="$W/dom.img",format=raw -device usb-storage,drive=dom \
	> "$W/console.log" 2>&1 || true
cp "$W/console.log" "$B/qemu-console.log"
dd if="$W/dom.img" of="$W/p2.img" bs=512 skip=67584 count=172032 status=none
echo "== hook lines"; grep -a "ds220:" "$W/console.log" | head -30
echo "== p2 after boot"; /sbin/debugfs -R "ls -l /" "$W/p2.img" 2>/dev/null | grep -E "zbm-menu" && echo "FLAG STILL THERE" || echo "FLAG REMOVED"
/sbin/e2fsck -fn "$W/p2.img" 2>&1 | tail -1
