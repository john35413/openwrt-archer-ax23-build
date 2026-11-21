#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Runs ON THE ROUTER for 24/48 h soak tests; writes one CSV line per minute to
# stdout. Run from the PC so the log survives a router crash:
#   ssh root@192.168.1.1 'sh -s' < tests/hardware/soak-monitor.sh | tee soak-$(date +%s).csv
# Columns: epoch,uptime_s,load1,memavail_kB,slab_kB,ath11k_crash_total,oom_total,
#          temp_mC(max),wifi_stations,conntrack,wan_rx_bytes,wan_tx_bytes
echo "epoch,uptime_s,load1,memavail_kB,slab_kB,ath11k_crashes,ooms,temp_mC,stations,conntrack,wan_rx,wan_tx"
while :; do
	d=$(dmesg)
	cr=$(echo "$d" | grep -ci "firmware crashed\|q6v5.*fatal")
	oo=$(echo "$d" | grep -ci "oom-kill\|Out of memory")
	t=0; for z in /sys/class/thermal/thermal_zone*/temp; do [ -f "$z" ] && v=$(cat "$z") && [ "$v" -gt "$t" ] && t=$v; done
	st=0; for i in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do st=$((st + $(iw dev "$i" station dump | grep -c Station))); done
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date +%s)" "$(cut -d. -f1 /proc/uptime)" "$(cut -d' ' -f1 /proc/loadavg)" \
		"$(awk '/MemAvailable/{print $2}' /proc/meminfo)" "$(awk '/^Slab/{print $2}' /proc/meminfo)" "$cr" "$oo" "$t" "$st" \
		"$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)" \
		"$(cat /sys/class/net/wan/statistics/rx_bytes 2>/dev/null)" "$(cat /sys/class/net/wan/statistics/tx_bytes 2>/dev/null)"
	sleep 60
done
