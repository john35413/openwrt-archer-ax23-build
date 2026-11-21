#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Full-system "digital twin" run of the AX23 v2 software.
#
#   router VM  : QEMU aarch64 (cortex-a53, 2 cores, 200 MiB ~ AX23 usable RAM),
#                the twin OpenWrt image (same SHA/feeds/patches as the AX23 dev
#                image), 5 virtio NICs renamed wan/lan1..lan4, 4 mac80211_hwsim
#                radios (radio0 = "2.4 GHz IPQ5018", radio1 = "5 GHz QCN6122",
#                phy2/phy3 = test stations).
#   helper VM  : x86 (virtme-ng, host userspace) holding the ISP, an Internet
#                host and three wired PCs on lan1..lan3, connected through QEMU
#                socket "cables".
#
# WHAT THIS IS NOT: it does not emulate the IPQ5018 SoC, the ath11k driver and
# Qualcomm firmware, QMI/remoteproc, board data/calibration, RF, the RTL8367S-VB
# switch (br-lan is a software bridge here), the 2.5G trunk, NAND or U-Boot.
# A PASS shows that the OpenWrt configuration and the software stack above the
# drivers work together. It is not evidence that the physical router works.
set -euo pipefail
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$PROJ/logs/twin"; mkdir -p "$OUT"; rm -f "$OUT"/results.tsv "$OUT"/helper.done "$OUT"/router-console.log
IMG=$(ls "$PROJ"/build/twin/openwrt/bin/targets/armsr/armv8/*generic-initramfs-kernel.bin 2>/dev/null | head -1)
[ -f "$IMG" ] || { echo "BLOCKED: twin image missing (./tools/build-twin.sh)"; exit 77; }
KERNEL="${VM_KERNEL:-$(ls /boot/vmlinuz-*-generic 2>/dev/null | sort -V | tail -1)}"
[ -r "$KERNEL" ] && command -v vng >/dev/null || { echo "BLOCKED: virtme-ng/VM kernel missing"; exit 77; }
BASE=${TWIN_PORT:-21000}
RMEM=${TWIN_RAM:-200M}

net=()
for i in 0 1 2 3 4; do
	net+=(-netdev "socket,id=n$i,listen=127.0.0.1:$((BASE+i))" -device "virtio-net-pci,netdev=n$i,mac=52:54:00:23:00:0$i")
done
qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 2 -m "$RMEM" -display none -monitor none \
	-kernel "$IMG" -append "console=ttyAMA0" -device virtio-rng-pci \
	-chardev "file,id=con,path=$OUT/router-console.log" -serial chardev:con \
	"${net[@]}" &
RPID=$!
trap 'kill $RPID 2>/dev/null || true' EXIT
sleep 2
kill -0 $RPID || { echo "router VM failed to start"; exit 1; }

hopts=""
for i in 0 1 2 3; do	# wan, lan1, lan2, lan3 (lan4 left unplugged)
	hopts+=" -netdev socket,id=h$i,connect=127.0.0.1:$((BASE+i)) -device virtio-net-pci,netdev=h$i,mac=52:54:00:aa:00:0$i"
done
cat >"$OUT/.helper-entry.sh" <<EOS
#!/bin/bash
"${TWIN_TESTS:-$PROJ/tests/twin/twin-tests.sh}" "$OUT" "$PROJ/build/twin-keys/id_ed25519" > "$OUT/helper-console.txt" 2>&1
echo \$? > "$OUT/helper.done"
EOS
chmod +x "$OUT/.helper-entry.sh"
(cd /tmp && timeout 5400 vng --run "$KERNEL" --disable-microvm -m 1536M --cpus 2 \
	--rwdir="$OUT" --qemu-opts="$hopts" --exec "$OUT/.helper-entry.sh" >"$OUT/helper-boot.log" 2>&1) || true
cat "$OUT/helper-console.txt" 2>/dev/null | grep -E "^[A-Z][0-9]+ |SUMMARY" || true
[ -f "$OUT/helper.done" ] || { echo "helper VM did not complete"; exit 1; }
exit "$(cat "$OUT/helper.done")"
