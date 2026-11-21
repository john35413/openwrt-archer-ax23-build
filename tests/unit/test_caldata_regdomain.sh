#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Regression test for ath11k_remove_regdomain() called without a target, as
# 11-ath11k-caldata does for the AX23 v2. Uses the real caldata.sh from the
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
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
command -v hexdump >/dev/null || { echo "SKIP hexdump not installed"; exit 77; }

# The function under test defaults to /lib/firmware/$FIRMWARE. If the host has
# no /lib/firmware, re-run inside a private mount namespace where an overlay on
# /usr/lib provides one; the host filesystem is never modified.
if [ ! -d /lib/firmware ] && [ -z "${IN_NS:-}" ]; then
	command -v unshare >/dev/null || { echo "SKIP no /lib/firmware and no unshare"; exit 77; }
	mkdir -p "$T/u" "$T/w"
	exec unshare -m --propagation private env IN_NS=1 OVL="$T" bash -c '
		mount -t overlay overlay -o lowerdir=/usr/lib,upperdir="$OVL/u",workdir="$OVL/w" /usr/lib &&
		mkdir -p /lib/firmware && exec bash "$0"' "$0"
fi

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

run() {	# run caldata.sh image -> prints 4 values
	local lib="$1" img="$2"
	# caldata_patch_data() writes /lib/firmware/$FIRMWARE; point FIRMWARE at
	# our temp file through a relative path so nothing in /lib is touched.
	(
		set +u
		d=$(dirname "$lib")	# .../lib/functions
		mkdir -p /lib/functions
		cp "$d/../functions.sh" /lib/functions.sh
		cp "$d/system.sh" /lib/functions/system.sh
		# shellcheck disable=SC1090
		. "$lib"
		mkdir -p /lib/firmware/t && cp "$img" /lib/firmware/t/cal.bin
		export FIRMWARE="t/cal.bin"
		ath11k_remove_regdomain </dev/null
		cp /lib/firmware/t/cal.bin "$img"
	) 2>/dev/null
	echo "$(at "$img" 0x34) $(at "$img" 0x450) $(at "$img" 0x458) $(at "$img" 0x500) $(at "$img" 0x5a8)"
}

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
