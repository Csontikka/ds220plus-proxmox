#!/bin/sh
# The ZFSBootMenu menu is on screen (not an automatic boot): ZBM waits for someone.
#   C blinks (the boot loader is waiting, SSH is open), power LED steady;
#   status orange blink when something is wrong (the boot guard stopped here, or no
#   pool / nothing to boot), green blink when the menu was asked for on purpose.
if [ -e /zfsbootmenu/syno-guard-stop ] || [ -z "$(zpool list -H -o name 2>/dev/null)" ]; then
	/usr/local/sbin/syno-microp 4 7B ';A'
else
	/usr/local/sbin/syno-microp 4 7B 9A
fi
exit 0
