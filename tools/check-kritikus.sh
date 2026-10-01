#!/bin/sh
# Checks the boot-critical files before they go to a box (and before every commit):
# LF line endings only (no CR anywhere), no UTF-8 BOM, plain ASCII, a final newline,
# and "sh -n" for shell scripts. A CR in a GRUB menu, a ZBM hook or an initramfs script
# can stop a DS220+ from booting, and there is no console to see why.
#   sh tools/check-kritikus.sh            (from the project root; exit 1 on any problem)
cd "$(dirname "$0")/.." || exit 2
files="
tools/menu/SynoBootLoader.conf
tools/menu/SynoBootLoader.dsm-transition.conf
tools/zbm/build-zbm.sh
tools/zbm/syno-install.sh
tools/zbm/syno-zbm-slot.sh
tools/syno-dom-zbm.sh
tools/pve/build-rootfs.sh
tools/pve/syno-net-switch.sh
tools/bootguard/syno-bootguard
tools/bootguard/syno-bootguard-check
tools/bootguard/syno-bootguard-ok.service
tools/check-kritikus.sh
"
files="$files tools/synodeb/build.sh tools/synodeb/SynoBootLoader.synodeb.conf tools/pve/post-install/post-install.sh tools/pve/post-install/pve-remove-nag.sh tools/pve/post-install/no-nag-script synofand/synofand.service"
files="$files $(find tools/zbm/overlay tools/pve/overlay tools/synodeb/overlay tools/pve/post-install tools/zbm -maxdepth 1 -type f 2>/dev/null | sort -u)"
files="$files $(find tools/zbm/overlay tools/pve/overlay tools/synodeb/overlay tools/pve/post-install -type f 2>/dev/null)"
# go to the box too, but may hold UTF-8 (degree signs): CR, BOM, final newline, valid UTF-8
utf8="synofand/synofand.py synofand/synofand.toml.example"
bad=0
for f in $files; do
	[ -f "$f" ] || { echo "MISSING  $f"; bad=1; continue; }
	p=""
	[ "$(od -An -v -tx1 "$f" | tr -s ' ' '\n' | grep -c '^0d$')" = 0 ] || p="$p CR"
	[ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' ')" = efbbbf ] && p="$p BOM"
	# byte level (the MSYS grep on Windows misses some): control bytes except tab/LF, and bytes >= 0x7f
	[ "$(od -An -v -tx1 "$f" | tr -s ' ' '\n' | grep -cE '^(0[0-8]|0[b-f]|1[0-9a-f]|7f|[89a-f][0-9a-f])$')" = 0 ] || p="$p non-ASCII/control"
	[ -s "$f" ] && [ "$(tail -c 1 "$f" | od -An -tx1 | tr -d ' ')" != 0a ] && p="$p no-final-newline"
	case "$(head -n 1 "$f")" in '#!/bin/sh'*|'#!/bin/bash'*) sh -n "$f" 2>/dev/null || p="$p SYNTAX" ;; esac
	case "$f" in */dhclient-exit-hooks.d/*) sh -n "$f" 2>/dev/null || p="$p SYNTAX" ;; esac
	if [ -n "$p" ]; then echo "BAD $p  $f"; bad=1; fi
done
for f in $utf8; do
	[ -f "$f" ] || { echo "MISSING  $f"; bad=1; continue; }
	p=""
	[ "$(od -An -v -tx1 "$f" | tr -s ' ' '\n' | grep -c '^0d$')" = 0 ] || p="$p CR"
	[ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' ')" = efbbbf ] && p="$p BOM"
	if command -v iconv >/dev/null 2>&1; then iconv -f UTF-8 -t UTF-8 "$f" >/dev/null 2>&1 || p="$p bad-UTF-8"; fi
	[ "$(tail -c 1 "$f" | od -An -tx1 | tr -d ' ')" != 0a ] && p="$p no-final-newline"
	if [ -n "$p" ]; then echo "BAD $p  $f"; bad=1; fi
done
if command -v grub-script-check >/dev/null 2>&1; then
	for f in tools/menu/*.conf; do grub-script-check "$f" || { echo "BAD grub-script-check  $f"; bad=1; }; done
fi
[ "$bad" = 0 ] && echo "OK: $(echo $files $utf8 | wc -w) files, LF only, no BOM, ASCII (UTF-8 for 2), final newline, shell syntax"
exit "$bad"
