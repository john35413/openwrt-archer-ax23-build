#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Low-memory matrix of the digital twin: the full twin test set at several
# router RAM sizes, then an optional soak. DIGITAL TWIN ONLY: there is no
# ath11k/Qualcomm firmware here, so the AX23's driver/firmware memory is not
# exercised; the matrix shows how the OpenWrt userspace + kernel stack behaves
# as RAM shrinks (see reports/real-memory-budget.md for the mapping).
#   tests/twin/memory-matrix.sh [RAM...]            default: 128M 160M 176M 200M
#   SOAK_RAM=176M SOAK_MIN=30 tests/twin/memory-matrix.sh
set -uo pipefail
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
M="$PROJ/logs/twin/matrix"; mkdir -p "$M"
S="$M/summary.tsv"; [ -f "$S" ] || printf 'run\tram\tload_s\tpass\tfail\tMemTotal_kB\tS01_MemAvailable_kB\tmin_MemAvailable_kB\tslope_kB_per_h\toom_lines\n' >"$S"
one() {	# NAME RAM LOAD_SEC
	local o="$M/$1"; rm -rf "$o"; mkdir -p "$o"
	TWIN_OUT="$o" TWIN_RAM="$2" TWIN_LOAD_SEC="$3" "$PROJ/tests/twin/run-twin.sh" >"$o/run.txt" 2>&1
	local p f mt ma s7
	p=$(grep -c "	PASS	" "$o/results.tsv" 2>/dev/null); f=$(grep -c "	FAIL	" "$o/results.tsv" 2>/dev/null)
	mt=$(awk '/MemTotal/{print $2}' "$o/router-mem-after.txt" 2>/dev/null)
	ma=$(awk -F'\t' '$1=="S01"{print $4}' "$o/results.tsv" | tr -dc 0-9)
	s7=$(awk -F'\t' '$1=="S07"{print $4}' "$o/results.tsv")
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${p:-0}" "${f:-?}" "${mt:-?}" "${ma:-?}" \
		"$(echo "$s7" | sed -n 's/.*min \([0-9]*\) kB.*/\1/p')" "$(echo "$s7" | sed -n 's/.*slope \([-0-9.na/]*\) kB.*/\1/p')" \
		"$(echo "$s7" | sed -n 's/.*lines \([0-9]*\).*/\1/p')" | tee -a "$S"
	rm -f "$o/.helper-entry.sh"
}
if [ $# -gt 0 ]; then RAMS="$*"; else RAMS="128M 160M 176M 200M"; fi
for r in $RAMS; do one "ram-$r" "$r" 180; done
[ -n "${SOAK_MIN:-}" ] && one "soak-${SOAK_RAM:-176M}-${SOAK_MIN}min" "${SOAK_RAM:-176M}" $((SOAK_MIN * 60))
