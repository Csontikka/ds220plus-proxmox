#!/bin/sh
# Fresh Proxmox install on the DS220+, run INSIDE ZFSBootMenu (as root, over SSH):
#   ssh root@<nas> 'sh -s wipe <serial1> <serial2>' < syno-install.sh  # partitions + pools + datasets (DESTROYS the disks)
#   ssh root@<nas> 'sh -s unpack'  < syno-install.sh   # then stream the rootfs: see "unpack" below
#   ssh root@<nas> 'sh -s finish'  < syno-install.sh   # hostid, cache, boot guard ok, export
#   The steps that read stdin themselves (unpack: the rootfs; finalize: the final menu) run
#   from a copy of this script: scp it to /tmp first, then e.g.
#   ssh root@<nas> 'sh /tmp/syno-install.sh finalize' < tools/menu/SynoBootLoader.conf
# The two disks are selected by serial number (as in /dev/disk/by-id/ata-<model>_<serial>),
# never by sdX; each serial must match exactly one whole disk.
set -eu
CMDLINE="ro quiet console=tty0 console=ttyS5,115200n8 panic=30 oops=panic softlockup_panic=1"
disk() {  # serial -> the one /dev/disk/by-id/ata-*_<serial> whole-disk link
	[ -n "${1:-}" ] || { echo "usage: sh -s wipe <serial1> <serial2>  (the full serial, as in /dev/disk/by-id)" >&2; exit 2; }
	n=0; d=""
	for x in /dev/disk/by-id/ata-*_"$1"; do
		[ -e "$x" ] || continue
		case "$x" in *-part*) continue ;; esac
		n=$((n + 1)); d="$x"
	done
	[ "$n" = 1 ] || { echo "serial $1: $n matching disks, need exactly 1" >&2; exit 1; }
	echo "$d"
}

case "${1:-}" in
wipe)
	A="$(disk "${2:-}")"; B="$(disk "${3:-}")"
	[ "$A" != "$B" ] || { echo "the two serials name the same disk"; exit 1; }
	echo "disks: $A $B"
	zpool export -a 2>/dev/null || true
	for p in "$A"-part* "$B"-part*; do
		[ -e "$p" ] || continue
		zpool labelclear -f "$p" 2>/dev/null || true
		wipefs -a -q "$p"
	done
	for d in "$A" "$B"; do
		wipefs -a -q "$d"
		sgdisk --zap-all "$d" >/dev/null
		sgdisk -n1:1M:+128G -t1:BF01 -c1:rpool -n2:0:-1G -t2:BF01 -c2:data "$d" >/dev/null
	done
	udevadm settle --timeout=20 2>/dev/null || sleep 3
	ls "$A"-part1 "$A"-part2 "$B"-part1 "$B"-part2 >/dev/null
	# system pool: strict feature set, ZFSBootMenu reads it
	zpool create -f -o ashift=12 -o autotrim=off -o compatibility=openzfs-2.3-linux \
		-O compression=lz4 -O acltype=posixacl -O xattr=sa -O relatime=on -O dnodesize=auto \
		-O normalization=formD -O canmount=off -O mountpoint=none -R /mnt rpool \
		mirror "$A"-part1 "$B"-part1
	zfs create -o canmount=off -o mountpoint=none rpool/ROOT
	zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/pve-1
	# mount the root first: every later dataset is auto-mounted on creation and
	# would otherwise end up under (and hidden by) the root mount
	zfs mount rpool/ROOT/pve-1
	zfs create -o mountpoint=/var/lib/vz rpool/var-lib-vz
	zpool set bootfs=rpool/ROOT/pve-1 rpool
	zfs set org.zfsbootmenu:commandline="$CMDLINE" rpool/ROOT/pve-1
	# data pool: not read by ZFSBootMenu, free to upgrade
	zpool create -f -o ashift=12 -O compression=lz4 -O acltype=posixacl -O xattr=sa \
		-O relatime=on -O mountpoint=/data -R /mnt data mirror "$A"-part2 "$B"-part2
	zfs create -o refreservation=200G -o mountpoint=none data/reserve
	zpool status -P
	zfs list -o name,used,avail,mountpoint
	;;
unpack)
	# stdin: the zstd-compressed rootfs tarball
	zstd -dc | tar --numeric-owner --xattrs --xattrs-include='*' --acls -xpf - -C /mnt
	echo UNPACKED
	;;
