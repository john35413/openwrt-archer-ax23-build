#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Removes ONLY generated build output inside this project, after confirmation.
#   ./tools/clean-dev.sh [--all]    --all also removes upstream/ clones and dl/
# Never touches: patches/, configs/, tools/, tests/, reports/, board-data/,
# artifacts/ checksum files, or anything outside AX23_V2_OPENWRT/.
set -euo pipefail
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
T=("$PROJ/build/baseline" "$PROJ/build/dev" "$PROJ/build/patchwork" "$PROJ"/build/validate-*)
[ "${1:-}" = --all ] && T+=("$PROJ/build/dl" "$PROJ/upstream")
echo "Will delete:"; for t in "${T[@]}"; do [ -e "$t" ] && du -sh "$t"; done
read -r -p "Type DELETE to confirm: " a
[ "$a" = DELETE ] || { echo "aborted"; exit 1; }
for t in "${T[@]}"; do case "$t" in "$PROJ"/build/*|"$PROJ"/upstream) rm -rf -- "$t" ;; *) echo "refusing $t" ;; esac; done
git -C "$PROJ/upstream/openwrt" worktree prune 2>/dev/null || true
find "$PROJ/artifacts" -type f \( -name '*.itb' -o -name '*.ubi' -o -name '*.bin' \) -delete
echo done
