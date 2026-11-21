#!/usr/bin/env bash
# Runs run-nand-lab.sh inside a throw-away QEMU VM (virtme-ng, Ubuntu kernel
# with nandsim/ubi/ubifs modules). Simulated NAND only; host root is shared
# read-only and only logs/nand is writable from the VM.
#   ITB=artifacts/ram-only/dev/<itb> tests/nand/vm-run.sh   (optional payload)
set -euo pipefail
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
KERNEL="${VM_KERNEL:-$(ls /boot/vmlinuz-*-generic 2>/dev/null | sort -V | tail -1)}"
OUT="$PROJ/logs/nand"; mkdir -p "$OUT"; rm -f "$OUT/nand-results.tsv" "$OUT/vm.done"
[ -r "$KERNEL" ] || { echo "BLOCKED: no VM kernel"; exit 77; }
command -v vng >/dev/null || { echo "BLOCKED: virtme-ng not installed"; exit 77; }
ITB_ABS=""; [ -n "${ITB:-}" ] && ITB_ABS="$(readlink -f "$ITB")"
cat >"$OUT/.vm-entry.sh" <<EOS
#!/bin/bash
ITB="$ITB_ABS" "$PROJ/tests/nand/run-nand-lab.sh" "$OUT" > "$OUT/console.txt" 2>&1
echo \$? > "$OUT/vm.done"
EOS
chmod +x "$OUT/.vm-entry.sh"
(cd /tmp && timeout 1200 vng --run "$KERNEL" --disable-microvm -m 1536M --cpus 2 \
	--rwdir="$OUT" --exec "$OUT/.vm-entry.sh" >"$OUT/vm-boot.log" 2>&1) || true
cat "$OUT/console.txt" 2>/dev/null
[ -f "$OUT/vm.done" ] || { echo "VM did not complete (see logs/nand/vm-boot.log)"; exit 1; }
exit "$(cat "$OUT/vm.done")"
