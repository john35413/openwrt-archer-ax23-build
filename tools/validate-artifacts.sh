#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# validate-artifacts.sh OPENWRT_TREE VARIANT
# Static validation of the AX23 v2 build outputs. Writes
# reports/artifacts-<variant>.txt and fails on any FAIL line.
set -Eeuo pipefail
OWRT="$1"; VARIANT="$2"
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$OWRT/bin/targets/qualcommax/ipq50xx"
DEV=tplink_archer-ax23-v2
OUT="$PROJ/reports/artifacts-$VARIANT.txt"
WORK="$PROJ/build/validate-$VARIANT"; rm -rf "$WORK"; mkdir -p "$WORK"
HOSTBIN="$OWRT/staging_dir/host/bin"
DUMPIMAGE="$HOSTBIN/dumpimage"; [ -x "$DUMPIMAGE" ] || DUMPIMAGE=$(command -v dumpimage || true)
[ -n "$DUMPIMAGE" ] || { echo "dumpimage missing (apt install u-boot-tools)"; exit 1; }
FAILS=0
r() { printf '%-4s %s\n' "$1" "$2" | tee -a "$OUT"; [ "$1" = FAIL ] && FAILS=$((FAILS+1)); return 0; }
: >"$OUT"
echo "# Artifact validation ($VARIANT) $(date -u +%FT%TZ)" | tee -a "$OUT"

ITB=$(ls "$BIN"/*"$DEV"-initramfs-uImage.itb 2>/dev/null | head -1)
[ -f "$ITB" ] && r PASS "initramfs FIT present: $(basename "$ITB") ($(stat -c%s "$ITB") bytes)" || { r FAIL "initramfs FIT missing"; exit 1; }

# --- FIT layout
"$DUMPIMAGE" -l "$ITB" >"$WORK/fit.txt" 2>&1 || true
grep -q "config@mp02.1" "$WORK/fit.txt" && r PASS "FIT has config@mp02.1 (stock U-Boot selects this)" || r FAIL "FIT lacks config@mp02.1"
grep -q "Load Address: 0x41000000" "$WORK/fit.txt" && r PASS "kernel load address 0x41000000" || r FAIL "unexpected kernel load address"

# U-Boot loads the FIT at 0x44000000 (stock tftpboot default, seen in UART
# logs) and decompresses the kernel to 0x41000000. The decompressed image
# (kernel + embedded initramfs) must end below 0x44000000 or it overwrites
# the FIT it is being decompressed from.
IMG=$(ls -d "$OWRT"/build_dir/target-*/linux-qualcommax_ipq50xx/Image-initramfs 2>/dev/null | head -1 || true)
[ -n "$IMG" ] || IMG=$(ls "$OWRT"/build_dir/target-*/linux-qualcommax_ipq50xx/linux-*/arch/arm64/boot/Image 2>/dev/null | head -1 || true)
if [ -n "$IMG" ]; then
	isz=$(stat -c%s "$IMG"); lim=$((0x44000000 - 0x41000000))
	[ "$isz" -lt "$lim" ] && r PASS "decompressed kernel $isz < $lim bytes (no overlap with FIT at 0x44000000)" \
		|| r FAIL "decompressed kernel $isz overlaps FIT load address"
else r FAIL "cannot locate uncompressed kernel image for size check"; fi
fsz=$(stat -c%s "$ITB"); [ "$fsz" -lt $((0x4b000000 - 0x44000000)) ] && r PASS "FIT ends below Q6 reserved region 0x4b000000" || r FAIL "FIT reaches Q6 region"

