#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Runs ON THE ROUTER (RAM-booted AX23 v2 OpenWrt initramfs). Read-only:
# it only reads dmesg, sysfs, procfs and tool output. Usage from the PC:
#   ssh root@192.168.1.1 sh -s < tests/hardware/router-collect.sh > hw-$(date +%s).tsv
# Every line is: ID <TAB> STATUS <TAB> check <TAB> evidence
# STATUS is PASS / FAIL / BLOCKED / INFO. NOT TESTED items are simply absent.
r() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }
D=$(dmesg)
has() { echo "$D" | grep -q "$1"; }

b=$(cat /tmp/sysinfo/board_name 2>/dev/null)
[ "$b" = "tplink,archer-ax23-v2" ] && r H01 PASS "board detected" "$b" || r H01 FAIL "board detected" "$b"
r H02 INFO "kernel / cmdline" "$(uname -r) | $(cat /proc/cmdline)"
rt=$(awk '$2=="/"{t=$3} END{print t}' /proc/mounts)
case "$rt" in rootfs|tmpfs|ramfs) r H03 PASS "RAM boot (root not on NAND)" "root fstype=$rt" ;; *) r H03 FAIL "RAM boot (root not on NAND)" "root fstype=$rt" ;; esac

l=$(echo "$D" | grep -m1 "found an RTL8367S")
case "$l" in *RTL8367S-VB*) r H04 PASS "switch probed as RTL8367S-VB" "$l" ;; "") r H04 FAIL "switch probe" "no rtl8365mb probe line" ;; *) r H04 FAIL "switch family" "$l" ;; esac
l=$(echo "$D" | grep -m1 "Link is Up - 2.5Gbps/Full")
[ -n "$l" ] && r H05 PASS "CPU trunk up at 2.5G" "$l" || r H05 FAIL "CPU trunk up at 2.5G" "$(echo "$D" | grep -i 'eth0\|gmac' | tail -2 | tr '\n' ' ')"
n=$(echo "$D" | grep -ci "re-latch\|did not latch\|sds.*latch")
r H06 INFO "777-08 SerDes re-latch events in dmesg" "$n"
for p in wan lan1 lan2 lan3 lan4; do
	if [ -d /sys/class/net/$p ]; then
		c=$(cat /sys/class/net/$p/carrier 2>/dev/null); s=$(cat /sys/class/net/$p/speed 2>/dev/null); du=$(cat /sys/class/net/$p/duplex 2>/dev/null)
		[ "$c" = 1 ] && r H07 PASS "port $p link" "carrier=1 speed=$s duplex=$du" || r H07 INFO "port $p link" "no carrier (cable?)"
	else r H07 FAIL "port $p netdev exists" "missing"; fi
done
if [ -f /tmp/tp_data/default-mac ]; then
	base=$(hexdump -v -n 6 -e '5/1 "%02x:" 1/1 "%02x"' /tmp/tp_data/default-mac)
	lan=$(cat /sys/class/net/br-lan/address 2>/dev/null); wan=$(cat /sys/class/net/wan/address 2>/dev/null)
	[ "$lan" = "$base" ] && r H08 PASS "br-lan MAC = tp_data default-mac" "match" || r H08 FAIL "br-lan MAC" "lan=$lan"
	. /lib/functions/system.sh; w=$(macaddr_add "$base" 1)
	[ "$wan" = "$w" ] && r H09 PASS "wan MAC = default-mac + 1" "match" || r H09 FAIL "wan MAC" "wan=$wan"
	grep -q "/tmp/tp_data .*ro[, ]" /proc/mounts && r H10 PASS "tp_data mounted read-only" "" || r H10 FAIL "tp_data read-only" "$(grep tp_data /proc/mounts)"
else r H08 FAIL "tp_data/default-mac present" "missing"; fi

nphy=$(ls /sys/class/ieee80211 2>/dev/null | wc -l)
if [ "$nphy" -ge 2 ]; then r H11 PASS "both radios registered" "$(ls /sys/class/ieee80211 | tr '\n' ' ')"
elif echo "$D" | grep -q "failed to fetch board"; then r H11 BLOCKED "radios registered" "board data missing ($nphy phys); see reports/wifi-investigation.md"
else r H11 FAIL "radios registered" "$nphy phys"; fi
[ -e /lib/firmware/ath11k/AX23-V2-BOARD-DATA-MISSING ] && r H12 BLOCKED "board data packaged" "image built without locally supplied board files"
echo "$D" | grep "ath11k" | grep -E "board|bdf|qmi failed|-12" | tail -4 | while read -r x; do r H13 INFO "ath11k board/qmi log" "$x"; done
for phd in /sys/class/ieee80211/*; do
	[ -e "$phd" ] || continue; ph=${phd##*/}
	band=$(iw phy "$ph" info 2>/dev/null | grep -qE "2412(\.0)? MHz" && echo 2.4G || echo 5G)
	r H14 INFO "phy band mapping (LED triggers assume phy0=2.4G)" "$ph=$band"
done
r H15 INFO "regulatory" "$(iw reg get 2>/dev/null | grep -m2 country | tr '\n' ' ')"
c=$(echo "$D" | grep -ci "firmware crashed\|fatal error.*wcss\|q6v5.*fatal\|rproc.*crash")
[ "$c" -eq 0 ] && r H16 PASS "no Q6/WCSS firmware crash in dmesg" "0" || r H16 FAIL "Q6/WCSS firmware crash" "$c events"
grep -E "MemTotal|MemFree|MemAvailable|Slab|CmaTotal" /proc/meminfo | tr -s ' ' | while read -r k v u; do r H17 INFO "meminfo $k" "$v $u"; done
ma=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
[ "$ma" -gt 51200 ] && r H18 PASS "MemAvailable > 50 MiB" "$ma kB" || r H18 FAIL "MemAvailable > 50 MiB" "$ma kB"
echo "$D" | grep -q "Out of memory\|oom-kill" && r H19 FAIL "no OOM kills" "see dmesg" || r H19 PASS "no OOM kills" ""
for t in /sys/class/thermal/thermal_zone*; do [ -f "$t/temp" ] && r H20 INFO "thermal $(cat $t/type)" "$(cat $t/temp) mC"; done
[ -e /dev/watchdog ] && r H21 PASS "watchdog device present" "$(ubus call system watchdog 2>/dev/null | tr -d '\n\t ')" || r H21 FAIL "watchdog device" "missing"
for l in /sys/class/leds/*; do r H22 INFO "LED $(basename $l)" "trigger=$(sed -n 's/.*\[\(.*\)\].*/\1/p' $l/trigger)"; done
[ -d /sys/kernel/debug/gpio ] || mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
grep -E "gpio-(14|39) " /sys/kernel/debug/gpio 2>/dev/null | while read -r x; do r H23 INFO "gpio" "$x"; done
grep -q platform_upgrade_blocked /lib/upgrade/platform.sh && r H24 PASS "sysupgrade interlock present" "" || r H24 FAIL "sysupgrade interlock" "absent - do not run sysupgrade"
r H25 INFO "uptime/load" "$(cat /proc/uptime) | $(cat /proc/loadavg)"
