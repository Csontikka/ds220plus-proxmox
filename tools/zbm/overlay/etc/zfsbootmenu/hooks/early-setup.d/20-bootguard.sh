#!/bin/sh
# Boot guard (see /usr/local/sbin/syno-bootguard): if the last boot of the real system
# never reported healthy, do not boot it again. ZFSBootMenu then stays up with SSH, and
# the box can be repaired remotely (snapshot rollback, older kernel), nobody has to go there.
log() { echo "<3>bootguard: $*" > /dev/kmsg; }
G=/usr/local/sbin/syno-bootguard

# the menu was asked for anyway (ZBM_MENU entry): leave the state alone
busybox grep -q "zbm.show" /proc/cmdline && exit 0

if ! st="$($G status 2>/dev/null)"; then
	log "state sector not readable, booting as usual"
	exit 0
fi
case "$st" in
ok|unknown)
	$G set pending && log "state $st -> pending, booting as usual" ;;
*)
	# zfsbootmenu-init skips the automatic boot while this lock file exists; the second
	# file tells the LED hooks that this is trouble, not a menu asked for on purpose
	busybox mkdir -p /zfsbootmenu && : > /zfsbootmenu/active && : > /zfsbootmenu/syno-guard-stop
	# C blinks (waiting here), power steady, status orange blink
	/usr/local/sbin/syno-microp 4 7B ';A'
	log "last boot did not come up healthy (state $st): staying here, SSH is open"
	cat > /etc/motd <<MOTD

  boot guard: the last boot of Proxmox did not report healthy (state: $st).
  The system was NOT booted again. Options:
    zfsbootmenu                                menu: snapshots, older kernels, recovery shell
    syno-bootguard set ok; busybox reboot -f   try the normal boot once more

MOTD
	;;
esac
