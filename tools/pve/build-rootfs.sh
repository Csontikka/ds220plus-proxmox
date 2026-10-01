#!/bin/sh
# Builds the base root filesystem for Proxmox VE on the DS220+ as a tarball.
# Debian 13 + Proxmox kernel (ZFS built in) + zfsutils + DS220+ services. The
# proxmox-ve package itself is installed later on the running box (Proxmox's
# recommended "install on Debian" path).
# Run as REAL root (e.g. on a running Proxmox/Debian host), NOT in an unprivileged
# container: there mmdebstrap silently loses every non-root owner/group.
#   ./build-rootfs.sh [outdir]
# Per-box settings (environment):
#   SYNO_HOSTNAME  the host name (default syno-pve)
#   SYNO_NET       static (vmbr0 as in overlay/etc/network/interfaces) or dhcp
#                  (vmbr0 by DHCP; a dhclient hook keeps /etc/hosts on the leased address,
#                  which pmxcfs needs: the node name must resolve to a non-loopback IP)
#   SYNO_TZ        the time zone (default UTC), e.g. Europe/Berlin
#   SYNO_LOCALE    an extra locale besides en_US.UTF-8 (default: none), e.g. de_DE.UTF-8
# Before the first build:
#   put your SSH public key(s) in overlay/root/.ssh/authorized_keys (see
#   authorized_keys.example next to it; the build stops without the file), and set the
#   static address in overlay/etc/network/interfaces and overlay/etc/hosts.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/out}"
SYNO_HOSTNAME="${SYNO_HOSTNAME:-syno-pve}"
case "$SYNO_HOSTNAME" in *[!A-Za-z0-9-]*|""|-*) echo "SYNO_HOSTNAME: letters, digits and hyphens only"; exit 2 ;; esac
SYNO_NET="${SYNO_NET:-static}"
case "$SYNO_NET" in static|dhcp) ;; *) echo "SYNO_NET must be static or dhcp"; exit 2 ;; esac
SYNO_TZ="${SYNO_TZ:-UTC}"
SYNO_LOCALE="${SYNO_LOCALE:-}"
case "$SYNO_TZ" in *[!A-Za-z0-9_/+-]*|"") echo "SYNO_TZ: a zoneinfo name like Europe/Berlin"; exit 2 ;; esac
case "$SYNO_LOCALE" in *[!A-Za-z0-9_.@-]*) echo "SYNO_LOCALE: a locale name like de_DE.UTF-8"; exit 2 ;; esac
mkdir -p "$OUT"
W="$(mktemp -d "${TMPDIR:-/tmp}/pverootfs.XXXXXX")"
trap 'rm -rf "$W"' EXIT
curl -fsSL -o "$W/pve.gpg" https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg

