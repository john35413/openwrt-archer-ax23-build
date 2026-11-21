#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Reproducible build pipeline for the TP-Link Archer AX23 v2 (IPQ5018) OpenWrt
# development images.
#
#   ./tools/build-dev.sh [--variant baseline|dev] [--jobs N] [--resume]
#                        [--stage-only] [--no-feeds-luci]
#
# Variants
#   baseline  The Sply-Dev AX23 v2 tree at the pinned SHA, applied to the
#             pinned OpenWrt base exactly as its docs/BUILD.md intends
#             (with the one documented-procedure defect corrected: the 777-*
#             kernel patches are copied into pending-6.18 instead of being fed
#             to `patch -p1` at the OpenWrt root, where they cannot apply).
#   dev       baseline + this project's patch series (patches/openwrt/series).
#
# Stages (each stage logs to logs/<variant>/NN-<stage>.log and aborts on error):
#   01 deps  02 checkout  03 verify-sha  04 stage-ax23  05 apply-dev-patches
#   06 feeds 07 config    08 kernel+dtb  09 world       10 validate-artifacts
#   11 collect+checksums
#
# This script never flashes, never talks to a router, and never writes outside
# the AX23_V2_OPENWRT project directory.
set -Eeuo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANT=dev
JOBS="$(nproc)"
SEED_FROM=""
STAGE_ONLY=0
RESUME=0
while [ $# -gt 0 ]; do
	case "$1" in
	--variant) VARIANT="$2"; shift 2 ;;
	--jobs) JOBS="$2"; shift 2 ;;
	--seed-from) SEED_FROM="$2"; shift 2 ;;
	--stage-only) STAGE_ONLY=1; shift ;;
	--resume) RESUME=1; shift ;;	# skip checkout/staging/feeds/config (tree already prepared)
	-h|--help) sed -n '3,30p' "$0"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done
case "$VARIANT" in baseline|dev) ;; *) echo "bad variant $VARIANT" >&2; exit 2 ;; esac

# shellcheck source=../configs/sources.lock
. "$PROJ/configs/sources.lock"

UP="$PROJ/upstream"
BUILD="$PROJ/build/$VARIANT"
OWRT="$BUILD/openwrt"
LOGDIR="$PROJ/logs/$VARIANT"
DEVICE=tplink_archer-ax23-v2
BIN="$OWRT/bin/targets/qualcommax/ipq50xx"
mkdir -p "$LOGDIR" "$UP" "$BUILD"
# Containers/WSL sessions often run as root; GNU autoconf packages (tar,
# coreutils) refuse to configure as root unless this is set.
[ "$(id -u)" = 0 ] && export FORCE_UNSAFE_CONFIGURE=1

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { printf '[%s] [%s] %s\n' "$(ts)" "$VARIANT" "$*" | tee -a "$LOGDIR/00-pipeline.log"; }
die() { say "FATAL: $*"; exit 1; }
trap 'say "FAILED at line $LINENO (exit $?) - see $LOGDIR"; exit 1' ERR

run_stage() {	# run_stage NN name cmd...
	local nn="$1" name="$2"; shift 2
	local log="$LOGDIR/$nn-$name.log"
	local rc
	say "stage $nn $name -> ${log#$PROJ/}"
	# Run in a subshell *outside* any conditional so `set -e` stays active
	# inside the stage function (bash disables errexit under `if`/`||`).
	set +e; trap - ERR
	( set -Eeuo pipefail; "$@" ) >"$log" 2>&1
	rc=$?
	set -e; trap 'say "FAILED at line $LINENO (exit $?)"; exit 1' ERR
	if [ "$rc" -ne 0 ]; then
		tail -n 40 "$log" | sed 's/^/    | /'
		die "stage $nn $name failed (rc=$rc)"
	fi
}

# ---------------------------------------------------------------- 01 deps
s_deps() {
	local miss=0 t
	for t in git make gcc g++ gawk flex bison python3 rsync unzip wget file \
		 patch swig perl tar xz zstd bzip2 dtc; do
		if command -v "$t" >/dev/null; then echo "ok   $t $(command -v "$t")"
		else echo "MISS $t"; miss=1; fi
	done
	python3 -c 'import setuptools' && echo "ok   python3-setuptools" || miss=1
	echo "nproc=$(nproc) mem=$(free -m | awk '/Mem:/{print $2}')MB"
	local avail; avail=$(df -Pk "$PROJ" | awk 'NR==2{print int($4/1024/1024)}')
	echo "disk_avail=${avail}GB"
	local need=25; [ "$RESUME" = 1 ] && need=5	# incremental rebuild of a prepared tree
	[ "$avail" -ge "$need" ] || { echo "need >=${need}GB free"; miss=1; }
	return $miss
}

