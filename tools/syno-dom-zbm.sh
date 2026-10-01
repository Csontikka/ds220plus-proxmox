#!/bin/sh
# Puts ZFSBootMenu on the DS220+ DOM from a RUNNING DSM (as root), with the transitional
# boot menu: the DSM stays the default, ZBM runs once when the "zbm-menu" flag is set.
# docs/install-from-dsm.md, phase 1-2. Nothing here touches the disks.
#
#   sh syno-dom-zbm.sh check              read-only: DOM size, UUIDs, free space, mounts
#   sh syno-dom-zbm.sh write <dir>        <dir>: vmlinuz-bootmenu, initramfs-bootmenu.img,
#                                         SHA256SUMS (of those two), SynoBootLoader.conf
#                                         (transitional), optional zbm-net.conf
#   sh syno-dom-zbm.sh verify <dir>       read-only: everything on the DOM matches <dir>
#   sh syno-dom-zbm.sh flag               sets the one-shot flag (then reboot the DSM)
#   sh syno-dom-zbm.sh undo               factory menu back, ZBM files and flag removed
#   sh syno-dom-zbm.sh dump <p1|p2>       raw partition to stdout, for an offline fsck
#
# Rules (see the review in the plan): the .efi is never touched; the ZBM (p2) goes first,
# the menu (p1) last; every file is written under a temporary name, checked, then renamed;
# caches are dropped before every read-back. The DSM refuses "mount /dev/synoboot1" but
# accepts the relative path "cd /dev && mount ./synoboot1" (the kernel filters the path).
set -eu
U1=10EE-589C
U2=45e5b07d-4783-4867-a369-f99c0cd1e610
M1=/tmp/sbdom1; M2=/tmp/sbdom2
CONF=EFI/boot/SynoBootLoader.conf
SAVE=EFI/boot/SynoBootLoader.conf.factory

die() { echo "ERROR: $*" >&2; exit 1; }
flush() { sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true; }
umnt() { for m in "$M1" "$M2"; do grep -q " $m " /proc/mounts && umount "$m"; done; rmdir "$M1" "$M2" 2>/dev/null || true; }
mnt() {  # ro|rw
	grep -q " $M1 \| $M2 " /proc/mounts && die "already mounted: $M1/$M2"
	if grep -q "synoboot" /proc/mounts; then
		grep synoboot /proc/mounts >&2; die "the DSM has the DOM mounted right now: try again later"
	fi
	(cd /dev && [ "$(blkid -s UUID -o value ./synoboot1)" = "$U1" ] && [ "$(blkid -s UUID -o value ./synoboot2)" = "$U2" ]) \
		|| die "the DOM partition UUIDs differ from $U1 / $U2: the menu and the ZBM hook would not find the DOM"
	mkdir -p "$M1" "$M2"
	(cd /dev && mount -o "$1" ./synoboot1 "$M1") || die "mount synoboot1 ($1) failed"
	(cd /dev && mount -o "$1" ./synoboot2 "$M2") || { umount "$M1"; die "mount synoboot2 ($1) failed"; }
	trap umnt EXIT
}
sha() { sha256sum "$1" | cut -d' ' -f1; }
put() {  # src dst: write as .tmp, compare, rename, sync
	cp "$1" "$2.tmp" && sync && flush
	[ "$(sha "$1")" = "$(sha "$2.tmp")" ] || { rm -f "$2.tmp"; die "checksum mismatch writing $2"; }
	mv -f "$2.tmp" "$2" && sync
}
check() {
	[ "$(cd /dev && blockdev --getsz ./synoboot)" = 245760 ] || die "DOM is not 245760 sectors"
	mnt ro
	[ -f "$M1/EFI/boot/SynoBootLoader.efi" ] || die "no SynoBootLoader.efi on p1"
	grep -q "$U1" "$M1/$CONF" && grep -qi "$U2" "$M1/$CONF" || die "menu does not reference the known DOM UUIDs"
	echo "efi   $(sha "$M1/EFI/boot/SynoBootLoader.efi")"
	echo "menu  $(sha "$M1/$CONF")"
	[ -f "$M1/$SAVE" ] && echo "saved factory menu present: $(sha "$M1/$SAVE")"
	df -k "$M1" "$M2" | tail -2
	ls -la "$M2"
	[ -e "$M2/zbm-menu" ] && echo "FLAG IS SET"
	return 0
}

