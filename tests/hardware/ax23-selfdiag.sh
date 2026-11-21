#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# AX23 v2 self-diagnostic. Runs ON THE ROUTER under a RAM-booted OpenWrt
# initramfs of this project. READ-ONLY and REDACTED:
#   - reads procfs/sysfs, dmesg, iw/ip/ubus output and selected U-Boot env keys
#   - never writes flash, the U-Boot environment, UCI, sysfs or debugfs, and
#     never mounts, loads modules, changes links or starts/stops services
#   - prints MAC addresses as OUI:xx:xx:xx, hides public IPv4 addresses,
#     serial numbers, SSIDs and keys; prints sizes and hashes of board/cal
#     data, never their contents
# Usage from the PC (output stays on the PC):
#   ssh root@192.168.1.1 sh -s < tests/hardware/ax23-selfdiag.sh > selfdiag-$(date +%Y%m%d-%H%M%S).txt
#   ssh root@192.168.1.1 sh -s -- --bundle < tests/hardware/ax23-selfdiag.sh > bundle.txt   # + filtered dmesg
# Output: one line per check, "ID<TAB>STATUS<TAB>check<TAB>evidence",
# STATUS = PASS / FAIL / WARN / BLOCKED / INFO, then a per-stage summary.
# See reports/physical-hardware-test-plan.md for what each stage gates.

export LC_ALL=C
FAILS=0; WARNS=0; BLOCKS=0

redact() {
	sed -E \
	  -e 's/(([0-9A-Fa-f]{2}:){3})([0-9A-Fa-f]{2}:){2}[0-9A-Fa-f]{2}/\1xx:xx:xx/g' \
	  -e 's/(serial|Serial|SERIAL)([=: ]+)[^ ,;]+/\1\2<redacted>/g'
}
# addresses: keep RFC1918/link-local/loopback, hide everything else (applied to address fields only)
ipred() {
	for a in "$@"; do
		case "$a" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|127.*|169.254.*) printf '%s ' "$a" ;;
		*) printf '<public-ip> ' ;; esac
	done
}
r() {
	case "$2" in FAIL) FAILS=$((FAILS+1)) ;; WARN) WARNS=$((WARNS+1)) ;; BLOCKED) BLOCKS=$((BLOCKS+1)) ;; esac
	printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(printf '%s' "$4" | tr '\n\t' '  ' | redact)"
}
D=$(dmesg 2>/dev/null)
have() { command -v "$1" >/dev/null 2>&1; }

echo "# ax23-selfdiag $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) (read-only, redacted)"

# ---- Stage 1: identity and boot mode -------------------------------------
b=$(cat /tmp/sysinfo/board_name 2>/dev/null)
[ "$b" = "tplink,archer-ax23-v2" ] && r S1.1 PASS "board name" "$b" || r S1.1 FAIL "board name" "${b:-unknown}"
r S1.2 INFO "model" "$(cat /tmp/sysinfo/model 2>/dev/null)"
r S1.3 INFO "kernel" "$(uname -r) $(uname -m)"
r S1.4 INFO "openwrt release" "$(. /etc/openwrt_release 2>/dev/null; echo "$DISTRIB_DESCRIPTION")"
rt=$(awk '$2=="/"{t=$3} END{print t}' /proc/mounts)
case "$rt" in rootfs|tmpfs|ramfs) r S1.5 PASS "RAM boot (root not on flash)" "root fstype=$rt" ;;
	*) r S1.5 FAIL "RAM boot (root not on flash)" "root fstype=$rt: STOP, this is not the RAM image" ;; esac
grep -q "ubi\.mtd=\|root=/dev/ubi" /proc/cmdline && r S1.6 WARN "cmdline mentions UBI root" "$(cat /proc/cmdline)" || r S1.6 PASS "cmdline has no UBI root" "$(cat /proc/cmdline)"
grep -q platform_upgrade_blocked /lib/upgrade/platform.sh 2>/dev/null && r S1.7 PASS "sysupgrade interlock present" "" \
	|| r S1.7 FAIL "sysupgrade interlock" "absent: do not run sysupgrade"