# --- embedded DTB
n=$(awk '/Image [0-9]+ \(fdt/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$WORK/fit.txt")
if [ -n "$n" ] && "$DUMPIMAGE" -T flat_dt -p "$n" -o "$WORK/board.dtb" "$ITB" >/dev/null 2>&1; then
	dtc -q -I dtb -O dts -o "$WORK/board.dts" "$WORK/board.dtb"
	r PASS "extracted DTB from FIT image $n"
	python3 -I "$PROJ/tests/static/check_dtb.py" "$WORK/board.dts" >"$WORK/dtb-checks.txt" || true
	while read -r st rest; do r "$st" "dtb: $rest"; done <"$WORK/dtb-checks.txt"
else r FAIL "could not extract DTB from FIT"; fi

# --- root filesystem contents (initramfs is built from this tree)
ROOT=$(ls -d "$OWRT"/build_dir/target-*/root-qualcommax 2>/dev/null | head -1 || true)
if [ -d "$ROOT" ]; then
	! find "$ROOT/lib/preinit" -name '*.orig' -o -name '*.rej' -o -name '*~' | grep -q . \
		&& r PASS "no patch backup files in /lib/preinit" || r FAIL "patch backup files in /lib/preinit (would override preinit functions)"
	grep -q "tplink,archer-ax23-v2" "$ROOT/lib/preinit/09_mount_tp_data" && r PASS "tp_data preinit handles AX23 v2" || r FAIL "tp_data preinit lacks AX23 v2"
	grep -q "tplink,archer-ax23-v2" "$ROOT/etc/board.d/02_network" && r PASS "02_network handles AX23 v2" || r FAIL "02_network lacks AX23 v2"
	for fw in IPQ5018 QCN6122; do
		f="$ROOT/lib/firmware/ath11k/$fw/hw1.0"
		if [ -f "$f/board-2.bin" ]; then
			if python3 -I "$PROJ/tools/bdf/board2.py" lookup "$f/board-2.bin" --chip-id 0 --board-id 255 \
				--variant TP-Link-Archer-AX23-v2 | grep -q "^MATCH .*variant=TP-Link-Archer-AX23-v2$"; then
				r PASS "$fw board-2.bin contains the AX23 v2 variant"
			else r FAIL "$fw board-2.bin present but has no AX23 v2 entry"; fi
			sid=$([ $fw = IPQ5018 ] && echo 36 || echo 96)
			if python3 -I "$PROJ/tools/bdf/board2.py" scoped "$f/board-2.bin" --stock-board-id "$sid" && [ ! -e "$f/board.bin" ]; then
				r PASS "$fw exact AX23 variant keys and no board.bin fallback"
			else r FAIL "$fw unexpected board data or unscoped fallback"; fi
		else
			r INFO "$fw board-2.bin ABSENT (no locally supplied board data) -> Wi-Fi BLOCKED, same -12 as baseline"
		fi
	done
	ls "$ROOT"/lib/firmware/ath11k/IPQ5018/hw1.0/q6_fw.mdt >/dev/null 2>&1 && r PASS "Q6 firmware present" || r FAIL "Q6 firmware missing"
	if [ "$VARIANT" = dev ]; then
		grep -q 'target=/lib/firmware/$FIRMWARE' "$ROOT/lib/functions/caldata.sh" && r PASS "caldata regdomain fix present" || r FAIL "caldata regdomain fix missing"
		grep -q "platform_upgrade_blocked" "$ROOT/lib/upgrade/platform.sh" && r PASS "sysupgrade interlock present" || r FAIL "sysupgrade interlock missing"
	else
		grep -q "platform_upgrade_blocked" "$ROOT/lib/upgrade/platform.sh" && r INFO "interlock present" || r INFO "baseline: no sysupgrade interlock (falls through to default_do_upgrade)"
	fi
	du -sk "$ROOT" | awk '{print "INFO rootfs size " $1 " KiB"}' | tee -a "$OUT"
else r FAIL "rootfs staging dir not found"; fi

# --- ath11k module built with the low-memory patch (dev)
if [ "$VARIANT" = dev ]; then
	# OpenWrt builds ath11k from backports (mac80211-*/backports-*), not from
	# the kernel tree's own copy.
	K=$(ls "$OWRT"/build_dir/target-*/linux-qualcommax_ipq50xx/mac80211-*/backports-*/drivers/net/wireless/ath/ath11k/dp_rx.c 2>/dev/null | head -1 || true)
	O="${K%.c}.o"
	if [ -n "$K" ] && grep -q "ath11k_dp_rx_ring_size" "$K" && [ -f "$O" ] && [ "$O" -nt "$K" ]; then
		r PASS "ath11k built from patched backports source (FW-mode-2 RX ring sizing)"
	else r FAIL "ath11k low-memory patch not in built backports source/object"; fi
	# 961: TX completion ring, its FIFO, wrap macro and IDR range follow one runtime size
	D="${K%/dp_rx.c}"
	if [ -n "$K" ] && grep -q "DP_TX_COMP_RING_SIZE_LOWMEM" "$D/dp.h" &&
	   grep -q "ATH11K_TX_COMPL_NEXT(dp, x)" "$D/dp.h" &&
	   ! grep -q "DP_TX_IDR_SIZE" "$D/dp_tx.c" &&
	   [ "$D/dp.o" -nt "$D/dp.h" ] && [ "$D/dp_tx.o" -nt "$D/dp.h" ]; then
		r PASS "ath11k built with FW-mode-2 TX completion ring sizing (961)"
	else r FAIL "ath11k TX completion ring patch (961) not in built source/object"; fi
fi

echo "fails=$FAILS" | tee -a "$OUT"
[ "$FAILS" -eq 0 ]
