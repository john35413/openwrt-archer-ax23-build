#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# PC-side: turn a raw, read-only dump of the AX23 v2 stock firmware slot into
# the two board-2.bin files the ipq-wifi-tplink_archer-ax23-v2 package needs.
#
#   extract-oem-bdf.sh DUMP.bin [--region DIR] [--out board-data/]
#
# DUMP.bin: `cat /dev/mtdNro` of the slot that holds TP-Link firmware
#           (made with tests/hardware/dump-stock-slot-ro.sh on the router).
# --region: OEM rootfs keeps per-market copies (e.g. CA/default/...). The
#           script lists every candidate it finds and refuses to guess when
#           more than one distinct file exists; pass the directory that
#           matches your unit (an EU unit needs the EU copy if one exists).
#
# The output is proprietary TP-Link/Qualcomm data derived from YOUR device.
# Keep it local: board-data/ is git-ignored. Never commit or publish it.
set -euo pipefail
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
DUMP=""; REGION=""; OUT="$PROJ/board-data"
while [ $# -gt 0 ]; do case "$1" in
	--region) REGION="$2"; shift 2 ;;
	--out) OUT="$2"; shift 2 ;;
	-h|--help) sed -n '3,20p' "$0"; exit 0 ;;
	*) DUMP="$1"; shift ;;
esac; done
[ -f "$DUMP" ] || { echo "usage: $0 DUMP.bin [--region DIR] [--out DIR]"; exit 2; }
for t in ubireader_extract_images unsquashfs python3; do
	command -v $t >/dev/null || { echo "missing $t (pip install ubi_reader; apt install squashfs-tools)"; exit 2; }
done
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
NAME="bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=TP-Link-Archer-AX23-v2"

echo "[1/4] UBI volumes in $(basename "$DUMP")"
ubireader_extract_images -o "$W/ubi" "$DUMP" >/dev/null
find "$W/ubi" -type f -printf '      %f %s bytes\n'

echo "[2/4] unpacking squashfs volume(s)"
n=0
for v in $(find "$W/ubi" -type f); do
	if [ "$(head -c4 "$v")" = "hsqs" ]; then
		n=$((n+1)); unsquashfs -q -n -d "$W/fs$n" "$v" >/dev/null 2>&1 || true
	fi
done
[ $n -gt 0 ] || { echo "no squashfs volume found - is this the stock firmware slot?"; exit 1; }

echo "[3/4] candidate board files (128 KiB bdwlan.*)"
find "$W"/fs* \( -name 'bdwlan.b24' -o -name 'bdwlan.b60' -o -name 'bdwlan*.bin' -o -name 'bdwlan.b*' \) -type f \
	-printf '%s %P\n' | sort -k2 >"$W/cands"
[ -s "$W/cands" ] || { echo "no bdwlan files found"; exit 1; }
while read -r sz p; do printf '      %-60s %7s %s\n' "$p" "$sz" "$(sha256sum "$W/fs"*/"$p" 2>/dev/null | head -1 | cut -c1-16)"; done <"$W/cands"

pick() {	# pick <glob-suffix> -> path
	local pat="$1" lst
	lst=$(awk '{print $2}' "$W/cands" | grep -E "$pat" | { [ -n "$REGION" ] && grep "^$REGION/" || cat; })
	[ -n "$lst" ] || { echo "no file matching $pat${REGION:+ under $REGION}" >&2; return 1; }
	local uniq; uniq=$(for p in $lst; do sha256sum "$W"/fs*/"$p" | head -1 | cut -d' ' -f1; done | sort -u | wc -l)
	if [ "$uniq" -gt 1 ]; then
		echo "multiple DIFFERENT $pat candidates; re-run with --region <dir> (see list above)" >&2; return 1
	fi
	for p in $lst; do ls "$W"/fs*/"$p" | head -1; return 0; done
}
F2=$(pick '(^|/)bdwlan\.b24$' ) ; F5=$(pick 'qcn6122/bdwlan\.b60$|/bdwlan\.b60$')
for f in "$F2" "$F5"; do
	[ "$(stat -c%s "$f")" -eq 131072 ] || { echo "unexpected size for $f (want 131072)"; exit 1; }
done

echo "[4/4] packing board-2.bin files -> $OUT"
mkdir -p "$OUT"
python3 -I "$PROJ/tools/bdf/board2.py" pack "$OUT/board-tplink_archer-ax23-v2.ipq5018" "$NAME=$F2"
python3 -I "$PROJ/tools/bdf/board2.py" pack "$OUT/board-tplink_archer-ax23-v2.qcn6122" "$NAME=$F5"
{ echo "source_dump_sha256=$(sha256sum "$DUMP" | cut -d' ' -f1)"
  echo "ipq5018_src=${F2#$W/}"; echo "qcn6122_src=${F5#$W/}"
  sha256sum "$OUT"/board-tplink_archer-ax23-v2.* | sed "s#$OUT/##"; } | tee "$OUT/PROVENANCE.txt"
echo "done. Rebuild with: ./tools/build-dev.sh --variant dev"
