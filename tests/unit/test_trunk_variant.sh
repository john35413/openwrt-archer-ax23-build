#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# The 1G SGMII trunk diagnostic variant stays outside the default series,
# applies to the prepared tree, compiles with the build's own cpp/dtc flow
# (control: the unmodified DTS reproduces the shipped DTB byte for byte) and
# changes exactly phy-mode and fixed-link speed on both trunk ends.
set -u
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
OWRT="$PROJ/build/dev/openwrt"
VAR="$PROJ/patches/variants/trunk-1g-sgmii.patch"
DTS=target/linux/qualcommax/dts/ipq5018-archer-ax23-v2.dts
K=$(ls -d "$OWRT"/build_dir/target-*/linux-qualcommax_ipq50xx/linux-[0-9]* 2>/dev/null | head -1)
REF=$(ls "$OWRT"/build_dir/target-*/linux-qualcommax_ipq50xx/image-ipq5018-archer-ax23-v2.dtb 2>/dev/null | head -1)
[ -n "$K" ] && [ -n "$REF" ] && [ -f "$OWRT/$DTS" ] || { echo "SKIP no prepared dev tree (run tools/build-dev.sh)"; exit 77; }
fail=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
grep -q "trunk-1g-sgmii" "$PROJ/patches/openwrt/series" && bad "variant listed in the default series" || ok "variant is not in the default series"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/a/$(dirname $DTS)"; cp "$OWRT/$DTS" "$W/a/$DTS"; cp -r "$W/a" "$W/b"
patch -s -p1 -d "$W/b" <"$VAR" && ok "variant applies to the prepared DTS" || bad "variant does not apply"
compile() {	# compile SRC OUT
	cpp -nostdinc -I"$OWRT/target/linux/qualcommax/dts" -I"$K/arch/arm64/boot/dts" \
		-I"$K/arch/arm64/boot/dts/qcom" -I"$K/include" -I"$K/scripts/dtc/include-prefixes" \
		-undef -D__DTS__ -x assembler-with-cpp -o "$2.pre" "$1" 2>/dev/null &&
		"$K/scripts/dtc/dtc" -q -I dts -O dtb -o "$2" "$2.pre" 2>/dev/null
}
compile "$W/a/$DTS" "$W/a.dtb" && cmp -s "$W/a.dtb" "$REF" && ok "control DTS reproduces the shipped DTB" || bad "control does not reproduce the shipped DTB"
compile "$W/b/$DTS" "$W/b.dtb" && ok "variant DTS compiles" || bad "variant DTS does not compile"
"$K/scripts/dtc/dtc" -q -I dtb -O dts "$W/a.dtb" >"$W/a.txt"; "$K/scripts/dtc/dtc" -q -I dtb -O dts "$W/b.dtb" >"$W/b.txt" 2>/dev/null
ch=$(diff "$W/a.txt" "$W/b.txt" | grep -c '^>')
want=$(diff "$W/a.txt" "$W/b.txt" | grep '^>' | grep -cE 'phy-mode = "sgmii"|speed = <0x3e8>')
[ "$ch" = 4 ] && [ "$want" = 4 ] && ok "only phy-mode and speed change on both trunk ends" || bad "unexpected DTB changes ($ch lines, $want expected)"
exit $fail
