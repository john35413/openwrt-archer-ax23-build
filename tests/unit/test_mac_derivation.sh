#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Runs OpenWrt's own get_mac_binary/macaddr_add (package/base-files system.sh)
# on synthetic tp_data/default-mac files, with the offsets used by the AX23 v2
# board scripts: lan=base (02_network), wan=base+1, 2.4G=base-1, 5G=base-2
# (11-ath11k-caldata). Synthetic, locally administered MACs only.
set -u
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
SYS="${SYSTEM_SH:-$PROJ/build/patchwork/package/base-files/files/lib/functions/system.sh}"
[ -f "$SYS" ] || SYS="$PROJ/upstream/openwrt/package/base-files/files/lib/functions/system.sh"
command -v hexdump >/dev/null || { echo "SKIP hexdump missing"; exit 77; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
rc=0
check() {	# base-bytes(hex) expect_lan expect_wan expect_2g expect_5g
	printf "$(echo "$1" | sed 's/../\\x&/g')" > "$T/default-mac"
	out=$( (set +u; . "$SYS" 2>/dev/null
		b=$(get_mac_binary "$T/default-mac" 0)
		echo "$b $(macaddr_add "$b" 1) $(macaddr_add "$b" -1) $(macaddr_add "$b" -2)") )
	want="$2 $3 $4 $5"
	if [ "$out" = "$want" ]; then echo "PASS $1 -> $out"; else echo "FAIL $1 -> '$out' want '$want'"; rc=1; fi
}
check 020000aabb10 02:00:00:aa:bb:10 02:00:00:aa:bb:11 02:00:00:aa:bb:0f 02:00:00:aa:bb:0e
check 020000aabbff 02:00:00:aa:bb:ff 02:00:00:aa:bc:00 02:00:00:aa:bb:fe 02:00:00:aa:bb:fd
check 020000ab0000 02:00:00:ab:00:00 02:00:00:ab:00:01 02:00:00:aa:ff:ff 02:00:00:aa:ff:fe
# a missing file must yield an empty MAC (board scripts then skip patching)
out=$( (set +u; . "$SYS" 2>/dev/null; get_mac_binary "$T/nonexistent" 0 2>/dev/null) )
[ -z "$out" ] && echo "PASS missing default-mac -> empty" || { echo "FAIL missing file -> '$out'"; rc=1; }
exit $rc
