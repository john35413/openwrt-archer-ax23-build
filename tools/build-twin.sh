#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Builds the AX23 v2 digital twin: the dev tree (same OpenWrt SHA, feeds, AX23
# staging and dev patch series) built for armsr/armv8 so it boots in QEMU,
# with twin/files overlaid. Usage: ./tools/build-twin.sh [--jobs N]
set -Eeuo pipefail
PROJ="$(cd "$(dirname "$0")/.." && pwd)"; . "$PROJ/configs/sources.lock"
JOBS="${2:-$(nproc)}"; DEV="$PROJ/build/dev/openwrt"; T="$PROJ/build/twin/openwrt"
LOG="$PROJ/logs/twin"; mkdir -p "$LOG"
[ "$(id -u)" = 0 ] && export FORCE_UNSAFE_CONFIGURE=1
[ -d "$DEV/.git" ] || [ -f "$DEV/.git" ] || { echo "build the dev variant first"; exit 1; }
HEAD=$(git -C "$DEV" rev-parse HEAD)
if [ ! -e "$T/.git" ]; then
	git -C "$PROJ/upstream/openwrt" worktree add --detach "$T" "$HEAD"
	ln -s "$PROJ/build/dl" "$T/dl"
fi
# No host-tool seeding: build_dir/host contains absolute paths of the tree it
# was configured in (e.g. meson install prefixes), so copying it between trees
# is unsafe. The twin builds its own host tools.
git -C "$T" merge-base --is-ancestor "$OPENWRT_SHA" HEAD
cp "$DEV/feeds.conf" "$T/feeds.conf"
(cd "$T" && ./scripts/feeds update -a && ./scripts/feeds install -a) >"$LOG/feeds.log" 2>&1
rm -rf "$T/files"; cp -a "$PROJ/twin/files" "$T/files"
# test-only SSH key for the twin harness (generated locally, never committed)
mkdir -p "$PROJ/build/twin-keys" "$T/files/etc/dropbear"
[ -f "$PROJ/build/twin-keys/id_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C ax23-twin-test -f "$PROJ/build/twin-keys/id_ed25519"
install -m 600 "$PROJ/build/twin-keys/id_ed25519.pub" "$T/files/etc/dropbear/authorized_keys"
cp "$PROJ/twin/twin.diffconfig" "$T/.config"
(cd "$T" && make defconfig) >"$LOG/config.log" 2>&1
grep -q "^CONFIG_PACKAGE_kmod-mac80211-hwsim=y" "$T/.config"; grep -q "^CONFIG_PACKAGE_wpad-mbedtls=y" "$T/.config"
echo "twin tree $(git -C "$T" log --oneline -1); building with -j$JOBS (log: logs/twin/build.log)"
(cd "$T" && make -j"$JOBS" world) >"$LOG/build.log" 2>&1 || { tail -30 "$LOG/build.log"; (cd "$T" && make -j1 V=s world) >"$LOG/build-verbose.log" 2>&1; exit 1; }
ls -la "$T"/bin/targets/armsr/armv8/ | tee "$LOG/outputs.txt"
(cd "$T/bin/targets/armsr/armv8" && sha256sum *initramfs* *.manifest) > "$LOG/SHA256SUMS"
echo "twin build OK"
