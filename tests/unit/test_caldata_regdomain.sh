#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Regression test for ath11k_remove_regdomain() called without a target, as
# used by other ipq50xx boards. AX23 preserves its factory regulatory words. Uses the real caldata.sh from the
# pristine OpenWrt base and from the patched build tree, on a synthetic
# 128 KiB caldata image (random bytes + a known regdomain at 0x34 and one
# copy at 0x450). No real calibration data is used.
#
# Expected:
#   base:    offsets 0x458/0x500/0x5a8 (NOT regdomain copies) get zeroed -> BUG
#   patched: only 0x34 and 0x450 are zeroed, everything else unchanged
set -u
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="${BASE_CALDATA:-$PROJ/upstream/openwrt/package/base-files/files/lib/functions/caldata.sh}"
PATCHED="${PATCHED_CALDATA:-$PROJ/build/dev/openwrt/package/base-files/files/lib/functions/caldata.sh}"
[ -r "$PATCHED" ] || { echo "SKIP no prepared dev caldata.sh"; exit 77; }
HOOK="$PROJ/build/dev/openwrt/target/linux/qualcommax/ipq50xx/base-files/etc/hotplug.d/firmware/11-ath11k-caldata"
python3 -I - "$HOOK" <<'CHECK' || exit 1
import sys
from pathlib import Path
hook = Path(sys.argv[1]).read_text()
radios = (
    ("ath11k/IPQ5018/hw1.0/cal-ahb-c000000.wifi.bin", "0x1000"),
    ("ath11k/QCN6122/hw1.0/cal-ahb-b00a040.wifi.bin", "0x26800"),
)
for name, offset in radios:
    path = hook.split(f'"{name}")', 1)[1].split("esac", 1)[0]
    board = path.split("tplink,archer-ax23-v2)", 1)[1].split(";;", 1)[0]
    if f'caldata_extract "0:ART" {offset} 0x20000' not in board or "ath11k_remove_regdomain" in board:
        sys.exit(f"FAIL factory regulatory calibration policy: {name}")
    print(f"PASS {name} preserves regulatory words from its own ART segment")
CHECK
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
command -v hexdump >/dev/null || { echo "SKIP hexdump not installed"; exit 77; }

mkimg() {
	head -c 131072 /dev/urandom >"$1"
	printf '\x00\x00\x00\x00\x00\x00\x00\x00' | dd of="$1" bs=1 seek=$((0x450)) conv=notrunc 2>/dev/null
	# regdomain 0x8114 at 0x34, copy at 0x450; non-copies at 0x458/0x500/0x5a8
	printf '\x81\x14' | dd of="$1" bs=1 seek=$((0x34)) conv=notrunc 2>/dev/null
	printf '\x81\x14' | dd of="$1" bs=1 seek=$((0x450)) conv=notrunc 2>/dev/null
	printf '\xaa\xbb' | dd of="$1" bs=1 seek=$((0x458)) conv=notrunc 2>/dev/null
	printf '\xcc\xdd' | dd of="$1" bs=1 seek=$((0x500)) conv=notrunc 2>/dev/null
	printf '\xee\xff' | dd of="$1" bs=1 seek=$((0x5a8)) conv=notrunc 2>/dev/null
}
at() { hexdump -v -n 2 -s "$2" -e '1/1 "%02x"' "$1"; }

run() (
    local lib="$1" img="$2" d
    d=$(dirname "$lib")
    cd "$T" || exit 1
    mkdir -p lib/functions lib/firmware/t
    cp "$d/../functions.sh" lib/functions.sh
    # Relocate only absolute OpenWrt dependency and firmware paths in the fixture.
    sed 's|^\. /lib/functions|. ./lib/functions|' "$d/system.sh" >lib/functions/system.sh
    sed -e 's|^\. /lib/functions|. ./lib/functions|' -e 's|/lib/firmware/|./lib/firmware/|g' "$lib" >lib/functions/caldata.sh
    set +u
    . ./lib/functions/caldata.sh
    export FIRMWARE=t/cal.bin
    cp "$img" "lib/firmware/$FIRMWARE"
    ath11k_remove_regdomain </dev/null >&2
    cp "lib/firmware/$FIRMWARE" "$img"
    echo "$(at "$img" 0x34) $(at "$img" 0x450) $(at "$img" 0x458) $(at "$img" 0x500) $(at "$img" 0x5a8)"
)

rc=0
for which in base patched; do
	lib=$BASE; [ $which = patched ] && lib=$PATCHED
	[ -f "$lib" ] || { echo "SKIP $which: $lib missing"; continue; }
	img="$T/cal-$which.bin"; mkimg "$img"
	got=$(run "$lib" "$img")
	echo "$which: 0x34 0x450 0x458 0x500 0x5a8 = $got"
	if [ $which = base ]; then
		# Documents the bug; not a failure of this project.
		[ "$got" = "0000 0000 0000 0000 0000" ] && echo "  base: CONFIRMED BUG (non-regdomain offsets zeroed)" \
			|| echo "  base: bug not reproduced on this host (stdin behaviour differs)"
	else
		if [ "$got" = "0000 0000 aabb ccdd eeff" ]; then echo "  PASS patched: only regdomain fields cleared"
		else echo "  FAIL patched: unexpected result"; rc=1; fi
	fi
done
exit $rc
