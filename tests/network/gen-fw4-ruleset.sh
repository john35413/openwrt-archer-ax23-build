#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Generate the nftables ruleset that the BUILT AX23 v2 image's own fw4 produces,
# by running the image userspace (aarch64) under qemu-user in a throw-away copy
# of the build root:
#   1. /bin/board_detect   -> board.json from the AX23 board.d scripts
#   2. /bin/config_generate -> /etc/config/network (checked: lan1-4 -> br-lan, wan)
#   3. uci batch configs/uci/10-guest-iot-networks.uci (the shipped profile)
#   4. map zones to the namespace test devices (fw4 cannot ask netifd/ubus here)
#   5. fw4 print -> OUT
#
#   gen-fw4-ruleset.sh <variant> <out.nft>
set -euo pipefail
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
V="${1:-dev}"; OUT="${2:-$PROJ/logs/network/fw4-generated-$V.nft}"
ROOT=$(ls -d "$PROJ"/build/"$V"/openwrt/build_dir/target-*/root-qualcommax 2>/dev/null | head -1 || true)
[ -d "$ROOT" ] || { echo "BLOCKED: no built rootfs for $V"; exit 77; }
command -v qemu-aarch64-static >/dev/null || { echo "BLOCKED: qemu-user-static missing"; exit 77; }
# Temporary binfmt_misc handler so aarch64 children run inside the chroot;
# removed again on exit if this script registered it.
BF=/proc/sys/fs/binfmt_misc; REG=0
[ -e $BF/register ] || mount -t binfmt_misc binfmt_misc $BF 2>/dev/null || true
if [ ! -e $BF/qemu-aarch64 ] && [ -w $BF/register ]; then
	printf '%s' ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:F' >$BF/register && REG=1
fi
[ -e $BF/qemu-aarch64 ] || { echo "BLOCKED: cannot register qemu-aarch64 binfmt handler"; exit 77; }
W=$(mktemp -d); trap 'umount -l "$W/r/proc" "$W/r/dev" 2>/dev/null; rm -rf "$W"; [ $REG = 1 ] && echo -1 >$BF/qemu-aarch64' EXIT
cp -a "$ROOT" "$W/r"; cp /usr/bin/qemu-aarch64-static "$W/r/usr/bin/"
mkdir -p "$W/r/proc" "$W/r/dev" "$W/r/tmp/sysinfo" "$W/r/var/lock"
mount -t proc proc "$W/r/proc"; mount --rbind /dev "$W/r/dev"
echo "tplink,archer-ax23-v2" >"$W/r/tmp/sysinfo/board_name"
echo "TP-Link Archer AX23 v2" >"$W/r/tmp/sysinfo/model"
C() { chroot "$W/r" /bin/sh -c "$1"; }
LOG="$PROJ/logs/network/gen-fw4-$V.log"; : >"$LOG"
{
	echo "== board_detect"; C 'rm -f /etc/board.json; /bin/board_detect && cat /etc/board.json'
	echo "== config_generate"; C 'rm -f /etc/config/network; /bin/config_generate; uci show network'
} >>"$LOG" 2>&1
# assertions on the AX23 board scripts' output
net=$(C 'uci show network')
echo "$net" | grep -q "ports='lan1' 'lan2' 'lan3' 'lan4'" && echo "PASS board.d: br-lan ports lan1-4" || { echo "FAIL board.d lan ports"; echo "$net" >>"$LOG"; exit 1; }
echo "$net" | grep -q "network.wan.device='wan'" && echo "PASS board.d: wan device 'wan'" || { echo "FAIL board.d wan"; exit 1; }
C 'grep -q "white:lan" /etc/board.json && grep -q "white:wan" /etc/board.json' && echo "PASS board.d: LAN/WAN LED netdev triggers in board.json" || echo "FAIL board.d LEDs"
touch "$W/r/etc/config/wireless"
cp "$PROJ/configs/uci/10-guest-iot-networks.uci" "$W/r/tmp/p.uci"
C 'uci batch < /tmp/p.uci && uci commit' >>"$LOG" 2>&1 && echo "PASS shipped UCI profile applies (uci batch)" || { echo "FAIL uci batch"; exit 1; }
# Map zones to the netns devices (test adaptation only)
C 'for z in $(uci show firewall | sed -n "s/^firewall\.\([^.]*\)=zone$/\1/p"); do
	n=$(uci get firewall.$z.name)
	uci -q delete firewall.$z.network
	case $n in
	lan) uci add_list firewall.$z.device=br-lan.1 ;;
	wan) uci add_list firewall.$z.device=wan; uci add_list firewall.$z.device=wan2 ;;
	guest) uci add_list firewall.$z.device=br-lan.20 ;;
	iot) uci add_list firewall.$z.device=br-lan.30 ;;
	esac
done; uci set firewall.@defaults[0].flow_offloading=1; uci commit firewall' >>"$LOG" 2>&1
C 'fw4 check' >>"$LOG" 2>&1 && echo "PASS fw4 check" || echo "WARN fw4 check returned non-zero (see log)"
C 'fw4 print' >"$OUT" 2>>"$LOG"
grep -q "table inet fw4" "$OUT" && echo "PASS fw4 print -> $(wc -l <"$OUT") lines: ${OUT#$PROJ/}" || { echo "FAIL fw4 print"; tail -5 "$LOG"; exit 1; }