# ---- Stage 1: flash protection (sysfs only; no device node is opened) -----
if [ -d /sys/class/mtd ]; then
	seen=0
	for m in /sys/class/mtd/mtd*; do
		case "$m" in *ro) continue ;; esac
		[ -f "$m/name" ] || continue
		seen=$((seen+1))
		n=$(cat "$m/name"); s=$(cat "$m/size" 2>/dev/null)
		if ! f=$(cat "$m/flags" 2>/dev/null) || [ -z "$f" ]; then
			r S1.8 FAIL "mtd $n flags unavailable" "size=$s"
		elif [ $((f & 0x400)) -eq 0 ]; then
			r S1.8 PASS "mtd $n read-only" "size=$s flags=$f"
		else
			r S1.8 FAIL "mtd $n writable" "size=$s flags=$f"
		fi
	done
	[ "$seen" -eq 16 ] || r S1.9 FAIL "unexpected MTD inventory" "$seen nodes"
else r S1.8 FAIL "mtd sysfs" "no /sys/class/mtd"; fi
grep -q "ubi" /proc/mounts && r S1.10 INFO "UBI-backed mounts" "$(grep ubi /proc/mounts | awk '{print $2":"$3":"$4}')" || r S1.10 INFO "UBI-backed mounts" "none"
grep -q " /tmp/tp_data " /proc/mounts && { grep -q " /tmp/tp_data .* ro[, ]" /proc/mounts \
	&& r S1.11 PASS "tp_data mounted read-only" "" || r S1.11 FAIL "tp_data read-only" "$(grep tp_data /proc/mounts)"; } \
	|| r S1.11 WARN "tp_data mounted" "not mounted: MAC/caldata derivation may fail"

# U-Boot env: read selected keys only (patch 0011). fw_printenv only reads.
if have fw_printenv && [ -s /etc/fw_env.config ]; then
	for k in tp_boot_idx bootcmd bootdelay; do
		v=$(fw_printenv -n "$k" 2>/dev/null); r S1.12 INFO "u-boot env $k" "${v:-<unset or env CRC bad>}"
	done
	fw_printenv >/dev/null 2>&1 && r S1.13 INFO "u-boot env CRC" "valid" || r S1.13 INFO "u-boot env CRC" "not valid (U-Boot uses built-in defaults)"
else r S1.12 INFO "u-boot env" "fw_printenv or /etc/fw_env.config absent"; fi

r S1.14 INFO "device tree model" "$(tr -d '\0' </proc/device-tree/model 2>/dev/null)"
nub=0; nro=0
for u in /sys/class/ubi/ubi[0-9]*; do
	case "$u" in *_*) continue ;; esac
	[ -e "$u/mtd_num" ] || continue
	nub=$((nub+1))
	m=$(cat "$u/mtd_num"); f=$(cat /sys/class/mtd/mtd$m/flags 2>/dev/null)
	[ -n "$f" ] && [ $((f & 0x400)) -eq 0 ] && nro=$((nro+1))
done
[ "$nub" -eq "$nro" ] && r S1.15 PASS "every attached UBI has a verified read-only backing MTD" "$nub attached, $nro read-only" \
	|| r S1.15 FAIL "UBI backing MTD read-only check failed" "$nub attached, only $nro read-only: STOP"
r S1.16 INFO "radio bring-up profile (ax23_radios=)" "$(cat /tmp/ax23_radio_profile 2>/dev/null || echo 'unset (both)')"

