#!/bin/sh
# SNMP extend: worst pool state. 0 = all ONLINE, 1 = DEGRADED, 2 = FAULTED/UNAVAIL/other, -1 = unknown
out=$(zpool list -H -o health 2>/dev/null) || { echo -1; exit 0; }
[ -z "$out" ] && { echo -1; exit 0; }
w=0
for h in $out; do
	case "$h" in
	ONLINE) ;;
	DEGRADED) [ $w -lt 1 ] && w=1 ;;
	*) w=2 ;;
	esac
done
echo $w
