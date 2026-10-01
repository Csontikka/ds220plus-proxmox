#!/bin/sh
# DS220+ early setup for ZFSBootMenu (runs after udev, before any pool is imported):
#   USB and disk power (GPIO) with a wait loop for both disks, factory MACs, DHCP on all
#   NICs, fan at a safe duty, dropbear SSH for remote rescue, one-shot "stay in menu" flag.

# ZFSBootMenu ships no coreutils: always use busybox for the tools this hook needs
for t in cat cut seq sed tr readlink mknod sleep ls grep mkdir sync stty printf rm umount mount; do
	eval "$t() { busybox $t \"\$@\"; }"
done
log() { echo "<3>ds220: $*" > /dev/kmsg; }
arg() { for x in $(cat /proc/cmdline); do case "$x" in "$1"=*) echo "${x#*=}" ;; esac; done; }
has() { for x in $(cat /proc/cmdline); do [ "$x" = "$1" ] && return 0; done; return 1; }

# 0. FIRST, before anything that can hang: the "stay in the menu" flag is one-shot.
#    With the transitional menu (installing from a running DSM, no console) the flag is
#    the only thing that leads here, so once it is gone a power cycle boots the DSM
#    again. Every step may fail without stopping the hook. The DOM is a USB device: wait
#    for it up to 30 s (no cost when it is there).
if has zbm.show; then
	dom=""
	for i in $(seq 1 30); do
		dom="$(blkid -U 45e5b07d-4783-4867-a369-f99c0cd1e610 2>/dev/null)" && [ -n "$dom" ] && break
		sleep 1
	done
	if [ -n "$dom" ] && mkdir -p /run/dom && mount -t ext4 "$dom" /run/dom 2>/dev/null; then
		if [ -e /run/dom/zbm-menu ]; then
			rm -f /run/dom/zbm-menu && sync && log "zbm-menu flag removed" || log "ERROR zbm-menu flag NOT removed"
		fi
		umount /run/dom || log "DOM p2 umount failed"
	else
		log "DOM p2 not found or not mounted: flag not checked"
	fi
fi

# 0b. hardware watchdog, only when the menu entry asks for it (syno.wd, transitional menu):
#     if this boot loader hangs later (disks, network), WDAT resets the box (its own
#     timeout, about half a minute plus the firmware delay) and the DSM comes back, as the
#     flag is already gone. After logging in over SSH, disarm it at once:
#       /usr/local/sbin/syno-wd-stop
#     One feeder, one open file descriptor: it stops on a stop file and closes the device
#     with the magic 'V' itself (a second opener would get EBUSY; a close without 'V'
#     leaves the watchdog running). The sleep gets no copy of the descriptor.
if has syno.wd; then
	if modprobe -q wdat_wdt 2>/dev/null && [ -e /dev/watchdog ]; then
		rm -f /run/syno-wd-stop
		(
			exec 3>/dev/watchdog || exit 1
			while [ ! -e /run/syno-wd-stop ]; do
				busybox printf . >&3
				busybox sleep 2 3>&-
			done
			busybox printf V >&3
			exec 3>&-
		) &
		wdpid=$!
		echo "$wdpid" > /run/syno-wd.pid
		sleep 1
		if kill -0 "$wdpid" 2>/dev/null; then
			log "watchdog armed (WDAT, feeder pid $wdpid); disarm: /usr/local/sbin/syno-wd-stop"
		else
			log "WARNING watchdog feeder died at once (device busy?): NOT armed"
		fi
		cat > /usr/local/sbin/syno-wd-stop <<'EOF'