# ---- Stage 2: wired networking --------------------------------------------
l=$(echo "$D" | grep -m1 "found an RTL8367S")
case "$l" in *RTL8367S-VB*) r S2.1 PASS "switch probed as RTL8367S-VB" "$l" ;; "") r S2.1 FAIL "switch probe" "no rtl8365mb probe line" ;; *) r S2.1 WARN "switch family" "$l" ;; esac
l=$(echo "$D" | grep -m1 "Link is Up - 2.5Gbps/Full")
[ -n "$l" ] && r S2.2 PASS "CPU trunk up at 2.5G" "$l" || r S2.2 FAIL "CPU trunk 2.5G" "$(echo "$D" | grep -iE 'eth0|gmac|uniphy' | tail -2)"
for p in eth0 wan lan1 lan2 lan3 lan4; do
	d=/sys/class/net/$p
	if [ -d $d ]; then
		r S2.3 INFO "port $p" "oper=$(cat $d/operstate 2>/dev/null) carrier=$(cat $d/carrier 2>/dev/null) speed=$(cat $d/speed 2>/dev/null) mtu=$(cat $d/mtu) rx=$(cat $d/statistics/rx_packets) tx=$(cat $d/statistics/tx_packets) rx_err=$(cat $d/statistics/rx_errors) tx_err=$(cat $d/statistics/tx_errors)"
	else [ "$p" = eth0 ] || r S2.3 FAIL "port $p netdev" "missing"; fi
done
e=$(cat /sys/class/net/eth0/statistics/rx_packets 2>/dev/null); t=$(cat /sys/class/net/eth0/statistics/tx_packets 2>/dev/null)
[ "${e:-0}" -gt 0 ] && [ "${t:-0}" -gt 0 ] && r S2.4 PASS "frames cross the CPU trunk both ways" "eth0 rx=$e tx=$t" \
	|| r S2.4 FAIL "frames cross the CPU trunk" "eth0 rx=$e tx=$t (EX511 v2 saw link-up with zero frames on HSGMII)"
n=$(echo "$D" | grep -ciE "re-latch|did not latch|sds.*latch")
r S2.5 INFO "777-08 SerDes re-latch events" "$n"
# shellcheck disable=SC2046  # word splitting of the address list is intended
for i in br-lan wan; do r S2.6 INFO "address $i" "$(ipred $(ip -4 -o addr show dev "$i" 2>/dev/null | awk '{print $4}'))"; done
r S2.7 INFO "default route via" "$(ip -4 route show default 2>/dev/null | awk '{print $5}')"

# ---- Stage 3: Wi-Fi bring-up ---------------------------------------------
[ -e /lib/firmware/ath11k/AX23-V2-BOARD-DATA-MISSING ] && r S3.1 BLOCKED "board data packaged" "image built without board files"
for f in /lib/firmware/ath11k/IPQ5018/hw1.0/board-2.bin /lib/firmware/ath11k/QCN6122/hw1.0/board-2.bin; do
	[ -f "$f" ] && r S3.2 INFO "board-2.bin $(echo $f | cut -d/ -f5)" "size=$(wc -c <"$f") sha256=$(sha256sum "$f" | cut -c1-16)…" \
		|| r S3.2 FAIL "board-2.bin present" "$f missing"
done
for f in /lib/firmware/ath11k/IPQ5018/hw1.0/cal-ahb-c000000.wifi.bin /lib/firmware/ath11k/QCN6122/hw1.0/cal-ahb-b00a040.wifi.bin; do
	[ -f "$f" ] && r S3.3 INFO "caldata $(echo $f | cut -d/ -f5)" "size=$(wc -c <"$f") (contents not printed)" || r S3.3 WARN "caldata present" "$f missing"
done
echo "$D" | grep -q "failed to fetch board\|failed to load board data" && r S3.4 FAIL "board data loaded" "fetch/load failure lines in dmesg" \
	|| r S3.4 PASS "no board-data fetch/load failure" ""
echo "$D" | grep -E "ath11k.*fw_build_id" | while read -r x; do r S3.5 INFO "ath11k firmware" "$x"; done
echo "$D" | grep -iE "ath11k.*(FW memory mode|Multipd|hw1.0)" | head -6 | while read -r x; do r S3.6 INFO "ath11k probe" "$x"; done
echo "$D" | grep -q "regd update : -22\|failed register the radio" && r S3.7 FAIL "regulatory init" "regd update failed (EX511 v2 saw this with a stock 5 GHz BDF)" \
	|| r S3.7 PASS "no regd update failure" ""
