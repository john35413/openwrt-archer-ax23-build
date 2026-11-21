#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Static checks that need no hardware. Prints PASS/FAIL/SKIP lines.
set -u
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
rc=0; p() { echo "PASS $*"; }; f() { echo "FAIL $*"; rc=1; }; s() { echo "SKIP $*"; }
cd "$PROJ" || exit 1
# 1. shell syntax + shellcheck (warnings and above) on project scripts
for x in $(git ls-files '*.sh' 2>/dev/null || find tools tests -name '*.sh'); do
	sh_=$(head -1 "$x" | grep -q bash && echo bash || echo sh)
	$sh_ -n "$x" 2>/dev/null && p "syntax $x" || f "syntax $x"
done
if command -v shellcheck >/dev/null; then
	git ls-files -z '*.sh' | xargs -0 shellcheck -S warning -e SC2015,SC1090,SC1091 >logs/shellcheck.txt 2>&1 \
		&& p "shellcheck (warning+) on all project scripts" || f "shellcheck: see logs/shellcheck.txt"
else s "shellcheck not installed"; fi
# 2. python byte-compile
for x in $(git ls-files '*.py'); do python3 -m py_compile "$x" && p "py_compile $x" || f "py_compile $x"; done
# 3. dev patch series applies on the staged baseline (fresh worktree)
B="$PROJ/build/baseline/openwrt"
if [ -d "$B/.git" ] || [ -f "$B/.git" ]; then
	T=$(mktemp -d); git -C "$B" worktree add -q --detach "$T/w" HEAD 2>/dev/null
	if [ -d "$T/w" ]; then
		ok=1; while read -r q; do case "$q" in ''|'#'*) continue;; esac
			git -C "$T/w" -c user.name=t -c user.email=t@t am -q --3way "$PROJ/patches/openwrt/$q" || { ok=0; f "series: $q does not apply"; git -C "$T/w" am --abort; break; }
		done < patches/openwrt/series
		[ $ok = 1 ] && p "dev series ($(grep -c . patches/openwrt/series) patches) applies cleanly on staged baseline"
		# 4. the changed shell scripts in the OpenWrt tree parse as POSIX sh
		for x in target/linux/qualcommax/ipq50xx/base-files/lib/upgrade/platform.sh \
			 target/linux/qualcommax/ipq50xx/base-files/etc/board.d/02_network \
			 target/linux/qualcommax/ipq50xx/base-files/etc/board.d/01_leds \
			 target/linux/qualcommax/ipq50xx/base-files/etc/hotplug.d/firmware/11-ath11k-caldata \
			 target/linux/qualcommax/ipq50xx/base-files/lib/preinit/09_mount_tp_data \
			 package/base-files/files/lib/functions/caldata.sh; do
			sh -n "$T/w/$x" && p "sh -n $x" || f "sh -n $x"
		done
		# 5. no patch leftovers in the tree the image is built from
		! find "$T/w/target/linux/qualcommax" "$T/w/package/base-files" \( -name '*.orig' -o -name '*.rej' \) | grep -q . \
			&& p "no .orig/.rej leftovers" || f ".orig/.rej leftovers present"
		git -C "$B" worktree remove --force "$T/w"
	fi
	rm -rf "$T"
else s "baseline tree not staged yet (run tools/build-dev.sh --variant baseline --stage-only)"; fi
# 6. DTB checks on whatever DTBs have been built
for v in baseline dev; do
	d=$(ls "$PROJ"/build/$v/openwrt/build_dir/target-*/linux-qualcommax_ipq50xx/linux-*/arch/arm64/boot/dts/qcom/ipq5018-archer-ax23-v2.dtb 2>/dev/null | head -1)
	[ -n "$d" ] || d=$(ls "$PROJ"/build/$v/openwrt/build_dir/target-*/linux-qualcommax_ipq50xx/image-ipq5018-archer-ax23-v2.dtb 2>/dev/null | head -1)
	if [ -n "$d" ]; then
		dtc -q -I dtb -O dts -o "$PROJ/logs/dtb-$v.dts" "$d"
		python3 -I tests/static/check_dtb.py "$PROJ/logs/dtb-$v.dts" >"$PROJ/logs/dtb-checks-$v.txt" \
			&& p "DTB static checks ($v): $(grep -c ^PASS "$PROJ/logs/dtb-checks-$v.txt") checks" \
			|| f "DTB static checks ($v): $(grep ^FAIL "$PROJ/logs/dtb-checks-$v.txt" | tr '\n' ';')"
	else s "no $v DTB built yet"; fi
done
exit $rc
