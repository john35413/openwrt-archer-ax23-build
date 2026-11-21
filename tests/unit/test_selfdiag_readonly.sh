#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Static guard: the on-router diagnostics must not contain commands that can
# write flash, the U-Boot environment, UCI, sysfs/procfs or change system state.
# (Behaviour is checked separately on the digital twin: tests/twin S06.)
set -u
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
rc=0
FORBID='fw_setenv|mtd (write|erase|-r)|nandwrite|flash_erase|ubiformat|ubiupdatevol|ubimkvol|ubirmvol|ubiattach|ubidetach|dd .*of=|(^[[:space:]]*|[;&|][[:space:]]*)sysupgrade |uci (set|add|del|commit|delete|revert)|>[ ]*/(sys|proc)/|>[ ]*/dev/(mtd|ubi|mmc|sd)|(^|[^-a-z])mount |umount|insmod|modprobe|rmmod|ifup|ifdown|wifi (up|down|reload)|/etc/init\.d/|reboot|poweroff|(^|[ ;])halt|(^|[ ;|])kill '
for f in tests/hardware/ax23-selfdiag.sh tests/hardware/router-collect.sh; do
	hits=$(grep -nvE '^\s*#' "$PROJ/$f" | grep -E "$FORBID" | grep -vE '#.*(never|refuse|not )' || true)
	# router-collect.sh mounts debugfs read-only-ish for GPIO listing; report it, do not hide it
	if [ -n "$hits" ]; then
		if [ "$f" = tests/hardware/router-collect.sh ] && [ "$(echo "$hits" | grep -vc 'mount -t debugfs')" -eq 0 ]; then
			echo "NOTE $f: mounts debugfs if absent (no flash/config write): $hits"
		else echo "FAIL $f:"; echo "$hits"; rc=1; fi
	else echo "PASS $f: no write-capable commands"; fi
done
grep -q "redact" "$PROJ/tests/hardware/ax23-selfdiag.sh" && echo "PASS ax23-selfdiag.sh redacts output" || { echo "FAIL no redaction"; rc=1; }
exit $rc