alloc_errors=$(echo "$D" | grep -iE "ath11k.*(-12|-ENOMEM|failed to set ?up|failed to alloc|qmi failed memory)" | head -4)
[ -z "$alloc_errors" ] || r S3.8 FAIL "ath11k allocation/setup failure" "$alloc_errors"
profile=$(cat /tmp/ax23_radio_profile 2>/dev/null)
for dev in c000000.wifi b00a040.wifi; do
    registered=0
    for ph in "/sys/bus/platform/devices/$dev"/ieee80211/phy*; do
        [ -e "$ph" ] && registered=1
    done
    case "$profile:$dev" in
        none:*|2g:b00a040.wifi|5g:c000000.wifi) expected=0 ;;
        both:*|seq:*|2g:c000000.wifi|5g:b00a040.wifi) expected=1 ;;
        *) r S3.9 FAIL "radio profile missing or incomplete" "$profile"; break ;;
    esac
    if [ "$registered" = "$expected" ]; then
        r S3.9 PASS "$dev matches profile $profile" "registered=$registered"
    else
        r S3.9 FAIL "$dev differs from profile $profile" "registered=$registered expected=$expected"
    fi
done
for phd in /sys/class/ieee80211/*; do
	[ -e "$phd" ] || continue; ph=${phd##*/}
	band=$(iw phy "$ph" info 2>/dev/null | grep -qE "2412(\.0)? MHz" && echo 2.4G || echo 5G)
	r S3.10 INFO "phy band" "$ph=$band"
done
r S3.11 INFO "regulatory domain" "$(iw reg get 2>/dev/null | grep -m1 country)"
have iw && for dev in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
	r S3.12 INFO "vif $dev" "type=$(iw dev $dev info | awk '/type/{print $2}') chan=$(iw dev $dev info | awk '/channel/{print $2,$5,$6}') stations=$(iw dev $dev station dump 2>/dev/null | grep -c ^Station)"
done
c=$(echo "$D" | grep -ciE "firmware crashed|fatal error received|q6v5.*fatal|rproc.*crash|USER-PD DOG")
[ "$c" -eq 0 ] && r S3.13 PASS "no Q6/WCSS firmware crash" "0" || r S3.13 FAIL "Q6/WCSS firmware crash" "$c events"
n=$(echo "$D" | grep -c "status_fifo is full")
[ "$n" -eq 0 ] && r S3.14 PASS "no TX completion FIFO-full warnings" "0" || r S3.14 WARN "TX completion FIFO-full warnings" "$n (see 961)"
for rp in /sys/class/remoteproc/remoteproc*; do
	[ -e "$rp/name" ] || continue
	r S3.15 INFO "remoteproc $(cat "$rp/name")" "driver=$(readlink -f "$rp/device/driver" 2>/dev/null) state=$(cat "$rp/state" 2>/dev/null) coredump=$(cat "$rp/coredump" 2>/dev/null) recovery=$(cat "$rp/recovery" 2>/dev/null)"
done
for mode in /sys/class/remoteproc/remoteproc*/coredump; do
    [ -r "$mode" ] || continue
    if [ "$(cat "$mode")" = inline ]; then
        r S3.16 WARN "inline remoteproc coredump policy" "$mode"
    else
        r S3.16 INFO "remoteproc coredump policy" "$mode=$(cat "$mode")"
    fi
done
for d in c000000.wifi b00a040.wifi; do
	o=$(cat /sys/bus/platform/devices/$d/driver_override 2>/dev/null)
	b=$(basename "$(readlink /sys/bus/platform/devices/$d/driver 2>/dev/null)" 2>/dev/null)
	r S3.17 INFO "wifi device $d" "driver=${b:-unbound} override=${o:-none-set}"
done
echo "$D" | grep -E "ath11k.*(firmware request|failed to fetch|board name|qmi failed|chip_id|fw_build_id)" | head -12 | \
	while read -r x; do r S3.18 INFO "ath11k firmware/board request" "$x"; done

# ---- Memory (all stages) --------------------------------------------------
for k in MemTotal MemFree MemAvailable Buffers Cached Shmem Slab SUnreclaim KernelStack PageTables; do
	v=$(awk -v k="$k:" '$1==k{print $2}' /proc/meminfo); r M.1 INFO "meminfo $k" "${v} kB"