# ---------------------------------------------------------------- 02 checkout
clone_or_fetch() {	# url dir sha
	if [ ! -d "$2/.git" ]; then git clone --filter=blob:none "$1" "$2"; fi
	git -C "$2" cat-file -e "$3^{commit}" 2>/dev/null || git -C "$2" fetch origin
}
s_checkout() {
	clone_or_fetch "$OPENWRT_URL" "$UP/openwrt" "$OPENWRT_SHA"
	clone_or_fetch "$AX23_URL" "$UP/ax23" "$AX23_SHA"
	if [ -d "$OWRT/.git" ] || [ -f "$OWRT/.git" ]; then
		echo "build tree exists: resetting tracked files to $OPENWRT_SHA"
		git -C "$OWRT" checkout -f --detach "$OPENWRT_SHA"
		git -C "$OWRT" clean -fdq -e /dl -e /build_dir -e /staging_dir \
			-e /tmp -e /bin -e /feeds -e /package/feeds -e /.config \
			-e /logs
	else
		git -C "$UP/openwrt" worktree prune
		git -C "$UP/openwrt" worktree add --detach "$OWRT" "$OPENWRT_SHA"
	fi
	mkdir -p "$PROJ/build/dl"
	[ -e "$OWRT/dl" ] || ln -s "$PROJ/build/dl" "$OWRT/dl"
	git -C "$UP/ax23" checkout -q -f --detach "$AX23_SHA"
}

# ---------------------------------------------------------------- 03 verify
s_verify() {
	local o a
	o=$(git -C "$OWRT" rev-parse HEAD); a=$(git -C "$UP/ax23" rev-parse HEAD)
	echo "openwrt $o (want $OPENWRT_SHA)"; echo "ax23    $a (want $AX23_SHA)"
	[ "$o" = "$OPENWRT_SHA" ] && [ "$a" = "$AX23_SHA" ]
	git -C "$OWRT" status --porcelain --untracked-files=no | tee /dev/stderr | \
		{ ! grep -q .; } || { echo "build tree has local modifications before staging"; return 1; }
}

# ---------------------------------------------------------------- 04 stage
s_stage_ax23() {
	local A="$UP/ax23" p
	cp -v "$A/target/linux/qualcommax/dts/ipq5018-archer-ax23-v2.dts" \
		"$OWRT/target/linux/qualcommax/dts/"
	cp -v "$A"/target/linux/generic/pending-6.18/777-*.patch \
		"$OWRT/target/linux/generic/pending-6.18/"
	for p in 0001 0002 0004 0003 0005; do	# order from docs/BUILD.md
		echo "== applying $p"
		patch -d "$OWRT" -p1 --forward --no-backup-if-mismatch -r - \
			<"$(ls "$A"/patches/$p-*.patch)"
	done
	# Insert the device block before tplink_archer-ax55-v1 (BUILD.md step).
	python3 - "$A/target/linux/qualcommax/image/ipq50xx-ax23v2-snippet.mk" \
		"$OWRT/target/linux/qualcommax/image/ipq50xx.mk" <<'PY'
import sys, re
snip = open(sys.argv[1]).read()
snip = "".join(l for l in snip.splitlines(True) if not l.startswith("#"))
mk = open(sys.argv[2]).read()
if "Device/tplink_archer-ax23-v2" in mk:
    print("device block already present"); sys.exit(0)
anchor = "define Device/tplink_archer-ax55-v1"
assert anchor in mk, "anchor not found"
mk = mk.replace(anchor, snip.strip() + "\n\n" + anchor, 1)
open(sys.argv[2], "w").write(mk)
print("device block inserted")
PY
	# Guard from BUILD.md: no backup files may land in preinit.
	! find "$OWRT/target/linux/qualcommax" \( -name '*.orig' -o -name '*.rej' -o -name '*~' \) | grep .
	git -C "$OWRT" add -A target && git -C "$OWRT" -c user.name=build -c user.email=build@localhost \
		commit -q -m "stage: Sply-Dev AX23 v2 tree @ $AX23_SHA" && git -C "$OWRT" log --oneline -1
}

