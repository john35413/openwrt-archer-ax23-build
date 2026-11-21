#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# ath11k DP ring allocation order regression (host model; no router).
# Runs the prepared backports dp.c, and the same file with ath11k patch 965
# reversed, through tests/unit/check_ath11k_ring_alloc.py.
set -u
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
SRC=$(ls "$PROJ"/build/dev/openwrt/build_dir/target-*/linux-qualcommax_ipq50xx/mac80211-*/backports-*/drivers/net/wireless/ath/ath11k/dp.c 2>/dev/null | head -1)
[ -n "$SRC" ] || { echo "SKIP no prepared dev backports tree (run tools/build-dev.sh)"; exit 77; }
OUTER="$PROJ/patches/openwrt/0027-mac80211-ath11k-request-exact-ring-sizes-from-the-DMA-allocator.patch"
fail=0
python3 -I "$PROJ/tests/unit/check_ath11k_ring_alloc.py" "$SRC" || fail=1
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/drivers/net/wireless/ath/ath11k"; cp "$SRC" "$W/drivers/net/wireless/ath/ath11k/"
python3 -I - "$OUTER" "$W/965.patch" <<'EOF'
import sys
lines = open(sys.argv[1]).read().split("\n")
start = next(i for i, l in enumerate(lines) if l.startswith("+++ b/package/")) + 2
body = []
for l in lines[start:]:
    if not l.startswith("+"):
        break
    body.append(l[1:])
open(sys.argv[2], "w").write("\n".join(body) + "\n")
EOF
if patch -s -R -p1 -d "$W" <"$W/965.patch"; then
	echo "PASS ath11k patch 965 is present in the prepared source and reverses cleanly"
	python3 -I "$PROJ/tests/unit/check_ath11k_ring_alloc.py" "$W/drivers/net/wireless/ath/ath11k/dp.c" --expect-fail || fail=1
else
	echo "FAIL ath11k patch 965 does not reverse on the prepared source"; fail=1
fi
exit $fail
