#!/bin/sh
# Post-install settings for a single-node Proxmox VE 9 (trixie), done by hand instead of the
# community-scripts "post-pve-install" helper. Same result, nothing downloaded at run time.
# Run on the host as root, from this directory:  sh post-install.sh
#  1. apt sources in deb822 format: Debian + pve-no-subscription, enterprise disabled
#  2. subscription nag removal + apt hook that re-applies it after every package change
#     (pve-remove-nag.sh follows the community-scripts ProxmoxVE post-pve-install helper, MIT)
#  3. HA stack off (single node, no cluster): pve-ha-lrm, pve-ha-crm, corosync
#  4. never pull in GRUB or os-prober (the kernel packages only recommend them)
#  5. boot guard + hardware watchdog (see docs/rescue.md)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p /root/apt-old
for f in /etc/apt/sources.list /etc/apt/sources.list.d/pve.list; do
	[ -f "$f" ] && mv "$f" /root/apt-old/
done
cat > /etc/apt/sources.list.d/debian.sources <<EOT
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOT
cat > /etc/apt/sources.list.d/proxmox.sources <<EOT
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOT
E=/etc/apt/sources.list.d/pve-enterprise.sources
if [ -f "$E" ] && ! grep -q '^Enabled:' "$E"; then echo "Enabled: false" >> "$E"; fi

install -m 755 "$HERE/pve-remove-nag.sh" /usr/local/bin/pve-remove-nag.sh
install -m 644 "$HERE/no-nag-script" /etc/apt/apt.conf.d/no-nag-script
/usr/local/bin/pve-remove-nag.sh

systemctl disable --now pve-ha-lrm pve-ha-crm corosync

cat > /etc/apt/preferences.d/syno-no-grub <<EOT
# GRUB lives on the Synology DOM and ZFSBootMenu boots the system.
# Proxmox kernels only *recommend* a GRUB; never pull one in (and never os-prober).
Package: grub-pc grub-pc-bin grub-efi-amd64 grub-efi-amd64-bin grub-efi-amd64-signed grub-efi-ia32 grub-efi-ia32-bin os-prober
Pin: release *
Pin-Priority: -1
EOT

# 5. boot guard (ZFSBootMenu stays in its menu after a boot that never came up healthy)
#    and the hardware watchdog (a hang resets the box); files from tools/bootguard and
#    tools/pve/overlay of this repo
install -m 755 "$HERE/../../bootguard/syno-bootguard" /usr/local/sbin/syno-bootguard
install -m 755 "$HERE/../../bootguard/syno-bootguard-check" /usr/local/sbin/syno-bootguard-check
install -m 644 "$HERE/../../bootguard/syno-bootguard-ok.service" /etc/systemd/system/
install -m 644 "$HERE/../overlay/etc/systemd/system/syno-wdat.service" /etc/systemd/system/
install -D -m 644 "$HERE/../overlay/etc/systemd/system.conf.d/syno-watchdog.conf" /etc/systemd/system.conf.d/syno-watchdog.conf
systemctl daemon-reload
systemctl enable syno-bootguard-ok.service syno-wdat.service

apt-get update
systemctl restart pveproxy
echo "post-install done (the watchdog is armed from the next boot)"