finish)
	# the hostid the pools were just written with: the kernel's spl_hostid if set,
	# otherwise ZFSBootMenu's /etc/hostid (baked in by build-zbm.sh). ZFSBootMenu has
	# no zgenhostid (2026-09-30: finish stopped here), so the file is copied as is.
	h="$(printf %08x "$(cat /sys/module/spl/parameters/spl_hostid)")"
	if [ "$h" != 00000000 ]; then
		a=${h%??????}; b=${h#??}; b=${b%????}; c=${h#????}; c=${c%??}; d=${h#??????}
		busybox printf "\\x$d\\x$c\\x$b\\x$a" > /mnt/etc/hostid
	else
		cp /etc/hostid /mnt/etc/hostid
		h="$(busybox hostid 2>/dev/null || echo '?')"
	fi
	echo "hostid $h (file: $(busybox od -An -tx1 /mnt/etc/hostid))"
	mkdir -p /mnt/etc/zfs
	zpool set cachefile=/mnt/etc/zfs/zpool.cache rpool
	zpool set cachefile=/mnt/etc/zfs/zpool.cache data
	# the boot guard: a fresh DOM holds no state (unknown = stop in the menu); the first
	# boot must go through. Until syno-bootguard-ok.service is installed (post-install),
	# run "syno-bootguard set ok" before every reboot, or the next boot stops in ZBM.
	/usr/local/sbin/syno-bootguard set ok && echo "boot guard: ok" \
		|| echo "WARNING: boot guard NOT ok: run /usr/local/sbin/syno-bootguard set ok before the reboot" >&2
	busybox stat -c '%u:%g %a %n' /mnt /mnt/etc /mnt/etc/shadow /mnt/usr/bin/chage /mnt/root/.ssh /mnt/root/.ssh/authorized_keys
	ls /mnt/boot
	# child mounts first, the root last (zfs umount -a can trip on the -R altroot)
	umount /mnt/data /mnt/var/lib/vz 2>/dev/null || true
	umount /mnt
	zpool export data
	zpool export rpool
	echo FINISHED
	;;
finalize)
	# after "finish", before the first reboot, still in ZFSBootMenu: the final DOM menu
	# (stdin: tools/menu/SynoBootLoader.conf) on p1 and slot A's ok marker on p2. From
	# now on GRUB boots ZBM A by default. Slot B is written later from Proxmox.
	U1=10EE-589C; U2=45e5b07d-4783-4867-a369-f99c0cd1e610
	d1="$(blkid -U "$U1" || true)"; d2="$(blkid -U "$U2" || true)"
	[ -n "$d1" ] && [ -n "$d2" ] || { echo "DOM partitions not found"; exit 1; }
	mkdir -p /run/f1 /run/f2
	trap 'umount /run/f1 /run/f2 2>/dev/null' EXIT
	mount -t vfat "$d1" /run/f1; mount -t ext4 "$d2" /run/f2
	[ -f /run/f2/zbm/vmlinuz-bootmenu ] && [ -f /run/f2/zbm/initramfs-bootmenu.img ] || { echo "no ZBM A on the DOM"; exit 1; }
	cat > /run/f1/EFI/boot/SynoBootLoader.conf.tmp
	grep -q "/zbm/ok" /run/f1/EFI/boot/SynoBootLoader.conf.tmp && ! grep -q "$(printf '\r')" /run/f1/EFI/boot/SynoBootLoader.conf.tmp \
		|| { rm -f /run/f1/EFI/boot/SynoBootLoader.conf.tmp; echo "stdin is not the final menu (or has CR)"; exit 1; }
	# ZFSBootMenu has no coreutils sync/sha256sum: busybox
	busybox sync; echo 3 > /proc/sys/vm/drop_caches
	busybox sha256sum /run/f1/EFI/boot/SynoBootLoader.conf.tmp
	mv -f /run/f1/EFI/boot/SynoBootLoader.conf.tmp /run/f1/EFI/boot/SynoBootLoader.conf
	: > /run/f2/zbm/ok
	rm -f /run/f2/zbm-menu
	busybox sync
	ls -la /run/f1/EFI/boot /run/f2/zbm
	echo FINALIZED
	;;
*)
	echo "usage: sh -s wipe|unpack|finish|finalize" >&2; exit 2 ;;
esac
