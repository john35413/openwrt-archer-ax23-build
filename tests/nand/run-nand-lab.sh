#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# NAND/UBI lab for the AX23 v2 flash layout. Runs INSIDE a throw-away VM
# (tests/nand/vm-run.sh) on a SIMULATED NAND (nandsim, RAM-backed). It never
# touches a real flash device: it refuses to start if any MTD device exists
# before nandsim is loaded.
#
# Geometry: 128 MiB, 2048-byte pages, 128 KiB erase blocks, 64-byte OOB
# (ESMT F50D1G41LB on the AX23 v2 is SPI-NAND; nandsim emulates raw NAND with
# the same page/block geometry, which is what MTD/UBI behaviour depends on).
# Partition map: tests/static/check_dtb.py EXPECTED (= stock table).
#
# Everything here is VERIFIED IN SIMULATION ONLY. U-Boot is not run: its slot
# selection is modelled from TP-Link's GPL source (cmd_bootqca.c do_bootipq).
set -u
OUT=${1:?out dir}
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
ITB=${ITB:-}
[ -n "$ITB" ] && [ -f "$ITB" ] || { echo "BLOCKED: set ITB=<dev initramfs itb> (needed as a real FIT payload for the U-Boot model)"; exit 77; }
WORK=$(mktemp -d)
RES="$OUT/nand-results.tsv"; : >"$RES"
FAILS=0
r() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" | tee -a "$RES"; [ "$2" = FAIL ] && FAILS=$((FAILS+1)); return 0; }
sha() { sha256sum "$1" | cut -c1-64; }
# AX23 NAND has no sub-pages (3P boot log: "sub-page size 2048"): VID header at 2048
att() { ubiattach -p "$1" -O 2048 >>"$OUT/ubi-attach.log" 2>&1; }

if [ -e /dev/mtd0 ] || grep -q . /proc/mtd 2>/dev/null && [ "$(wc -l </proc/mtd)" -gt 1 ]; then
	echo "REFUSING: MTD devices exist before nandsim; this lab only runs on simulated NAND"; exit 2
fi

# name:size-in-erase-blocks (128 KiB) - stock AX23 v2 table; remainder = BBT/spare
PARTS="0:SBL1:4 0:MIBIB:4 0:BOOTCONFIG:2 0:BOOTCONFIG1:2 0:QSEE:8 0:DEVCFG:2 0:CDT:2 0:APPSBLENV:4 0:APPSBL:10 0:ART:8 0:TRAINING:4 rootfs:428 rootfs_1:428 tp_data:66 radio:34 data:4"
sizes=$(for p in $PARTS; do echo "${p##*:}"; done | paste -sd,)
load_nandsim() {
	# K9F1G08-class ID: 128 MiB, 2 KiB page, 128 KiB block, 64 B OOB
	modprobe nandsim id_bytes=0xec,0xf1,0x00,0x15 parts="$sizes" "$@" || return 1
	modprobe ubi 2>/dev/null; modprobe ubifs 2>/dev/null
	udevadm settle 2>/dev/null; sleep 1
	# if the whole device is registered too (partitioned master), partitions start at mtd1
	MTD_BASE=$(awk 'NR>1 && /NAND simulator partition 0"/{sub(":","",$1); sub("mtd","",$1); print $1}' /proc/mtd)
	MTD_BASE=${MTD_BASE:-0}
}
# nandsim names partitions "NAND simulator partition N": map our labels by position
MTD_BASE=0
mtd_of() { local i=0 p; for p in $PARTS; do [ "${p%:*}" = "$1" ] && { echo "/dev/mtd$((MTD_BASE+i))"; return; }; i=$((i+1)); done; }
unload() { for u in /sys/class/ubi/ubi[0-9]*; do [ -e "$u" ] && ubidetach -d "${u##*ubi}" 2>/dev/null; done; rmmod ubifs 2>/dev/null; rmmod ubi 2>/dev/null; rmmod nandsim 2>/dev/null; sleep 1; }

load_nandsim || { r L00 BLOCKED "nandsim" "modprobe failed"; exit 77; }