case "${1:-}" in
check) check ;;
write)
	d="${2:-}"; [ -n "$d" ] && [ -f "$d/SHA256SUMS" ] && [ -f "$d/SynoBootLoader.conf" ] || die "usage: write <dir>"
	(cd "$d" && sha256sum -c SHA256SUMS >/dev/null) || die "build checksum mismatch in $d"
	! grep -q "$(printf '\r')" "$d/SynoBootLoader.conf" "$d/zbm-net.conf" 2>/dev/null || die "CR in the menu or zbm-net.conf"
	grep -q "zbm-menu" "$d/SynoBootLoader.conf" && grep -q "set default='1'" "$d/SynoBootLoader.conf" \
		|| die "$d/SynoBootLoader.conf is not the transitional menu (DSM default + zbm-menu flag)"
	need=$(( ($(stat -c %s "$d/vmlinuz-bootmenu") + $(stat -c %s "$d/initramfs-bootmenu.img")) / 1024 + 2048 ))
	mnt rw
	free=$(df -k "$M2" | awk 'NR==2 {print $4}')
	# the .tmp copies are written next to any old files, so the old files do not count
	[ "$free" -ge "$need" ] || die "DOM p2: $free KB free, $need KB needed (old ZBM files there? run undo first)"
	# p2 first: the ZBM slot A (no "ok" marker: the transitional menu does not use it)
	mkdir -p "$M2/zbm"
	put "$d/vmlinuz-bootmenu" "$M2/zbm/vmlinuz-bootmenu"
	put "$d/initramfs-bootmenu.img" "$M2/zbm/initramfs-bootmenu.img"
	[ -f "$d/zbm-net.conf" ] && put "$d/zbm-net.conf" "$M2/zbm-net.conf"
	# p1 last: the factory menu saved once, then the transitional menu; the .efi untouched
	[ -f "$M1/$SAVE" ] || put "$M1/$CONF" "$M1/$SAVE"
	put "$d/SynoBootLoader.conf" "$M1/$CONF"
	umnt; trap - EXIT
	blockdev --flushbufs /dev/synoboot 2>/dev/null || true
	flush
	echo "written; now: sh $0 verify $d"
	;;
verify)
	d="${2:-}"; [ -n "$d" ] || die "usage: verify <dir>"
	flush; mnt ro
	ok=1
	for f in vmlinuz-bootmenu initramfs-bootmenu.img; do
		[ "$(sha "$M2/zbm/$f")" = "$(sha "$d/$f")" ] && echo "ok   zbm/$f" || { echo "BAD  zbm/$f"; ok=0; }
	done
	[ "$(sha "$M1/$CONF")" = "$(sha "$d/SynoBootLoader.conf")" ] && echo "ok   menu" || { echo "BAD  menu"; ok=0; }
	[ -f "$M1/$SAVE" ] && echo "ok   factory menu saved" || { echo "BAD  no saved factory menu"; ok=0; }
	[ -f "$d/zbm-net.conf" ] && { [ "$(sha "$M2/zbm-net.conf")" = "$(sha "$d/zbm-net.conf")" ] && echo "ok   zbm-net.conf" || { echo "BAD  zbm-net.conf"; ok=0; }; }
	[ -e "$M2/zbm-menu" ] && echo "note: the flag is set"
	[ "$ok" = 1 ] || die "verify failed: do NOT reboot, run undo"
	echo "VERIFIED"
	;;
flag)
	mnt rw
	[ -f "$M2/zbm/vmlinuz-bootmenu" ] && [ -f "$M2/zbm/initramfs-bootmenu.img" ] || die "no ZBM on the DOM"
	grep -q "zbm-menu" "$M1/$CONF" || die "the menu on the DOM does not know the flag"
	: > "$M2/zbm-menu" && sync
	echo "flag set: the next boot starts ZBM once (it removes the flag itself)"
	;;
undo)
	mnt rw
	[ -f "$M1/$SAVE" ] || die "no saved factory menu: restore the DOM from its image instead"
	put "$M1/$SAVE" "$M1/$CONF"
	rm -f "$M2/zbm-menu" "$M2/zbm-net.conf"; rm -rf "$M2/zbm"; sync
	echo "factory menu back, ZBM files and flag removed"
	;;
dump)
	flush
	case "${2:-}" in p1) cd /dev && exec dd if=./synoboot1 bs=1M status=none ;;
	p2) cd /dev && exec dd if=./synoboot2 bs=1M status=none ;;
	*) die "usage: dump p1|p2" ;; esac
	;;
*) sed -n '2,20p' "$0"; exit 2 ;;
esac