done
ma=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
[ "${ma:-0}" -ge 51200 ] && r M.2 PASS "MemAvailable >= 50 MiB" "$ma kB" || r M.2 WARN "MemAvailable >= 50 MiB" "$ma kB"
# free blocks per order: orders >= 5 matter for the ath11k rings (961: order 5/4; default: order 9/8)
awk '$4=="Normal"||$4=="DMA"||$4=="DMA32"{o=""; for(i=5;i<=NF;i++) o=o" o"(i-5)"="$i; print $4":"o}' /proc/buddyinfo 2>/dev/null \
	| while read -r x; do r M.3 INFO "buddyinfo" "$x"; done
hi=$(awk '{for(i=14;i<=NF;i++) s+=$i} END{print s+0}' /proc/buddyinfo 2>/dev/null)
r M.4 INFO "free blocks of order >= 9 (2 MiB+ on 4 KiB pages)" "$hi"
echo "$D" | grep -qE "Out of memory|oom-kill" && r M.5 FAIL "no OOM kills" "see dmesg" || r M.5 PASS "no OOM kills" ""
echo "$D" | grep -qE "page allocation failure" && r M.6 WARN "page allocation failures" "$(echo "$D" | grep -m2 'page allocation failure')" || r M.6 PASS "no page allocation failures" ""
r M.7 INFO "coherent pool" "$(tr ' ' '\n' </proc/cmdline | grep coherent_pool)"
r M.8 INFO "reserved (no-map) regions" "$(ls /proc/device-tree/reserved-memory 2>/dev/null | tr '\n' ' ')"
grep -E "^(kmalloc-(8k|4k|2k|1k)|skbuff_head_cache|kmalloc-rcl|names_cache|dentry|inode_cache) " /proc/slabinfo 2>/dev/null | \
	awk '{printf "%s=%dKiB ", $1, $3*$4/1024}' | while read -r x; do r M.9 INFO "largest slab caches" "$x"; done
r M.10 INFO "page allocation failure / Order lines" "$(echo "$D" | grep -cE 'page allocation failure|order:[5-9]')"

# ---- Health ---------------------------------------------------------------
for t in /sys/class/thermal/thermal_zone*; do [ -f "$t/temp" ] && r H.1 INFO "thermal $(cat $t/type)" "$(cat $t/temp) mC"; done
[ -e /dev/watchdog ] && r H.2 PASS "watchdog device present" "" || r H.2 WARN "watchdog device" "missing"
r H.3 INFO "uptime/load" "$(cat /proc/uptime) | $(cat /proc/loadavg)"
r H.4 INFO "processes" "$(ls -d /proc/[0-9]* | wc -l)"
w=$(echo "$D" | grep -ciE "warning|call trace|BUG:|Oops")
[ "$w" -eq 0 ] && r H.5 PASS "no kernel WARN/Oops/BUG" "0" || r H.5 WARN "kernel WARN/Oops/BUG lines" "$w (attach dmesg)"

# ---- optional bundle: filtered, redacted kernel log for a remote reviewer ----
if [ "${1:-}" = "--bundle" ]; then
	echo "# ---- dmesg (filtered: radios, remoteproc, switch, NAND/UBI, memory, warnings) ----"
	echo "$D" | grep -iE "ath11k|qmi|remoteproc|q6v5|wcss|rtl83|rtl8365|dsa|uniphy|gmac|eth0|mtd|ubi|nand|oom|out of memory|allocation failure|warning|call trace|bug:|oops|panic|cmdline|memory:" | redact
	echo "# ---- /proc/meminfo, /proc/buddyinfo ----"; cat /proc/meminfo /proc/buddyinfo 2>/dev/null
	echo "# ---- /proc/mtd ----"; cat /proc/mtd 2>/dev/null
fi
echo "# summary: FAIL=$FAILS WARN=$WARNS BLOCKED=$BLOCKS"
echo "# gate: Stage 1 needs S1.* PASS (incl. S1.15 UBI read-only); Stage 2 needs S2.1/S2.2/S2.4 PASS; Stage 3 needs S3.4/S3.7/S3.9/S3.13 PASS and no S3.8 lines"
