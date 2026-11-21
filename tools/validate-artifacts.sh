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
FAILS=0
r() { printf '%-4s %s\n' "$1" "$2" | tee -a "$OUT"; [ "$1" = FAIL ] && FAILS=$((FAILS+1)); return 0; }
: >"$OUT"
echo "# Artifact validation ($VARIANT) $(date -u +%FT%TZ)" | tee -a "$OUT"

ITB=$(ls "$BIN"/*"$DEV"-initramfs-uImage.itb 2>/dev/null | head -1 || true)
[ -f "$ITB" ] && r PASS "initramfs FIT present: $(basename "$ITB") ($(stat -c%s "$ITB") bytes)" || { r FAIL "initramfs FIT missing"; exit 1; }

# Check the bytes U-Boot will select (including hashes and kernel extent).
if python3 -I "$PROJ/tools/fit-verify.py" "$ITB" --config config@mp02.1 --ram-boot-dtb "$WORK/board.dtb" --ram-boot-kernel "$WORK/Image" >"$WORK/fit.txt"; then
    r PASS "FIT hashes, default config, kernel addresses and decompressed extent"
    dtc -q -I dtb -O dts -o "$WORK/board.dts" "$WORK/board.dtb"
    if ! python3 -I "$PROJ/tests/static/check_dtb.py" "$WORK/board.dts" >"$WORK/dtb-checks.txt"; then
        r FAIL "selected DTB failed validation"
    fi
    while read -r st rest; do r "$st" "dtb: $rest"; done <"$WORK/dtb-checks.txt"
else
    r FAIL "FIT validation failed (see $WORK/fit.txt)"
fi

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
			if python3 -I "$PROJ/tools/bdf/board2.py" scoped "$f/board-2.bin" --eu --stock-board-id "$sid" && [ ! -e "$f/board.bin" ]; then
				r PASS "$fw exact AX23 variant keys and no board.bin fallback"
			else r FAIL "$fw unexpected board data or unscoped fallback"; fi
		elif [ "$VARIANT" = dev ]; then
			r FAIL "$fw dev board-2.bin missing"
		else
			r INFO "$fw board-2.bin ABSENT (no locally supplied board data) -> Wi-Fi BLOCKED, same -12 as baseline"
		fi
	done
	ls "$ROOT"/lib/firmware/ath11k/IPQ5018/hw1.0/q6_fw.mdt >/dev/null 2>&1 && r PASS "Q6 firmware present" || r FAIL "Q6 firmware missing"
	if [ "$VARIANT" = dev ]; then
        if python3 -I "$PROJ/tools/check-initramfs.py" "$WORK/Image" "$ROOT" >"$WORK/embedded-files.txt"; then
            r PASS "selected FIT kernel contains both staged radio modules, EU board data and startup hooks"
        else r FAIL "selected FIT kernel embedded initramfs failed verification"; fi
        grep -q 'target=/lib/firmware/$FIRMWARE' "$ROOT/lib/functions/caldata.sh" && r PASS "caldata regdomain fix present" || r FAIL "caldata regdomain fix missing"
		grep -q "platform_upgrade_blocked" "$ROOT/lib/upgrade/platform.sh" && r PASS "sysupgrade interlock present" || r FAIL "sysupgrade interlock missing"
	else
		grep -q "platform_upgrade_blocked" "$ROOT/lib/upgrade/platform.sh" && r INFO "interlock present" || r INFO "baseline: no sysupgrade interlock (falls through to default_do_upgrade)"
	fi
	du -sk "$ROOT" | awk '{print "INFO rootfs size " $1 " KiB"}' | tee -a "$OUT"
else r FAIL "rootfs staging dir not found"; fi

if [ "$VARIANT" = dev ]; then
    configs=("$OWRT"/build_dir/target-*/linux-qualcommax_ipq50xx/linux-[0-9]*/.config)
    if [ "${#configs[@]}" -eq 1 ] && [ -r "${configs[0]}" ]; then
        for key in MTD_OF_PARTS QCOM_Q6V5_MPD; do
            grep -qx "CONFIG_$key=y" "${configs[0]}" && r PASS "kernel enables $key" || r FAIL "missing $key"
        done
        for key in MTD_PARTITIONED_MASTER MTD_CMDLINE_PARTS DEVMEM SPI_SPIDEV; do
            if grep -Eq "^CONFIG_$key=[ym]$" "${configs[0]}"; then
                r FAIL "kernel exposes $key"
            else r PASS "kernel disables $key"; fi
        done
    else r FAIL "ambiguous or missing kernel configuration"; fi
fi

# --- ath11k module built with the low-memory patch (dev)
if [ "$VARIANT" = dev ]; then
	# OpenWrt builds ath11k from backports (mac80211-*/backports-*), not from
	# the kernel tree's own copy.
	K=$(ls "$OWRT"/build_dir/target-*/linux-qualcommax_ipq50xx/mac80211-*/backports-*/drivers/net/wireless/ath/ath11k/dp_rx.c 2>/dev/null | head -1 || true)
	O="${K%.c}.o"
	if [ -n "$K" ] && grep -q "ath11k_dp_rx_ring_size" "$K" && [ -f "$O" ] && [ "$O" -nt "$K" ]; then
		r PASS "ath11k built from patched backports source (FW-mode-2 RX ring sizing)"
	else r FAIL "ath11k low-memory patch not in built backports source/object"; fi
    if [ -n "$K" ] && python3 -I "$PROJ/tests/unit/check_ath11k_cleanup.py" "${K%/dp_rx.c}/dp.c"; then
        r PASS "host allocation regression on prepared ath11k driver source"
    else r FAIL "ath11k partial allocation cleanup regression"; fi
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
