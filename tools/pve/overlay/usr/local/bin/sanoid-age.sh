#!/bin/sh
# SNMP extend: age in minutes of the newest sanoid snapshot (autosnap_*), -1 = none or unknown
t=$(zfs list -H -p -t snapshot -o creation,name 2>/dev/null | awk '$2 ~ /@autosnap_/ { if ($1 > m) m = $1 } END { print m + 0 }')
[ "${t:-0}" -gt 0 ] 2>/dev/null || { echo -1; exit 0; }
echo $(( ($(date +%s) - t) / 60 ))
