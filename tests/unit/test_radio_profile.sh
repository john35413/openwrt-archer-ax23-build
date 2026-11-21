#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Runs the AX23 radio bring-up profile scripts (patch 0017) against a fake sysfs
# tree and command line: which Wi-Fi platform devices are held back from ath11k
# for each ax23_radios= value, and that "seq" releases the 5 GHz radio only after
# the 2.4 GHz phy appears. Logic test only: no driver or firmware is involved.
set -u
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# Replay the profile patches into the disposable fixture.
B=target/linux/qualcommax/ipq50xx/base-files
SRC="$T/$B"
for p in "$PROJ"/patches/openwrt/{0017,0021}-*.patch; do
	(cd "$T" && git apply --include="$B/*" "$p") || exit 1
done
rc=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; rc=1; }
setup() {
	rm -rf "$T/sys"; for d in c000000.wifi b00a040.wifi; do
		mkdir -p "$T/sys/bus/platform/devices/$d"; : >"$T/sys/bus/platform/devices/$d/driver_override"; done
	: >"$T/sys/bus/platform/drivers_probe"; echo "console=ttyMSM0 $1" >"$T/cmdline"
}
run_preinit() {	# board
	( boot_hook_add() { :; }; board_name() { echo "$1"; }
	  export AX23_SYSFS="$T/sys" AX23_CMDLINE="$T/cmdline" AX23_STATE="$T/state" AX23_BOARD="$1"
	  . "$SRC/lib/preinit/08_ax23_radio_profile"; ax23_radio_profile ) 2>/dev/null
}
held() { local o=""; for d in c000000.wifi b00a040.wifi; do
	[ "$(cat "$T/sys/bus/platform/devices/$d/driver_override")" = none ] && o="$o $d"; done; echo "${o# }"; }

for c in "|both|" "ax23_radios=both|both|" "ax23_radios=none|none|c000000.wifi b00a040.wifi" \
	 "ax23_radios=2g|2g|b00a040.wifi" "ax23_radios=5g|5g|c000000.wifi" "ax23_radios=seq|seq|b00a040.wifi" \
	 "ax23_radios=bogus|both|"; do
	IFS='|' read -r arg want_state want_held <<<"$c"
	setup "$arg"; run_preinit tplink,archer-ax23-v2
	[ "$(cat "$T/state")" = "$want_state" ] && [ "$(held)" = "$want_held" ] \
		&& ok "'${arg:-<none>}' -> profile $want_state, held: ${want_held:-nothing}" \
		|| bad "'${arg:-<none>}': state=$(cat "$T/state") held='$(held)'"
done
setup "ax23_radios=none"; rm -f "$T/state"; run_preinit tplink,archer-ax55-v1
[ -z "$(held)" ] && [ ! -f "$T/state" ] && ok "other boards are never touched" || bad "acted on another board"

# seq: 5 GHz released only after the 2.4 GHz phy exists
setup "ax23_radios=seq"; run_preinit tplink,archer-ax23-v2
( logger() { echo "$*" >>"$T/log"; }
  export AX23_SYSFS="$T/sys" AX23_STATE="$T/state" AX23_SEQ_TIMEOUT=20
  . "$SRC/etc/init.d/ax23-radio-seq"
  boot )
sleep 2
[ "$(held)" = b00a040.wifi ] && [ ! -s "$T/sys/bus/platform/drivers_probe" ] && ok "seq: 5 GHz still held while no 2.4 GHz phy" || bad "seq released too early"
mkdir -p "$T/sys/bus/platform/devices/c000000.wifi/ieee80211/phy0"
for _ in $(seq 1 10); do [ -s "$T/sys/bus/platform/drivers_probe" ] && break; sleep 1; done
[ -z "$(held)" ] && [ "$(cat "$T/sys/bus/platform/drivers_probe")" = b00a040.wifi ] \
	&& ok "seq: 5 GHz released and probed after the 2.4 GHz phy registered ($(cat "$T/log" 2>/dev/null))" || bad "seq did not release 5 GHz"
setup "ax23_radios=none"
rm "$T/sys/bus/platform/devices/b00a040.wifi/driver_override"
run_preinit tplink,archer-ax23-v2
grep -q '^incomplete none: b00a040.wifi$' "$T/state" && ok "missing hold reported" || bad "missing hold hidden"
setup "ax23_radios=2g"
ln -s "$T" "$T/sys/bus/platform/devices/b00a040.wifi/driver"
run_preinit tplink,archer-ax23-v2
grep -q '^incomplete 2g' "$T/state" && ok "already-bound radio reported" || bad "bound radio hidden"
setup "ax23_radios=seq"; run_preinit tplink,archer-ax23-v2
( logger() { :; }
  export AX23_SYSFS="$T/sys" AX23_STATE="$T/state" AX23_SEQ_TIMEOUT=0
  . "$SRC/etc/init.d/ax23-radio-seq"; boot; wait )
[ "$(held)" = b00a040.wifi ] && [ ! -s "$T/sys/bus/platform/drivers_probe" ] &&
	grep -q '^seq timeout' "$T/state" && ok "timeout keeps 5 GHz held" || bad "timeout overlapped startup"
exit $rc
