#!/bin/sh
# First steps on a freshly installed DS220+ (after the first boot, as root), before
# post-install.sh: GRUB pin, proxmox-ve, microcode, ZFS ARC limit, the "data" storage.
# Takes the LAN1 factory MAC for the bond and the bridge when vmbr0 uses DHCP (otherwise
# the bridge asks the DHCP server with a generated MAC, and a reservation for the factory
# MAC never matches).
#   sh first-boot.sh <mailname>       e.g. sh first-boot.sh syno-pve.example.lan
# Log: /root/first-boot.log; the end marker is "FIRST-BOOT DONE" or "FIRST-BOOT FAILED".
set -eu
MAILNAME="${1:?usage: first-boot.sh <mailname>}"
exec >> /root/first-boot.log 2>&1
trap 'echo "FIRST-BOOT FAILED rc=$?"' EXIT
echo "== $(date -Is) first-boot"

# 1. GRUB and os-prober must never come in (the kernel packages only recommend them)
cat > /etc/apt/preferences.d/syno-no-grub <<EOT
# GRUB lives on the Synology DOM and ZFSBootMenu boots the system.
Package: grub-pc grub-pc-bin grub-efi-amd64 grub-efi-amd64-bin grub-efi-amd64-signed grub-efi-ia32 grub-efi-ia32-bin os-prober
Pin: release *
Pin-Priority: -1
EOT

# 2. the bridge takes the bond's factory MAC (LAN1) when vmbr0 is DHCP
if grep -q '^iface vmbr0 inet dhcp' /etc/network/interfaces && ! grep -q 'hwaddress' /etc/network/interfaces; then
	# the factory MAC as syno-macs set it at boot (enp1s0 itself now carries the bond's
	# address, which is generated): from the journal, else straight from the DOM vender
	mac="$(journalctl -u syno-macs -b -o cat 2>/dev/null | sed -n 's/^.*LAN1 [^ ]* = \([0-9a-f:]*\)$/\1/p' | tail -n 1)"
	case "$mac" in ??:??:??:??:??:??) ;; *) echo "factory MAC of LAN1 not found: hwaddress not set"; mac="" ;; esac
	if [ -n "$mac" ]; then
		sed -i "/^iface bond0 inet manual/a \\\\thwaddress $mac" /etc/network/interfaces
		sed -i "/^iface vmbr0 inet dhcp/a \\\\thwaddress $mac" /etc/network/interfaces
		echo "hwaddress $mac on bond0 and vmbr0 (active after the next reboot)"
	fi
fi

# 3. Proxmox VE (the "install on Debian" way), postfix local only
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string $MAILNAME" | debconf-set-selections
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y proxmox-ve postfix open-iscsi chrony intel-microcode wireless-regdb
dpkg -l 'linux-image-*' 2>/dev/null | awk '/^ii/ {print $2}' | grep -v pve && echo "WARNING: a Debian kernel came in" || true

# 4. small box: ZFS ARC at most 1 GiB; pNFS block layout is not used
echo "options zfs zfs_arc_max=1073741824" > /etc/modprobe.d/zfs.conf
systemctl disable --now nfs-blkmap 2>/dev/null || true
update-initramfs -u -k all

# 5. the data pool as Proxmox storage
pvesm status | grep -q '^data ' || pvesm add zfspool data --pool data --content images,rootdir --sparse 1

trap - EXIT
echo "FIRST-BOOT DONE $(date -Is)"
