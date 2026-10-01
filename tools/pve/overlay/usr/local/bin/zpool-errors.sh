#!/bin/sh
# SNMP extend: sum of READ + WRITE + CKSUM errors on all vdevs of all pools, -1 = unknown
zpool status -p 2>/dev/null | awk '
	/^[[:space:]]*NAME[[:space:]]+STATE[[:space:]]+READ/ { in_cfg = 1; next }
	in_cfg && NF == 0 { in_cfg = 0 }
	in_cfg && NF >= 5 && $3 ~ /^[0-9]+$/ { s += $3 + $4 + $5; seen = 1 }
	END { print (seen ? s : -1) }'
