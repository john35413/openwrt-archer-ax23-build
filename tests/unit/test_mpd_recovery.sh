#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Q6 MPD crash/recovery regression (host model; no router, no firmware).
# Runs the prepared kernel's qcom_q6v5_mpd.c, and the same file with kernel
# patch 0821 reversed, through tests/unit/check_mpd_recovery.py.
set -u
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
SRC=$(ls "$PROJ"/build/dev/openwrt/build_dir/target-*/linux-qualcommax_ipq50xx/linux-*/drivers/remoteproc/qcom_q6v5_mpd.c 2>/dev/null | head -1)
[ -n "$SRC" ] || { echo "SKIP no prepared dev kernel tree (run tools/build-dev.sh)"; exit 77; }
OUTER="$PROJ/patches/openwrt/0026-qualcommax-mpd-recover-user-PDs-with-the-root-PD.patch"
fail=0
python3 -I "$PROJ/tests/unit/check_mpd_recovery.py" "$SRC" || fail=1
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/drivers/remoteproc"; cp "$SRC" "$W/drivers/remoteproc/"
# the inner kernel patch is the '+' body of the outer patch's single new file
python3 -I - "$OUTER" "$W/0821.patch" <<'EOF'
import sys
lines = open(sys.argv[1]).read().split("\n")
start = next(i for i, l in enumerate(lines) if l.startswith("+++ b/target/")) + 2
body = []
for l in lines[start:]:
    if not l.startswith("+"):
        break
    body.append(l[1:])
open(sys.argv[2], "w").write("\n".join(body) + "\n")
EOF
if patch -s -R -p1 -d "$W" <"$W/0821.patch"; then
	echo "PASS kernel patch 0821 is present in the prepared source and reverses cleanly"
	python3 -I "$PROJ/tests/unit/check_mpd_recovery.py" "$W/drivers/remoteproc/qcom_q6v5_mpd.c" --expect-fail || fail=1
else
	echo "FAIL kernel patch 0821 does not reverse on the prepared source"; fail=1
fi
exit $fail
