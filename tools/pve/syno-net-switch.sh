#!/bin/sh
# Moves a DS220+ running Proxmox VE to another network in one step, for the next
# power-on: the fixed address of the installed system and of ZFSBootMenu (zbm-net.conf on
# the DOM) change together. Run it on the box right before shutting down for transport.
#   syno-net-switch.sh ADDRESS/PREFIX GATEWAY "DNS1 DNS2 ..." FQDN [--apply]
#   e.g. syno-net-switch.sh 192.0.2.50/24 192.0.2.1 "192.0.2.11 192.0.2.12" nas.example.lan --apply
# Without --apply it only shows what would change. With --apply it writes the files (the
# running network is left alone) and powers the box off. After the first boot on the new
# network: pvecm updatecerts --force (web certificate for the new address).
set -eu
addr="${1:?address/prefix}"; gw="${2:?gateway}"; dns="${3:?dns servers}"; fqdn="${4:?fqdn}"
apply="${5:-}"
ip="${addr%/*}"; short="${fqdn%%.*}"; domain="${fqdn#*.}"
case "$addr" in *.*.*.*/*) ;; *) echo "bad address: $addr"; exit 64 ;; esac
# the node name is not changed here (a Proxmox node rename also moves /etc/pve/nodes/<name>)
[ "$short" = "$(hostname)" ] || { echo "fqdn $fqdn does not match the host name $(hostname)"; exit 64; }

new=$(mktemp -d)
trap 'rm -rf "$new"' EXIT
sed -e "s#^\taddress .*#\taddress $addr#" -e "s#^\tgateway .*#\tgateway $gw#" \
	/etc/network/interfaces > "$new/interfaces"
{ printf '127.0.0.1\tlocalhost\n%s\t%s %s\n' "$ip" "$fqdn" "$short"; } > "$new/hosts"
{ printf 'search %s\n' "$domain"; for d in $dns; do printf 'nameserver %s\n' "$d"; done; } > "$new/resolv.conf"
printf '# ZFSBootMenu fixed address. Without this file ZBM uses DHCP.\naddress=%s\ngateway=%s\n' \
	"$addr" "$gw" > "$new/zbm-net.conf"

D2=$(blkid -U 45e5b07d-4783-4867-a369-f99c0cd1e610)
mkdir -p /mnt/dom2
mount -o ro "$D2" /mnt/dom2
for f in interfaces hosts resolv.conf; do
	case $f in interfaces) cur=/etc/network/interfaces ;; *) cur=/etc/$f ;; esac
	echo "== $cur"; diff "$cur" "$new/$f" || true
done
echo "== DOM zbm-net.conf"; diff /mnt/dom2/zbm-net.conf "$new/zbm-net.conf" 2>/dev/null || cat "$new/zbm-net.conf"
umount /mnt/dom2

[ "$apply" = "--apply" ] || { echo "(dry run: nothing written; add --apply)"; exit 0; }

bk=/root/before-network-$(date +%Y%m%d-%H%M)
mkdir -p "$bk"
cp -a /etc/network/interfaces /etc/hosts /etc/resolv.conf "$bk/"
mount "$D2" /mnt/dom2
cp -a /mnt/dom2/zbm-net.conf "$bk/" 2>/dev/null || true
cp "$new/zbm-net.conf" /mnt/dom2/zbm-net.conf.tmp && sync && mv /mnt/dom2/zbm-net.conf.tmp /mnt/dom2/zbm-net.conf
sync; umount /mnt/dom2
cp "$new/interfaces" /etc/network/interfaces
cp "$new/hosts" /etc/hosts
cp "$new/resolv.conf" /etc/resolv.conf
sync
echo "written (old files in $bk); powering off"
systemctl poweroff