mmdebstrap --mode=root --variant=minbase --components=main,contrib,non-free-firmware \
  --include=systemd-sysv,udev,dbus,kmod,locales,ca-certificates,curl,gnupg,openssh-server,ifupdown2,iproute2,iputils-ping,chrony,less,nano,gpiod,python3,python3-libgpiod,firmware-realtek,smartmontools,busybox,procps,lsof,pciutils,usbutils,isc-dhcp-client \
  --customize-hook='mkdir -p "$1/usr/share/keyrings" && cp "'"$W"'/pve.gpg" "$1/usr/share/keyrings/proxmox-archive-keyring.gpg"' \
  --customize-hook='echo "deb [signed-by=/usr/share/keyrings/proxmox-archive-keyring.gpg] http://download.proxmox.com/debian/pve trixie pve-no-subscription" > "$1/etc/apt/sources.list.d/pve.list"' \
  --customize-hook='chroot "$1" apt-get update -qq' \
  --customize-hook='chroot "$1" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq proxmox-default-kernel zfsutils-linux zfs-zed zfs-initramfs' \
  --customize-hook='cp -a --no-preserve=ownership "'"$HERE"'/overlay/." "$1/"' \
  --customize-hook='echo "'"$SYNO_HOSTNAME"'" > "$1/etc/hostname"; sed -i "s/syno-pve/'"$SYNO_HOSTNAME"'/g" "$1/etc/hosts"' \
  --customize-hook='if [ "'"$SYNO_NET"'" = dhcp ]; then sed -i "/^iface vmbr0 inet static/,/^\tgateway/{s/^iface vmbr0 inet static/iface vmbr0 inet dhcp/;/^\taddress/d;/^\tgateway/d}" "$1/etc/network/interfaces"; printf "127.0.0.1\tlocalhost\n" > "$1/etc/hosts"; else rm -f "$1/etc/dhcp/dhclient-exit-hooks.d/syno-hosts"; fi' \
  --customize-hook='mkdir -p "$1/usr/local/lib/synofand" && cp "'"$HERE"'/../../synofand/synofand.py" "$1/usr/local/sbin/" && cp "'"$HERE"'/../../synofand/synofand.service" "$1/etc/systemd/system/" && cp "'"$HERE"'/../../synofand/synofand.toml.example" "$1/etc/synofand.toml"' \
  --customize-hook='chmod 755 "$1/usr/local/sbin/syno-disks" "$1/usr/local/sbin/syno-macs" "$1/usr/local/sbin/synofand.py"; chmod 700 "$1/root/.ssh"; chmod 600 "$1/root/.ssh/authorized_keys"' \
  --customize-hook='chroot "$1" systemctl enable ssh syno-disks syno-macs synofand zfs-import-cache zfs-mount zfs.target zfs-zed chrony' \
  --customize-hook='rm -f "$1"/etc/ssh/ssh_host_*; chroot "$1" ssh-keygen -A; chroot "$1" passwd -l root' \
  --customize-hook='sed -i "s/^# *\(en_US.UTF-8\)/\1/" "$1/etc/locale.gen"; if [ -n "'"$SYNO_LOCALE"'" ]; then sed -i "s/^# *\('"$SYNO_LOCALE"' \)/\1/" "$1/etc/locale.gen"; grep -q "^'"$SYNO_LOCALE"' " "$1/etc/locale.gen" || { echo "SYNO_LOCALE '"$SYNO_LOCALE"' not in locale.gen"; exit 1; }; fi; chroot "$1" locale-gen >/dev/null' \
  --customize-hook='[ -e "$1/usr/share/zoneinfo/'"$SYNO_TZ"'" ] || { echo "SYNO_TZ '"$SYNO_TZ"' not found"; exit 1; }; ln -sf "/usr/share/zoneinfo/'"$SYNO_TZ"'" "$1/etc/localtime"; echo "'"$SYNO_TZ"'" > "$1/etc/timezone"' \
  trixie "$W/root"
# mmdebstrap's own tarball output writes every entry as 0/0 (seen on real root too);
# a directory target keeps the real owners, so build into a directory and pack it
# with GNU tar. Acceptance check: the non-root groups must be there.
# Names are resolved in the NEW system's passwd/group, not the build host's: the build
# host (e.g. a Debian 12 build box) can give the same gid another name (101 = input there,
# _ssh in trixie).
chk() {
	u="$(awk -F: -v n="${1%%:*}" '$1 == n {print $3}' "$W/root/etc/passwd")"
	g="$(awk -F: -v n="${1##*:}" '$1 == n {print $3}' "$W/root/etc/group")"
	have="$(stat -c %u:%g "$W/root/$2")"
	[ -n "$u" ] && [ -n "$g" ] && [ "$have" = "$u:$g" ] || { echo "OWNERSHIP CHECK FAILED: $2 is $have, want $1 ($u:$g)"; exit 1; }
}
chk root:shadow etc/shadow
chk root:shadow usr/bin/chage
chk root:shadow usr/sbin/unix_chkpwd
chk root:_ssh usr/bin/ssh-agent
chk root:messagebus usr/lib/dbus-1.0/dbus-daemon-launch-helper
chk root:root .
chk root:root etc
chk root:root usr/local/sbin/syno-disks
chk root:root root/.ssh
chk root:root root/.ssh/authorized_keys
odd="$(find "$W/root" -xdev \( -uid +65000 -o -gid +65000 \) -print | head -5)"
[ -z "$odd" ] || { echo "OWNERSHIP CHECK FAILED: foreign uid/gid on: $odd"; exit 1; }
echo "ownership check ok"
tar --numeric-owner --xattrs --xattrs-include='*' --acls -cpf "$OUT/syno-rootfs.tar" -C "$W/root" \
  --exclude='./dev/*' --exclude='./proc/*' --exclude='./sys/*' --exclude='./run/*' .
zstd -q -T0 -10 -f --rm "$OUT/syno-rootfs.tar" -o "$OUT/syno-rootfs.tar.zst"
( cd "$OUT" && sha256sum syno-rootfs.tar.zst > SHA256SUMS )
echo "host $SYNO_HOSTNAME, network $SYNO_NET, tz $SYNO_TZ, locale ${SYNO_LOCALE:-en_US.UTF-8 only}" > "$OUT/SETTINGS.txt"
ls -la "$OUT"