#!/bin/sh
# Disarms the boot loader's watchdog: the feeder sees the stop file, writes the magic
# 'V' and closes the device. Only if it does not end in 15 s: kill it and try here.
pid="$(busybox cat /run/syno-wd.pid 2>/dev/null)"
[ -n "$pid" ] || { echo "no watchdog feeder recorded"; exit 0; }
: > /run/syno-wd-stop
i=0
while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 15 ]; do busybox sleep 1; i=$((i + 1)); done
if kill -0 "$pid" 2>/dev/null; then
	kill "$pid" 2>/dev/null; busybox sleep 3
	busybox printf V > /dev/watchdog 2>/dev/null && echo "watchdog disarmed (fallback)" && exit 0
	echo "WARNING: watchdog NOT disarmed: the box will reset soon; do not start the install" >&2
	exit 1
fi
busybox rm -f /run/syno-wd.pid
echo "watchdog disarmed"
EOF
		busybox chmod 755 /usr/local/sbin/syno-wd-stop
	else
		log "WARNING watchdog NOT armed (syno.wd set, but wdat_wdt or /dev/watchdog missing)"
	fi
fi

modprobe -q pinctrl_geminilake 2>/dev/null
modprobe -q ahci 2>/dev/null; modprobe -q libahci 2>/dev/null; modprobe -q sd_mod 2>/dev/null

# 1. fan: no regulation in the menu, so a fixed safe duty on the microcontroller UART
for t in /sys/class/tty/ttyS*; do
	[ "$(cat "$t/iomem_base" 2>/dev/null)" = "0xA1215000" ] || continue
	p="/dev/${t##*/}"
	[ -e "$p" ] || mknod "$p" c "$(cut -d: -f1 "$t/dev")" "$(cut -d: -f2 "$t/dev")"
	stty -F "$p" 9600 cs8 -cstopb -parenb -crtscts -ixon raw -echo && printf 'V50' > "$p" && log "fan V50 on $p"
done

# front LEDs while the boot loader runs: C steady, status green blink (power keeps the
# microcontroller's own boot blink); see docs/fan-and-leds.md
/usr/local/sbin/syno-microp 9 @ || log "front LEDs not set"

# 2. GPIO: wait for the pinctrl driver, then USB power and the two disk bays one after the other
for i in $(seq 1 40); do
	gpiodetect 2>/dev/null | grep -qF "[INT3453:00]" && break
	sleep 0.5
done
chip="$(gpiodetect 2>/dev/null | grep -F "[INT3453:00]" | cut -d' ' -f1)"
if [ -n "$chip" ]; then
	gpioset -z -c "$chip" 29=1 30=1 && log "usb vbus on"
	gpioset -z -c "$chip" 20=1 && log "disk 1 power on"
	sleep 5
	gpioset -z -c "$chip" 21=1 && log "disk 2 power on"
	# rescan until both SATA disks are there (or 40 s)
	for i in $(seq 1 20); do
		for h in /sys/class/scsi_host/host*/scan; do echo "- - -" > "$h"; done
		sleep 2
		n=0
		for b in /sys/block/sd*; do
			case "$(readlink -f "$b")" in */ata*) n=$((n + 1)) ;; esac
		done
		[ "$n" -ge 2 ] && break
	done
	udevadm settle --timeout=20 2>/dev/null
	log "sata disks: $n after $((i * 2)) s"
else
	log "ERROR gpio chip INT3453:00 not found"
fi

# 3. factory MACs (macs= comes from the Synology GRUB 'vender' command)
n=1
for m in $(arg macs | tr ',' ' '); do
	mac="$(echo "$m" | sed 's/\(..\)/\1:/g; s/:$//')"
	for d in /sys/class/net/*; do
		case "$(readlink -f "$d/device")" in
			*/0000:0${n}:00.0) ip link set dev "${d##*/}" address "$mac" && log "mac ${d##*/} = $mac" ;;
		esac
	done
	[ "$n" = 1 ] && bondmac="$mac"   # LAN1: the bond carries the first port's factory MAC
	n=$((n + 1))
done

