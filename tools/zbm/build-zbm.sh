#!/bin/sh
# Builds a small ZFSBootMenu (kernel + initramfs) for the Synology DS220+ DOM.
# Proxmox kernel (ZFS built in) + Debian 13 + ZFSBootMenu from source. Run as REAL root on a
# Debian 12/13 or Proxmox host (not in an unprivileged container):
#   sudo SYNO_HOSTID=<hostid> ./build-zbm.sh [outdir]
# Put your SSH public key(s) in overlay/root/.ssh/authorized_keys first (see
# authorized_keys.example next to it; the build stops without the file).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/out}"
ZBM_VER=v3.1.0
# The hostid of the installed system, baked into ZFSBootMenu. Without it ZBM has to
# adopt the pool owner's hostid, and ZBM 3.1 only does that for ONLINE pools: with one
# disk missing (DEGRADED) the import fails ("last accessed by another system").
# Required, 8 lower-case hex digits. For a new install pick any (e.g. "openssl rand -hex 4"):
# syno-install.sh writes the same one to the new system. For an existing system use
# the value "hostid" prints there.
SYNO_HOSTID="${SYNO_HOSTID:-}"
case "$SYNO_HOSTID" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) echo "SYNO_HOSTID: 8 lower-case hex digits required"; exit 2 ;; esac
# The host name ZFSBootMenu sends with its DHCP request (one per box, so two boxes in
# rescue mode do not claim the same DNS name).
SYNO_ZBM_NAME="${SYNO_ZBM_NAME:-syno-zbm}"
case "$SYNO_ZBM_NAME" in *[!a-z0-9-]*|"") echo "SYNO_ZBM_NAME: lower-case letters, digits and - only"; exit 2 ;; esac
mkdir -p "$OUT" "$HERE/keys"
[ -f "$HERE/keys/dropbear_ed25519_host_key" ] || \
	(cd /tmp && dropbearkey -t ed25519 -f "$HERE/keys/dropbear_ed25519_host_key" >/dev/null)
W="$(mktemp -d /tmp/zbm.XXXXXX)"
trap 'rm -rf "$W"' EXIT
curl -fsSL -o "$W/pve.gpg" https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg

mmdebstrap --mode=root --variant=minbase --components=main,non-free-firmware \
  --include=ca-certificates,curl,git,make,procps,less,kmod,util-linux,gdisk,tar,smartmontools,e2fsprogs,dracut,dracut-network,busybox,dropbear-bin,gpiod,iproute2,kexec-tools,fzf,mbuffer,libyaml-pp-perl,libsort-versions-perl,libboolean-perl,firmware-realtek,zstd,systemd-sysv \
  --customize-hook='mkdir -p "$1/usr/share/keyrings" && cp "'"$W"'/pve.gpg" "$1/usr/share/keyrings/proxmox-archive-keyring.gpg"' \
  --customize-hook='echo "deb [signed-by=/usr/share/keyrings/proxmox-archive-keyring.gpg] http://download.proxmox.com/debian/pve trixie pve-no-subscription" > "$1/etc/apt/sources.list.d/pve.list"' \
  --customize-hook='chroot "$1" apt-get update -qq' \
  --customize-hook='chroot "$1" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq proxmox-default-kernel zfsutils-linux >/dev/null' \
  --customize-hook='chroot "$1" git clone -q --depth 1 --branch '"$ZBM_VER"' https://github.com/zbm-dev/zfsbootmenu /usr/src/zfsbootmenu' \
  --customize-hook='chroot "$1" sh -c "cd /usr/src/zfsbootmenu && make core dracut >/dev/null"' \
  --customize-hook='cp -a --no-preserve=ownership "'"$HERE"'/overlay/." "$1/"' \
  --customize-hook='mkdir -p "$1/usr/local/sbin" && cp "'"$HERE"'/../bootguard/syno-bootguard" "$1/usr/local/sbin/" && chmod 755 "$1/usr/local/sbin/syno-bootguard"' \
  --customize-hook='mkdir -p "$1/etc/dropbear" && cp "'"$HERE"'/keys/dropbear_ed25519_host_key" "$1/etc/dropbear/"' \
  --customize-hook='chmod 755 "$1"/etc/zfsbootmenu/hooks/*/*.sh "$1/usr/local/sbin/syno-microp" "$1/etc/zfsbootmenu/udhcpc.script"; chmod 700 "$1/root/.ssh"; chmod 600 "$1/root/.ssh/authorized_keys"; mkdir -p "$1/out"' \
  --customize-hook='chroot "$1" zgenhostid -f '"$SYNO_HOSTID"' && od -An -tx4 "$1/etc/hostid"' \
  --customize-hook='echo "'"$SYNO_ZBM_NAME"'" > "$1/etc/zfsbootmenu/syno-zbm-name"' \
  --customize-hook='chroot "$1" generate-zbm --config /etc/zfsbootmenu/config.yaml' \
  --customize-hook='{ echo "zbm '"$ZBM_VER"' hostid '"$SYNO_HOSTID"' name '"$SYNO_ZBM_NAME"' built $(date -u +%FT%TZ)"; chroot "$1" dpkg-query -W "proxmox-kernel-*" zfsutils-linux busybox dracut dropbear-bin 2>/dev/null || echo "dpkg-query: missing pattern"; } > "$1/out/VERSIONS.txt"' \
  --customize-hook='l="$(chroot "$1" lsinitrd /out/initramfs-bootmenu.img)"; for x in wdat_wdt.ko hooks/early-setup.d/10-ds220.sh usr/local/sbin/syno-bootguard; do echo "$l" | grep -q "$x" || { echo "BUILD CHECK FAILED: $x not in the initramfs"; exit 1; }; done; echo "$l" | grep -q vfat.ko || grep -q "^CONFIG_VFAT_FS=y" "$1"/boot/config-* || { echo "BUILD CHECK FAILED: no vfat (module or built in)"; exit 1; }; echo "initramfs check ok" >> "$1/out/VERSIONS.txt"' \
  --customize-hook='copy-out /out "'"$W"'"' \
  trixie /dev/null

cp "$W"/out/* "$OUT/"
( cd "$OUT" && sha256sum vmlinuz-bootmenu initramfs-bootmenu.img > SHA256SUMS )
cat "$OUT/VERSIONS.txt"
ls -la "$OUT"
