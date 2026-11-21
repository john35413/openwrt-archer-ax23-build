#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# PC/Pi-side, READ-ONLY full NAND backup of an AX23 v2 that is RAM-booted into
# the OpenWrt initramfs (nothing on flash is modified; nothing is written to the
# router except reading /dev/mtdNro, the kernel's read-only MTD nodes).
#
#   backup-flash-ro.sh [ROUTER_IP] [OUTDIR]
#
# Run this BEFORE any experiment that could ever touch flash. Keep the result
# offline and private: ART, tp_data and the env contain per-unit calibration,
# MAC addresses, Wi-Fi PIN and credentials.
#
# Each partition is streamed over SSH and verified against a sha256 computed
# on the router from a second read; a mismatch (e.g. ECC errors on a weak
# block) is reported, never silently ignored.
set -euo pipefail
IP="${1:-192.168.1.1}"; OUT="${2:-./ax23-flash-backup-$(date +%Y%m%d-%H%M%S)}"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 root@$IP"
mkdir -p "$OUT"; chmod 700 "$OUT"
$SSH 'cat /proc/mtd; cat /tmp/sysinfo/board_name; uname -a; grep -q initramfs /proc/cmdline 2>/dev/null; cat /proc/cmdline' >"$OUT/router-info.txt"
grep -q "tplink,archer-ax23-v2" "$OUT/router-info.txt" || { echo "not an AX23 v2 OpenWrt session; aborting"; exit 1; }
# Expect a RAM boot: rootfs on NAND must not be the running root.
if $SSH 'mount | grep -q " / .*ubi"'; then echo "router root is on UBI (not a RAM boot); aborting to stay read-only-safe"; exit 1; fi
fail=0
while read -r dev size _erase name; do
	dev=${dev%:}; name=${name//\"/}
	[ "$dev" = dev ] && continue
	f="$OUT/${dev}_${name//[:\/]/_}.bin"
	printf '%-6s %-14s %10d bytes ... ' "$dev" "$name" "$((16#$size))"
	$SSH "cat /dev/${dev}ro" >"$f" 2>"$f.err" || true
	local_sum=$(sha256sum "$f" | cut -d' ' -f1)
	remote_sum=$($SSH "sha256sum /dev/${dev}ro" 2>/dev/null | cut -d' ' -f1 || true)
	got=$(stat -c%s "$f")
	if [ "$got" -eq "$((16#$size))" ] && [ "$local_sum" = "$remote_sum" ]; then echo "OK $local_sum"
	else echo "MISMATCH size=$got local=$local_sum remote=$remote_sum (see $f.err)"; fail=1; fi
	[ -s "$f.err" ] || rm -f "$f.err"
done < <(grep '^mtd' "$OUT/router-info.txt")
(cd "$OUT" && sha256sum ./*.bin > SHA256SUMS)
echo "backup in $OUT ($( [ $fail = 0 ] && echo complete || echo 'INCOMPLETE - see MISMATCH lines'))"
exit $fail