# ---- L01 geometry and partition map
eb=$(cat /sys/class/mtd/mtd0/erasesize); pg=$(cat /sys/class/mtd/mtd0/writesize); oob=$(cat /sys/class/mtd/mtd0/oobsize)
[ "$eb" = 131072 ] && [ "$pg" = 2048 ] && [ "$oob" = 64 ] && r L01 PASS "NAND geometry 2048/131072/64" "page=$pg eb=$eb oob=$oob" || r L01 FAIL "NAND geometry" "page=$pg eb=$eb oob=$oob"
off=0; ok=1
for p in $PARTS; do
	n=${p%:*}; b=${p##*:}; d=$(mtd_of "$n")
	[ -n "$d" ] || { ok=0; echo "missing $n"; continue; }
	s=$(cat /sys/class/mtd/${d#/dev/}/size); o=$(cat /sys/class/mtd/${d#/dev/}/offset)
	[ "$s" = $((b*131072)) ] && [ "$o" = "$off" ] || { ok=0; echo "$n off=$o size=$s want off=$off size=$((b*131072))"; }
	off=$((off + b*131072))
done
[ $ok = 1 ] && r L01 PASS "partition offsets/sizes = stock table (16)" "last end=0x$(printf %x $off)" || r L01 FAIL "partition map" "see console"

SL0=$(mtd_of rootfs); SL1=$(mtd_of rootfs_1); ENV=$(mtd_of 0:APPSBLENV)

# Synthetic factory data (random bytes, never real calibration/MAC data)
for n in 0:ART tp_data radio 0:APPSBL; do
	d=$(mtd_of "$n"); sz=$(cat /sys/class/mtd/${d#/dev/}/size)
	head -c "$sz" /dev/urandom >"$WORK/$n.img"; flash_erase -q "$d" 0 0; nandwrite -q -p "$d" "$WORK/$n.img"
done
snap() { for n in 0:SBL1 0:APPSBL 0:ART tp_data radio rootfs; do d=$(mtd_of "$n"); nanddump -q -a "$d" -f "$WORK/s.$n" 2>/dev/null; printf '%s %s\n' "$n" "$(sha "$WORK/s.$n")"; done; }

# ---- L02 stock-like slot 0 (volumes "kernel" + "ubi_rootfs", what bootipq reads)
cp "$ITB" "$WORK/stock-kernel.bin"; head -c 20000000 /dev/urandom >"$WORK/stock-rootfs.bin"
cat >"$WORK/stock.ini" <<EOF
[kernel]
mode=ubi
image=$WORK/stock-kernel.bin
vol_id=0
vol_type=dynamic
vol_name=kernel
[ubi_rootfs]
mode=ubi
image=$WORK/stock-rootfs.bin
vol_id=1
vol_type=dynamic
vol_name=ubi_rootfs
EOF
ubinize -o "$WORK/stock.ubi" -p 128KiB -m 2048 -s 2048 "$WORK/stock.ini"
ubiformat -q -y -s 2048 -O 2048 "$SL0" -f "$WORK/stock.ubi" >>"$OUT/ubi-attach.log" 2>&1
att "$SL0"; u0=$(ls -d /sys/class/ubi/ubi[0-9]* | head -1); u0=${u0##*/}
dd if=/dev/${u0}_0 of="$WORK/k0" bs=1M 2>/dev/null; head -c "$(stat -c%s "$WORK/stock-kernel.bin")" "$WORK/k0" >"$WORK/k0c"
[ "$(sha "$WORK/k0c")" = "$(sha "$WORK/stock-kernel.bin")" ] && [ "$(cat /sys/class/ubi/$u0/${u0}_0/name)" = kernel ] \
	&& r L02 PASS "slot 0 UBI has 'kernel' + 'ubi_rootfs', kernel reads back" "" || r L02 FAIL "slot 0 layout" ""
ubidetach -p "$SL0" >/dev/null 2>&1
before=$(snap)

# ---- L03 OpenWrt-style image into the INACTIVE slot only (rootfs_1)
cp "$ITB" "$WORK/owrt-kernel.bin"; src="dev initramfs itb as kernel volume payload"
head -c 9000000 /dev/urandom >"$WORK/owrt-rootfs.bin"
sed -e "s#$WORK/stock-kernel.bin#$WORK/owrt-kernel.bin#; s#$WORK/stock-rootfs.bin#$WORK/owrt-rootfs.bin#; s#vol_name=ubi_rootfs#vol_name=rootfs#" "$WORK/stock.ini" >"$WORK/owrt.ini"
printf '[rootfs_data]\nmode=ubi\nvol_id=2\nvol_type=dynamic\nvol_name=rootfs_data\nvol_size=1MiB\nvol_flags=autoresize\n' >>"$WORK/owrt.ini"
ubinize -o "$WORK/owrt.ubi" -p 128KiB -m 2048 -s 2048 "$WORK/owrt.ini"
ubiformat -q -y -s 2048 -O 2048 "$SL1" -f "$WORK/owrt.ubi" >>"$OUT/ubi-attach.log" 2>&1
after=$(snap)
[ "$before" = "$after" ] && r L03 PASS "writing rootfs_1 leaves SBL1/APPSBL/ART/tp_data/radio/rootfs bit-identical" "$src" \
	|| r L03 FAIL "slot isolation" "$(diff <(echo "$before") <(echo "$after") | tr '\n' ' ')"
att "$SL1"; u1=$(ls -d /sys/class/ubi/ubi[0-9]* | head -1); u1=${u1##*/}
k=$(cat /sys/class/ubi/$u1/${u1}_0/name); dd if=/dev/${u1}_0 of="$WORK/k1" bs=1M 2>/dev/null; head -c "$(stat -c%s "$WORK/owrt-kernel.bin")" "$WORK/k1" >"$WORK/k1c"
[ "$k" = kernel ] && [ "$(sha "$WORK/k1c")" = "$(sha "$WORK/owrt-kernel.bin")" ] && r L03 PASS "slot 1 'kernel' volume reads back bit-exact" "$(stat -c%s "$WORK/owrt-kernel.bin") bytes" || r L03 FAIL "slot 1 kernel volume" "name=$k"
ubidetach -p "$SL1" >/dev/null 2>&1

# ---- L04 U-Boot env layout of patch 0011 (APPSBLENV offset 0, 0x40000, sector 0x20000)
printf 'bootcmd=bootipq\nbootdelay=1\ntp_boot_idx=1\n' >"$WORK/env.txt"
mkenvimage -s 0x40000 -o "$WORK/env.bin" "$WORK/env.txt"
flash_erase -q "$ENV" 0 0; nandwrite -q -p "$ENV" "$WORK/env.bin"
printf '%s 0x0 0x40000 0x20000\n' "$ENV" >"$WORK/fw_env.config"
v=$(fw_printenv -c "$WORK/fw_env.config" -n tp_boot_idx 2>/dev/null)
[ "$v" = 1 ] && r L04 PASS "fw_printenv with the 0011 layout reads tp_boot_idx" "tp_boot_idx=$v" || r L04 FAIL "0011 env layout" "got '$v'"
printf '%s 0x0 0x20000 0x20000\n' "$ENV" >"$WORK/fw_env.bad"
v=$(fw_printenv -c "$WORK/fw_env.bad" -n tp_boot_idx 2>&1)
[ "$v" != 1 ] && r L04 PASS "a wrong env size (0x20000) is rejected (CRC), not misread" "$(echo "$v" | head -1)" || r L04 FAIL "wrong size accepted" "$v"

# Model of do_bootipq() slot choice (GPL cmd_bootqca.c): idx "1" -> rootfs_1 else rootfs;
# load failure -> other slot; both fail -> httpd recovery. "Load" = attach + read kernel volume.
bootipq_model() {
	local idx sel other
	idx=$(fw_printenv -c "$WORK/fw_env.config" -n tp_boot_idx 2>/dev/null)
	[ "$idx" = 1 ] && { sel=$SL1; other=$SL0; } || { sel=$SL0; other=$SL1; }
	for s in "$sel" "$other"; do
		if att "$s"; then
			u=$(ls -d /sys/class/ubi/ubi[0-9]* | head -1); u=${u##*/}
			# ubi read ... kernel, then config_select + bootm: FIT hashes and config@mp02.1
			if [ "$(cat /sys/class/ubi/$u/${u}_0/name 2>/dev/null)" = kernel ] && dd if=/dev/${u}_0 of="$WORK/load" bs=1M 2>/dev/null \
			   && python3 -I "$PROJ/tools/fit-verify.py" "$WORK/load" --config config@mp02.1 >/dev/null 2>&1; then
				ubidetach -p "$s" >/dev/null 2>&1; echo "$s"; return 0; fi
			ubidetach -p "$s" >/dev/null 2>&1
		fi
	done
	echo httpd-recovery
}
got=$(bootipq_model); [ "$got" = "$SL1" ] && r L05 PASS "model: tp_boot_idx=1 boots rootfs_1" "$got" || r L05 FAIL "model idx=1" "$got"

# ---- L06 interrupted write of the inactive slot (power loss during install)
flash_erase -q "$SL1" 0 0 >/dev/null 2>&1   # erase, then write part of the image only
head -c $((3*1024*1024)) "$WORK/owrt.ubi" >"$WORK/partial.ubi"
nandwrite -q -p "$SL1" "$WORK/partial.ubi" 2>/dev/null
after2=$(snap)
[ "$before" = "$after2" ] && r L06 PASS "interrupted slot-1 write leaves other partitions intact" "" || r L06 FAIL "interrupted write isolation" ""
got=$(bootipq_model)
[ "$got" = "$SL0" ] && r L06 PASS "model: idx=1 + truncated slot 1 falls back to rootfs (stock)" "$got" \
	|| r L06 FAIL "fallback after truncated slot" "$got"
flash_erase -q "$SL0" 0 0 >/dev/null 2>&1
got=$(bootipq_model)
[ "$got" = httpd-recovery ] && r L06 PASS "model: both slots unloadable -> U-Boot httpd recovery" "$got" || r L06 FAIL "both slots bad" "$got"
r L06 INFO "limit" "U-Boot only falls back on LOAD failure; a kernel that loads and then crashes is not caught (GPL source)"

# ---- L07 bad blocks inside the inactive slot are skipped
unload
first=$(( (4+4+2+2+8+2+2+4+10+8+4+428) ))   # first eraseblock of rootfs_1
load_nandsim badblocks=$((first+3)),$((first+50)),$((first+200)) || { r L07 BLOCKED "nandsim reload" ""; }
SL1=$(mtd_of rootfs_1); SL0=$(mtd_of rootfs)
ubiformat -q -y -s 2048 -O 2048 "$SL1" -f "$WORK/owrt.ubi" >>"$OUT/ubi-attach.log" 2>&1; rc=$?
att "$SL1"; u=$(ls -d /sys/class/ubi/ubi[0-9]* | head -1); u=${u##*/}
dd if=/dev/${u}_0 of="$WORK/kb" bs=1M 2>/dev/null; head -c "$(stat -c%s "$WORK/owrt-kernel.bin")" "$WORK/kb" >"$WORK/kbc"
[ $rc = 0 ] && [ "$(sha "$WORK/kbc")" = "$(sha "$WORK/owrt-kernel.bin")" ] && r L07 PASS "ubiformat skips 3 bad blocks in rootfs_1; kernel volume intact" "bad=$(cat /sys/class/ubi/$u/bad_peb_count)" \
	|| r L07 FAIL "bad-block handling" "rc=$rc"
ubidetach -p "$SL1" >/dev/null 2>&1

# ---- L08 a read-write UBI attach writes NAND by itself (rationale of patch 0015)
# One correctable bitflip is injected deterministically: the page holding the
# first 2 KiB of a volume is re-programmed raw with one data bit cleared (NAND
# programming only clears bits) and the ECC bytes unchanged. Then the volume
# is only READ. A read-write UBI scrubs the PEB: it copies it and erases it.
unload
load_nandsim || { r L08 BLOCKED "nandsim reload" ""; }
# The VM's Ubuntu kernel builds UBI with fastmap; with fastmap off for a device its WL
# pool is never refilled and scheduled scrubs never run. fm_autoconvert=1 lets the WL
# worker run (and adds fastmap writes). The AX23 kernel has no fastmap
# (CONFIG_MTD_UBI_FASTMAP unset), where scrubbing uses the plain WL path directly.
rmmod ubifs 2>/dev/null; rmmod ubi 2>/dev/null; modprobe ubi fm_autoconvert=1
D=$(mtd_of tp_data); dn=${D#/dev/}
ubiformat -q -y -s 2048 -O 2048 "$D" >>"$OUT/ubi-attach.log" 2>&1
att "$D"; u=$(ls -d /sys/class/ubi/ubi[0-9]* | head -1); u=${u##*/}
{ ubimkvol /dev/$u -N vol -s 4MiB; head -c 4000000 /dev/urandom >"$WORK/v"; ubiupdatevol /dev/${u}_0 "$WORK/v"; } >>"$OUT/ubi-attach.log" 2>&1
ubidetach -p "$D" >/dev/null 2>&1
nanddump -q -f "$WORK/raw" "$D" >>"$OUT/ubi-attach.log" 2>&1
off=$(python3 -I -c "import sys; r=open(sys.argv[1],'rb').read(); v=open(sys.argv[2],'rb').read(2048); i=r.find(v); print(i if i>=0 and i%2048==0 else -1, len(r), i)" "$WORK/raw" "$WORK/v")
echo "L08 locate: $off" >>"$OUT/ubi-attach.log"; off=${off%% *}
if [ "${off:--1}" -ge 0 ]; then
	nanddump -q -n -o -s "$off" -l 2048 -f "$WORK/pg" "$D" 2>/dev/null
	python3 -I -c "
import sys; p=bytearray(open(sys.argv[1],'rb').read())
i=next(k for k in range(2048) if p[k])
p[i] &= p[i]-1          # clear the lowest set bit of one data byte
open(sys.argv[2],'wb').write(p)" "$WORK/pg" "$WORK/pg2"
	nandwrite -q -n -o -s "$off" "$D" "$WORK/pg2" 2>>"$OUT/ubi-attach.log"
	dmesg >"$OUT/dmesg-before-L08.txt" 2>/dev/null; dmesg -C 2>/dev/null
	c0=$(cat /sys/class/mtd/$dn/corrected_bits 2>/dev/null)
	att "$D"
	dd if=/dev/${u}_0 of="$WORK/rb" bs=1M 2>/dev/null          # read only
	for i in $(seq 1 30); do dmesg | grep -q "scrubbed PEB" && break; sleep 1; done
	sleep 2                                                    # let the erase work run
	c1=$(cat /sys/class/mtd/$dn/corrected_bits 2>/dev/null)
	ubidetach -p "$D" >/dev/null 2>&1
	dmesg >"$OUT/dmesg-L08.txt" 2>/dev/null
	head -c 4000000 "$WORK/rb" | cmp -s - "$WORK/v" && dataok=yes || dataok=no
	nanddump -q -n -o -s "$off" -l 2048 -f "$WORK/pg3" "$D" 2>/dev/null
	cmp -s "$WORK/pg2" "$WORK/pg3" && moved=no || moved=yes
	ev=$(grep -E "fixable bit-flip|scrubbed PEB|schedule.*scrub" "$OUT/dmesg-L08.txt" | sed 's/^\[[^]]*\] //' | paste -sd';')
	[ "$moved" = yes ] && [ "$dataok" = yes ] && r L08 PASS "a read-only workload made the read-write UBI erase/rewrite the flipped PEB" "corrected_bits $c0->$c1, scrub log lines=$ev, data intact=$dataok" \
		|| r L08 FAIL "expected UBI scrub after a correctable bitflip" "moved=$moved data=$dataok corrected_bits $c0->$c1 lines=$ev"
else r L08 BLOCKED "bitflip injection" "volume page not found in raw dump"; fi
r L08 INFO "consequence" "a RAM image that attaches a writable UBI can write NAND with no command given; patch 0015 makes every AX23 partition read-only, so UBI attaches read-only (as tp_data already does on HW: 'MTD device is write-protected, attach in read-only mode')"
unload
rm -rf "$WORK"
echo "fails=$FAILS" | tee -a "$RES"
[ "$FAILS" -eq 0 ]