# ---------------------------------------------------------------- 05 dev patches
s_dev_patches() {
	local series="$PROJ/patches/openwrt/series" p
	[ -f "$series" ] || { echo "no series file"; return 1; }
	while read -r p; do
		case "$p" in ''|'#'*) continue ;; esac
		echo "== git am $p"
		git -C "$OWRT" -c user.name=build -c user.email=build@localhost \
			am --3way --committer-date-is-author-date "$PROJ/patches/openwrt/$p"
	done <"$series"
	git -C "$OWRT" log --oneline "$OPENWRT_SHA..HEAD"
	s_board_data
}

# --resume: apply series patches whose subject is not yet in the tree, in series order.
# A patch already present is never re-applied; editing an applied patch still needs a full run.
s_new_patches() {
	local series="$PROJ/patches/openwrt/series" p subj applied
	applied=$(git -C "$OWRT" log --format=%s "$OPENWRT_SHA..HEAD")
	while read -r p; do
		case "$p" in ''|'#'*) continue ;; esac
		subj=$(git mailinfo /dev/null /dev/null <"$PROJ/patches/openwrt/$p" | sed -n 's/^Subject: //p')
		if printf '%s\n' "$applied" | grep -qxF -- "$subj"; then continue; fi
		echo "== git am (new since last run) $p"
		git -C "$OWRT" -c user.name=build -c user.email=build@localhost \
			am --3way --committer-date-is-author-date "$PROJ/patches/openwrt/$p"
	done <"$series"
	git -C "$OWRT" log --oneline -3
}

# Locally supplied, never committed: board-data/board-tplink_archer-ax23-v2.{ipq5018,qcn6122}
s_board_data() {
	local bd="$PROJ/board-data" pkg="$OWRT/package/firmware/ipq-wifi-tplink-archer-ax23-v2/files" f
	local name="bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=TP-Link-Archer-AX23-v2"
	rm -f "$pkg"/board-tplink_archer-ax23-v2.*
	for f in ipq5018 qcn6122; do
		if [ ! -f "$bd/board-tplink_archer-ax23-v2.$f" ]; then
			echo "BOARD-DATA: $f ABSENT -> image will have no Wi-Fi board data"
			echo absent > "$LOGDIR/board-data.status"; return 0
		fi
	done
	for f in ipq5018 qcn6122; do
		python3 -I "$PROJ/tools/bdf/board2.py" lookup "$bd/board-tplink_archer-ax23-v2.$f" \
			--chip-id 0 --board-id 255 --variant TP-Link-Archer-AX23-v2 | tee /dev/stderr | \
			grep -q "^MATCH $name\$" || { echo "BOARD-DATA: $f has no exact '$name' entry"; return 1; }
		# must resolve for any OTP board id (stock DT ids: IPQ5018 0x24, QCN6122 0x60)
		python3 -I "$PROJ/tools/bdf/board2.py" robust "$bd/board-tplink_archer-ax23-v2.$f" \
			--stock-board-id "$([ $f = ipq5018 ] && echo 36 || echo 96)" | tail -n1 | grep -q "ROBUST$" \
			|| { echo "BOARD-DATA: $f resolves only for some OTP board ids (re-run tools/bdf/board-data-from-tplink-firmware.sh)"; return 1; }
		cp "$bd/board-tplink_archer-ax23-v2.$f" "$pkg/"
	done
	sha256sum "$pkg"/board-tplink_archer-ax23-v2.* | sed "s#$PROJ/##" | tee "$LOGDIR/board-data.status"
}

# ---------------------------------------------------------------- 06 feeds
s_feeds() {
	cat >"$OWRT/feeds.conf" <<EOF
src-git packages $FEED_PACKAGES
src-git luci $FEED_LUCI
src-git routing $FEED_ROUTING
EOF
	cat "$OWRT/feeds.conf"
	(cd "$OWRT" && ./scripts/feeds update -a && ./scripts/feeds install -a)
	for f in packages luci routing; do
		echo "feed $f $(git -C "$OWRT/feeds/$f" rev-parse HEAD)"
	done
}

# ---------------------------------------------------------------- 07 config
s_config() {
	local frag="$PROJ/configs/$VARIANT.diffconfig"
	[ "$VARIANT" = dev ] && frag="$PROJ/configs/dev-core.diffconfig"
	cp "$frag" "$OWRT/.config"
	(cd "$OWRT" && make defconfig)
	grep -q "^CONFIG_TARGET_qualcommax_ipq50xx_DEVICE_tplink_archer-ax23-v2=y" "$OWRT/.config"
	grep -q "^CONFIG_TARGET_ROOTFS_INITRAMFS=y" "$OWRT/.config"
	(cd "$OWRT" && ./scripts/diffconfig.sh) >"$LOGDIR/diffconfig.final"
	cat "$LOGDIR/diffconfig.final"
}

