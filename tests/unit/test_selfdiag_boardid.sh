#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# S3.20 board_id_check from ax23-selfdiag.sh against ath11k's real chip_id log format.
set -u
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
fn=$(sed -n '/# --- board-id-check begin/,/# --- board-id-check end/p' "$PROJ/tests/hardware/ax23-selfdiag.sh")
[ -n "$fn" ] || { echo "FAIL board_id_check not found"; exit 1; }
eval "$fn"
fail=0
t() {	# t NAME EXPECTED_OUTPUT DMESG DEV IDS...
	local name=$1 want=$2 dm=$3; shift 3
	local got; got=$(printf '%s\n' "$dm" | board_id_check "$@")
	[ "$got" = "$want" ] && echo "PASS $name ($got)" || { echo "FAIL $name: got '$got' want '$want'"; fail=1; }
}
L24="ath11k c000000.wifi: chip_id 0x0 chip_family 0x4 board_id 0xff soc_id 0xffffffff"
L5="ath11k b00a040.wifi: chip_id 0x0 chip_family 0x4 board_id 0x60 soc_id 0xffffffff"
t "unprogrammed OTP on 2.4 GHz" "ok 0xff" "$L24" c000000.wifi 0xff 0x24
t "stock selector OTP on 5 GHz" "ok 0x60" "$L5" b00a040.wifi 0xff 0x60
t "other radio's line ignored" "missing" "$L5" c000000.wifi 0xff 0x24
t "unknown OTP reported" "mismatch 0x2b" "ath11k c000000.wifi: chip_id 0x0 chip_family 0x4 board_id 0x2B soc_id 0x0" c000000.wifi 0xff 0x24
t "5 GHz id not accepted on 2.4 GHz" "mismatch 0x60" "ath11k c000000.wifi: chip_id 0x0 chip_family 0x4 board_id 0x60 soc_id 0x0" c000000.wifi 0xff 0x24
t "latest line wins after recovery" "ok 0x24" "$(printf '%s\n%s' "ath11k c000000.wifi: chip_id 0x0 chip_family 0x4 board_id 0x2b soc_id 0x0" "ath11k c000000.wifi: chip_id 0x0 chip_family 0x4 board_id 0x24 soc_id 0x0")" c000000.wifi 0xff 0x24
t "no Wi-Fi lines" "missing" "random line" b00a040.wifi 0xff 0x60
# the S3.20 loop must not clobber the positional parameters (--bundle is read later)
if grep -nE '(^|[;&| \t])set -- ' "$PROJ/tests/hardware/ax23-selfdiag.sh" >/dev/null; then echo "FAIL selfdiag resets positional parameters (breaks --bundle)"; fail=1
else echo "PASS selfdiag keeps \$1 for --bundle"; fi
exit $fail
