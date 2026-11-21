#!/usr/bin/env bash
# Runs run-netns-tests.sh inside a throw-away QEMU VM (virtme-ng, stock
# Ubuntu kernel with bridge/8021q/nft/netem/cake), because the build host
# kernel lacks bridge/VLAN support. Host root is shared read-only; only
# logs/network is writable from the VM.
set -euo pipefail
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
KERNEL="${VM_KERNEL:-$(ls /boot/vmlinuz-*-generic 2>/dev/null | sort -V | tail -1)}"
OUT="$PROJ/logs/network"; mkdir -p "$OUT"; rm -f "$OUT/results.tsv" "$OUT/vm.done"
[ -r "$KERNEL" ] || { echo "BLOCKED: no VM kernel (install linux-image-virtual)"; exit 77; }
command -v vng >/dev/null || { echo "BLOCKED: virtme-ng not installed (pip install virtme-ng)"; exit 77; }
cat >"$OUT/.vm-entry.sh" <<EOS
#!/bin/bash
"$PROJ/tests/network/run-netns-tests.sh" --out "$OUT" $* > "$OUT/console.txt" 2>&1
echo \$? > "$OUT/vm.done"
EOS
chmod +x "$OUT/.vm-entry.sh"
(cd /tmp && timeout 1500 vng --run "$KERNEL" --disable-microvm -m 1536M --cpus 2 \
	--rwdir="$OUT" --exec "$OUT/.vm-entry.sh" >"$OUT/vm-boot.log" 2>&1) || true
cat "$OUT/console.txt" 2>/dev/null
[ -f "$OUT/vm.done" ] || { echo "VM did not complete (see logs/network/vm-boot.log)"; exit 1; }
exit "$(cat "$OUT/vm.done")"