# ---------------------------------------------------------------- 08/09 build
s_kernel() {
	cd "$OWRT"
	make -j"$JOBS" tools/install toolchain/install
	make -j"$JOBS" target/linux/compile
	# DTBs are compiled in the image step (validated in stage 10); here only
	# require the kernel image itself.
	ls build_dir/target-*/linux-qualcommax_ipq50xx/linux-*/arch/arm64/boot/Image
}
s_world() {
	cd "$OWRT"
	make -j"$JOBS" world || { echo "parallel build failed; re-running -j1 V=s for diagnostics"; make -j1 V=s world; }
}

# ---------------------------------------------------------------- 10 validate
s_validate() {
	# The baseline reproduces the upstream tree including its known defects
	# (e.g. D3 LED mapping); record them but do not stop the collection.
	if [ "$VARIANT" = baseline ]; then
		"$PROJ/tools/validate-artifacts.sh" "$OWRT" "$VARIANT" || echo "baseline: known upstream defects recorded in reports/artifacts-baseline.txt"
	else
		"$PROJ/tools/validate-artifacts.sh" "$OWRT" "$VARIANT"
	fi
}

# ---------------------------------------------------------------- 11 collect
s_collect() {
	local ram="$PROJ/artifacts/ram-only/$VARIANT" exp="$PROJ/artifacts/experimental-do-not-flash/$VARIANT" f
	rm -rf "$ram" "$exp"; mkdir -p "$ram" "$exp"
	cp -v "$BIN"/*"$DEVICE"-initramfs-uImage.itb "$ram/"
	cp -v "$BIN"/*"$DEVICE".manifest "$ram/" 2>/dev/null || true
	cp -v "$BIN"/profiles.json "$ram/" 2>/dev/null || true
	for f in "$BIN"/*"$DEVICE"-*factory.ubi "$BIN"/*"$DEVICE"-*sysupgrade.bin; do
		[ -e "$f" ] && cp -v "$f" "$exp/"
	done
	cat >"$exp/DO-NOT-FLASH.txt" <<'EOF'
These images are build by-products only. They have NOT been validated on
hardware and the AX23 v2 has no validated sysupgrade/A-B (tp_boot_idx) logic
or recovery path. Writing any of them to NAND can leave the router
unbootable without UART access. See reports/nand-boot-safety.md.
EOF
	(cd "$ram" && sha256sum * > SHA256SUMS && cat SHA256SUMS)
	(cd "$exp" && sha256sum * > SHA256SUMS && cat SHA256SUMS)
	{
		echo "variant=$VARIANT"; echo "built=$(ts)"
		echo "openwrt=$(git -C "$UP/openwrt" rev-parse "$OPENWRT_SHA")"
		echo "ax23=$AX23_SHA"
		echo "build_tree_head=$(git -C "$OWRT" rev-parse HEAD)"
		git -C "$OWRT" log --format='  %h %s' "$OPENWRT_SHA..HEAD"
		for f in packages luci routing; do echo "feed_$f=$(git -C "$OWRT/feeds/$f" rev-parse HEAD)"; done
		echo "host=$(uname -srm) gcc=$(gcc -dumpfullversion)"
	} | tee "$ram/BUILDINFO"
	cp "$ram/BUILDINFO" "$exp/BUILDINFO"
}

say "pipeline start (jobs=$JOBS)"
run_stage 01 deps s_deps
if [ "$RESUME" = 1 ]; then
	say "resume: keeping prepared tree $(git -C "$OWRT" log --oneline -1)"
	git -C "$OWRT" merge-base --is-ancestor "$OPENWRT_SHA" HEAD || die "resume: tree is not based on $OPENWRT_SHA"
	[ "$VARIANT" = dev ] && run_stage 05a new-patches s_new_patches
	[ "$VARIANT" = dev ] && run_stage 05b board-data s_board_data
else
	run_stage 02 checkout s_checkout
	run_stage 03 verify-sha s_verify
	run_stage 04 stage-ax23 s_stage_ax23
	[ "$VARIANT" = dev ] && run_stage 05 dev-patches s_dev_patches
	run_stage 06 feeds s_feeds
	run_stage 07 config s_config
fi
[ "$STAGE_ONLY" = 1 ] && { say "stage-only requested; stopping before compile"; exit 0; }
[ -n "$SEED_FROM" ] && die "--seed-from was removed: build_dir/host holds absolute paths of its own tree, so seeding is unsafe"
run_stage 08 kernel s_kernel
run_stage 09 world s_world
run_stage 10 validate s_validate
run_stage 11 collect s_collect
say "pipeline OK"
