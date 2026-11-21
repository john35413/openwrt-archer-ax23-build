#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Produce the AX23 v2 Wi-Fi board data (board-2.bin for IPQ5018 and QCN6122)
# from TP-Link's OFFICIAL firmware for this model, without touching a router.
#
#   board-data-from-tplink-firmware.sh [--region EU] [--firmware FILE.bin|ZIP]
#
# Default: downloads Archer AX23(EU) V2 1.2.1 Build 20261026 from TP-Link's
# download server, verifies TP-Link's RSA signature (public key from TP-Link's
# GPL source), unpacks it, and selects <region>/00000001 exactly as the stock
# preinit (/lib/preinit/91_init_for_tp_qca) does for that region.
#
# The output is proprietary TP-Link/Qualcomm board data for YOUR model. It is
# written to board-data/ (git-ignored). Do not commit or redistribute it.
# Per-unit RF calibration is NOT taken from here: it is read from the unit's
# own 0:ART partition at runtime by 11-ath11k-caldata.
set -euo pipefail
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
REGION=EU; FW=""
URL='https://static.tp-link.com/upload/firmware/2026/202611/20261113/Archer%20AX23%20_V2_1.2.1%20Build%2020261026.zip'
ZIP_SHA=fbe8fdebbaf2c46b   # prefix of the sha256 of the zip seen on 2026-11-21
while [ $# -gt 0 ]; do case "$1" in
	--region) REGION="$2"; shift 2 ;;
	--firmware) FW="$2"; shift 2 ;;
	*) echo "bad arg $1"; exit 2 ;;
esac; done
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
if [ -z "$FW" ]; then
	echo "downloading official firmware"; curl -fsS -o "$W/fw.zip" "$URL"
	sha256sum "$W/fw.zip" | grep -q "^$ZIP_SHA" || echo "NOTE: zip checksum differs from the one recorded (new upload?); signature check below still applies"
	FW="$W/fw.zip"
fi
case "$FW" in *.zip) mkdir "$W/z"; unzip -q -o "$FW" -d "$W/z"; FW=$(ls "$W"/z/*.bin | head -1) ;; esac
python3 -I "$PROJ/tools/bdf/tplink-fw-unpack.py" "$FW" "$W/fw.ubi"
"$PROJ/tools/bdf/extract-oem-bdf.sh" "$W/fw.ubi" --region "$REGION/00000001" --out "$PROJ/board-data"
echo "firmware=$(basename "$FW") region=$REGION" >> "$PROJ/board-data/PROVENANCE.txt"
