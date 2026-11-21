#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Offline test of tools/bdf/extract-oem-bdf.sh on a SYNTHETIC UBI image that
# mimics the stock slot layout (kernel + ubi_rootfs squashfs with per-region
# WIFI_FW copies). Random bytes stand in for board data.
set -u
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
for t in mksquashfs ubinize ubireader_extract_images unsquashfs; do command -v $t >/dev/null || { echo "SKIP $t missing"; exit 77; }; done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
rc=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; rc=1; }
for r in CA/default EU/default; do
	d="$T/root/$r/lib/firmware/IPQ5018/WIFI_FW"; mkdir -p "$d/qcn6122"
	head -c 131072 /dev/urandom >"$d/bdwlan.b24"; head -c 131072 /dev/urandom >"$d/qcn6122/bdwlan.b60"
done
mksquashfs "$T/root" "$T/rootfs.sqfs" -comp xz -quiet -noappend >/dev/null
head -c 2000000 /dev/urandom >"$T/kernel.bin"
cat >"$T/ubi.ini" <<EOI
[kernel]
mode=ubi
image=$T/kernel.bin
vol_id=0
vol_type=dynamic
vol_name=kernel
[ubi_rootfs]
mode=ubi
image=$T/rootfs.sqfs
vol_id=1
vol_type=dynamic
vol_name=ubi_rootfs
EOI
ubinize -o "$T/slot.ubi" -p 128KiB -m 2048 -s 2048 "$T/ubi.ini" >/dev/null 2>&1 || { echo "SKIP ubinize failed"; exit 77; }
X="$PROJ/tools/bdf/extract-oem-bdf.sh"
"$X" "$T/slot.ubi" --out "$T/out1" >"$T/log1" 2>&1 && bad "ambiguous regions must be refused" || \
	{ grep -q "multiple DIFFERENT" "$T/log1" && ok "refuses to guess between CA and EU copies" || bad "unexpected error: $(tail -2 "$T/log1")"; }
"$X" "$T/slot.ubi" --region EU/default --out "$T/out2" >"$T/log2" 2>&1 && ok "extracts with --region EU/default" || bad "extract failed: $(tail -3 "$T/log2")"
for f in ipq5018:EU/default/lib/firmware/IPQ5018/WIFI_FW/bdwlan.b24 qcn6122:EU/default/lib/firmware/IPQ5018/WIFI_FW/qcn6122/bdwlan.b60; do
	k=${f%%:*}; src="$T/root/${f#*:}"
	python3 -I "$PROJ/tools/bdf/board2.py" lookup "$T/out2/board-tplink_archer-ax23-v2.$k" --chip-id 0 --board-id 255 \
		--variant TP-Link-Archer-AX23-v2 >"$T/l" && grep -q "$(sha256sum "$src" | cut -d' ' -f1)" "$T/l" \
		&& ok "$k board-2.bin carries the EU source file under the AX23 v2 name" || bad "$k content/name mismatch"
	python3 -I "$PROJ/tools/bdf/board2.py" robust "$T/out2/board-tplink_archer-ax23-v2.$k" \
		--stock-board-id "$([ "$k" = ipq5018 ] && echo 36 || echo 96)" | tail -n1 | grep -q "ROBUST$" \
		&& ok "$k board-2.bin resolves for any OTP board id" || bad "$k resolves only for some OTP board ids"
done
exit $rc