# 4. network, then SSH: an active-backup bond over both ports with LAN1's factory MAC,
#    like the installed system, so the boot loader gets the same address whichever port
#    has the cable. The address: fixed, from "zbm-net.conf" in the root of the DOM data
#    partition (lines "address=192.0.2.10/24" and "gateway=192.0.2.1", the same as
#    the installed system, editable from there), otherwise DHCP (udhcpc -b keeps trying
#    in the background). If the bond cannot be built: DHCP on every port, as before.
# -C: no client-id, like the installed system's dhclient, so the DHCP server sees one client (the MAC)
zbmname="$(cat /etc/zfsbootmenu/syno-zbm-name 2>/dev/null)"; [ -n "$zbmname" ] || zbmname=syno-zbm
dhcp() { busybox udhcpc -C -i "$1" -s /etc/zfsbootmenu/udhcpc.script -b -x "hostname:$zbmname" -t 5 -T 2 >/dev/null 2>&1 & }
netconf() {
	d="$(blkid -U 45e5b07d-4783-4867-a369-f99c0cd1e610 2>/dev/null)"
	[ -n "$d" ] || return 1
	mkdir -p /run/domnet && mount -t ext4 -o ro "$d" /run/domnet 2>/dev/null || return 1
	a=""; g=""
	if [ -f /run/domnet/zbm-net.conf ]; then
		a="$(sed -n '/^address=/{s/^address=//p;q}' /run/domnet/zbm-net.conf)"
		g="$(sed -n '/^gateway=/{s/^gateway=//p;q}' /run/domnet/zbm-net.conf)"
	fi
	umount /run/domnet
	case "$a" in *.*.*.*/*) ;; *) return 1 ;; esac
	case "$g" in *.*.*.*|"") ;; *) return 1 ;; esac
	echo "$a $g"
}
static() {  # interface address/prefix [gateway]
	ip addr add "$2" dev "$1" || return 1
	[ -n "$3" ] && ip route replace default via "$3" dev "$1"
	echo "ds220: $1 $2 (fixed, zbm-net.conf) gw ${3:-none}" > /dev/kmsg
	# a typo in zbm-net.conf must not lock us out: if the gateway does not answer
	# within about 60 s (30 tries; switch ports may block for 30-50 s after link-up),
	# DHCP starts as well and adds its own address next to the fixed one
	[ -n "$3" ] || return 0
	(
		i=0
		while [ "$i" -lt 30 ]; do
			busybox ping -c 1 -W 1 "$3" >/dev/null 2>&1 && {
				echo "ds220: gateway $3 answers, fixed address only" > /dev/kmsg; exit 0; }
			busybox sleep 1   # "network unreachable" fails at once: keep the full 30 s
			i=$((i + 1))
		done
		echo "ds220: gateway $3 silent for 60 s, starting DHCP next to the fixed address" > /dev/kmsg
		: > /run/syno-keep-static
		dhcp "$1"
	) &
}
nics=""
for d in /sys/class/net/*; do
	i="${d##*/}"
	case "$i" in lo|bond*) ;; *) nics="$nics $i" ;; esac
done
if [ -n "$bondmac" ] && modprobe -q bonding max_bonds=0 2>/dev/null &&
	ip link add bond0 type bond mode active-backup miimon 100 2>/dev/null; then
	for i in $nics; do ip link set "$i" down; ip link set "$i" master bond0; done
	ip link set bond0 address "$bondmac"
	ip link set bond0 up
	log "bond0 active-backup over$nics, mac $bondmac"
	if cfg="$(netconf)"; then
		static bond0 $cfg || { log "fixed address failed, DHCP"; dhcp bond0; }
	else
		dhcp bond0
	fi
else
	log "no bond, DHCP on every port"
	for i in $nics; do ip link set "$i" up; dhcp "$i"; done
fi
grep -q '^root:' /etc/passwd || echo 'root:x:0:0:root:/root:/bin/sh' >> /etc/passwd
mkdir -p /var/log /var/run
dropbear -s -j -k -p 22 -r /etc/dropbear/dropbear_ed25519_host_key && log "dropbear ssh on port 22"

# 5. (the one-shot "stay in the menu" flag is removed at the very start, step 0)
