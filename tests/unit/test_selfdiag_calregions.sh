#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# S3.22 cal_regions_populated from ax23-selfdiag.sh on synthetic files (no real calibration).
# With board data present it also checks the region lists against the local stock EU BDFs.
set -u
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
fn=$(sed -n '/# --- cal-regions begin/,/# --- cal-regions end/p' "$PROJ/tests/hardware/ax23-selfdiag.sh")
[ -n "$fn" ] || { echo "FAIL cal_regions_populated not found"; exit 1; }
eval "$fn"
fail=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
head -c 131072 /dev/zero >"$W/zero.bin"
[ "$(cal_regions_populated "$W/zero.bin" "$CAL_REGIONS_2G")" = "0/39" ] && ok "all-zero file: 0/39" || bad "all-zero file"
cp "$W/zero.bin" "$W/two.bin"
printf '\001' | dd of="$W/two.bin" bs=1 seek=$((0x5580 + 7)) conv=notrunc 2>/dev/null	# last byte of the first region
printf '\377' | dd of="$W/two.bin" bs=1 seek=$((0xd57c)) conv=notrunc 2>/dev/null	# first byte of the last region
printf '\001' | dd of="$W/two.bin" bs=1 seek=$((0x5588)) conv=notrunc 2>/dev/null	# just past region 1: not counted
[ "$(cal_regions_populated "$W/two.bin" "$CAL_REGIONS_2G")" = "2/39" ] && ok "region edges: 2/39" || bad "region edges: $(cal_regions_populated "$W/two.bin" "$CAL_REGIONS_2G")"
[ "$(cal_regions_populated "$W/absent.bin" "$CAL_REGIONS_5G")" = "missing" ] && ok "absent file: missing" || bad "absent file"
head -c 4096 /dev/zero | tr '\0' '\001' >"$W/short.bin"
[ "$(cal_regions_populated "$W/short.bin" "$CAL_REGIONS_5G")" = "0/44" ] && ok "short file: regions past EOF not counted" || bad "short file"
# the lists must describe the stock EU board data: every region zero there
for pair in "2G bdwlan.b24" "5G qcn6122/bdwlan.b60"; do
	band=${pair%% *}; src=""
	for d in /tmp/claude-*/*/*/scratchpad/oem-mem/fs1/EU/00000001/lib/firmware/IPQ5018/WIFI_FW; do [ -f "$d/${pair#* }" ] && src="$d/${pair#* }"; done
	[ -n "$src" ] || { echo "SKIP $band list check (no local stock EU board data)"; continue; }
	[ "$band" = 2G ] && regs=$CAL_REGIONS_2G || regs=$CAL_REGIONS_5G
	[ "$(cal_regions_populated "$src" "$regs" | cut -d/ -f1)" = 0 ] && ok "$band regions are all zero in the stock EU board data" || bad "$band list does not match the stock EU board data"
done
exit $fail
