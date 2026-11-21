#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# SIMULATED routing/firewall/DHCP/DNS/VLAN tests in Linux network namespaces.
#
# This models the AX23 v2's *software* configuration (br-lan bridge with
# per-port VLANs as the DSA bridge-vlan setup would give, fw4-structured
# nftables, dnsmasq DHCP/DNS/RA, masquerade on wan). It does NOT exercise
# the IPQ5018, the RTL8367S-VB switch, the 2.5G trunk or any radio, and its
# throughput numbers are veth numbers. PASS here is never evidence that the
# physical router works.
#
# Usage (as root, in a kernel with bridge/8021q/nft/netem; see
# tools/test-dev.sh which runs this in a QEMU VM):
#   run-netns-tests.sh [--ruleset FILE] [--out DIR]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RULESET="$HERE/fw4-reference.nft"
OUT="$HERE/../../logs/network"
while [ $# -gt 0 ]; do case "$1" in
	--ruleset) RULESET="$2"; shift 2 ;;
	--out) OUT="$2"; shift 2 ;;
	*) echo "bad arg $1"; exit 2 ;;
esac; done
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
RES="$OUT/results.tsv"; LOG="$OUT/netns-test.log"
W=$(mktemp -d /tmp/ax23-netns.XXXX)
: >"$RES"; exec 3>&1 >"$LOG" 2>&1
NS="isp isp2 inet rtr c1 c2 g1 i1"
PASS=0; FAIL=0
res() {	# res ID STATUS description [measurement]
	printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$RES"
	printf '%-5s %-4s %s %s\n' "$1" "$2" "$3" "${4:-}" >&3
	echo "### $1 $2 $3 ${4:-}"
	[ "$2" = PASS ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
}
x() { local n=$1; shift; ip netns exec "$n" "$@"; }
cleanup() {
	for n in $NS; do ip netns pids "$n" 2>/dev/null | xargs -r kill 2>/dev/null; done
	sleep 0.3; for n in $NS; do ip netns del "$n" 2>/dev/null; done; rm -rf "$W"
}
trap cleanup EXIT
for m in bridge 8021q veth sch_netem sch_cake nft_masq nft_flow_offload nf_conntrack; do modprobe "$m" 2>/dev/null; done
for n in $NS; do ip netns add "$n"; x "$n" ip link set lo up; done

link() {	# link nsA ifA nsB ifB
	ip link add "$2" netns "$1" type veth peer name "$4" netns "$3"
	x "$1" ip link set "$2" up; x "$3" ip link set "$4" up
}

# ---------------------------------------------------------------- topology
#   inet (198.51.100.10, 198.18.0.10, 2001:db8:100::10)
#     |-- isp  (198.51.100.1 | 203.0.113.1 DHCP server for router wan)
#     |-- isp2 (198.18.0.1   | 192.0.2.1)
#   rtr: wan<->isp, wan2<->isp2, br-lan (vlan_filtering) ports lan1..lan4
#        lan1,lan2: VLAN 1 (lan) | lan3: VLAN 20 (guest) | lan4: VLAN 30 (iot)
#   c1@lan1 c2@lan2 g1@lan3 i1@lan4
link inet up1 isp dn; link inet up2 isp2 dn
link isp wanp rtr wan; link isp2 wanp rtr wan2
x inet ip addr add 198.51.100.10/24 dev up1; x inet ip addr add 198.18.0.10/24 dev up2
x inet ip -6 addr add 2001:db8:100::10/64 dev up1 nodad
x inet ip route add default via 198.51.100.1
x inet ip route add 192.0.2.0/24 via 198.18.0.1
x isp ip addr add 198.51.100.1/24 dev dn; x isp ip addr add 203.0.113.1/24 dev wanp
x isp ip -6 addr add 2001:db8:100::1/64 dev dn nodad; x isp ip -6 addr add 2001:db8:ffff::1/64 dev wanp nodad
x isp ip -6 route add 2001:db8:1::/48 via 2001:db8:ffff::2 dev wanp
x isp2 ip addr add 198.18.0.1/24 dev dn; x isp2 ip addr add 192.0.2.1/24 dev wanp
x isp2 ip route add default via 198.18.0.10
x inet ip -6 route add default via 2001:db8:100::1 dev up1
for n in isp isp2 rtr; do x $n sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1; done
# netifd drops an interface's routes on carrier loss; the kernel equivalent:
x rtr sysctl -qw net.ipv4.conf.all.ignore_routes_with_linkdown=1

x rtr ip link add br-lan type bridge vlan_filtering 1 vlan_default_pvid 0
x rtr ip link set br-lan up
x rtr bridge vlan add dev br-lan vid 1 self; x rtr bridge vlan add dev br-lan vid 20 self; x rtr bridge vlan add dev br-lan vid 30 self
i=1; for c in c1 c2 g1 i1; do
	link rtr lan$i "$c" eth0
	x rtr ip link set lan$i master br-lan
	case $c in c1|c2) vid=1 ;; g1) vid=20 ;; i1) vid=30 ;; esac
	x rtr bridge vlan add dev lan$i vid $vid pvid untagged
	i=$((i+1))
done
for v in 1 20 30; do x rtr ip link add link br-lan name br-lan.$v type vlan id $v; x rtr ip link set br-lan.$v up; done
x rtr ip addr add 192.168.1.1/24 dev br-lan.1
x rtr ip addr add 192.168.20.1/24 dev br-lan.20
x rtr ip addr add 192.168.30.1/24 dev br-lan.30
x rtr ip -6 addr add 2001:db8:ffff::2/64 dev wan nodad
x rtr ip -6 addr add 2001:db8:1:1::1/64 dev br-lan.1 nodad
x rtr ip -6 route add default via 2001:db8:ffff::1 dev wan
x rtr ip addr add 192.0.2.2/24 dev wan2
x rtr ip route add default via 192.0.2.1 dev wan2 metric 20

# ---------------------------------------------------------------- services
x isp dnsmasq --conf-file=/dev/null --interface=wanp --bind-interfaces --except-interface=lo \
	--dhcp-range=203.0.113.100,203.0.113.150,255.255.255.0,1h --dhcp-option=3,203.0.113.1 \
	--dhcp-option=6,203.0.113.1 --no-resolv --no-hosts --address=/example.test/198.51.100.10 \
	--address=/example.test/2001:db8:100::10 --dhcp-leasefile="$W/isp.leases" --pid-file="$W/isp.pid" --log-facility="$W/isp-dnsmasq.log"
mkdir -p "$W/lease"
x rtr env LEASE_DIR="$W/lease" METRIC=10 busybox udhcpc -i wan -s "$HERE/udhcpc.script" -n -q -t 10 -T 1 \
	&& WANIP=$(sed -n 's/^ip=//p' "$W/lease/wan.lease") || WANIP=""
[ -n "$WANIP" ] && res N01 PASS "router WAN obtains DHCP lease from ISP" "wan=$WANIP" \
	|| res N01 FAIL "router WAN obtains DHCP lease from ISP"

x rtr nft -f "$RULESET" && res N02 PASS "firewall ruleset loads" "$(basename "$RULESET")" || res N02 FAIL "firewall ruleset loads"

x rtr dnsmasq --conf-file=/dev/null --interface=br-lan.1 --interface=br-lan.20 --interface=br-lan.30 \
	--bind-interfaces --except-interface=lo --no-resolv --no-hosts --server=203.0.113.1 \
	--dhcp-range=set:lan,192.168.1.100,192.168.1.199,12h --dhcp-option=tag:lan,3,192.168.1.1 --dhcp-option=tag:lan,6,192.168.1.1 \
	--dhcp-range=set:guest,192.168.20.100,192.168.20.199,1h --dhcp-option=tag:guest,3,192.168.20.1 --dhcp-option=tag:guest,6,192.168.20.1 \
	--dhcp-range=set:iot,192.168.30.100,192.168.30.199,12h --dhcp-option=tag:iot,3,192.168.30.1 --dhcp-option=tag:iot,6,192.168.30.1 \
	--enable-ra --dhcp-range=::,constructor:br-lan.1,ra-only,64,12h \
	--dhcp-leasefile="$W/rtr.leases" --pid-file="$W/rtr.pid" --log-facility="$W/rtr-dnsmasq.log"

# internet-side services
echo "hello-from-internet" >"$W/index.html"
head -c 5000000 /dev/urandom >"$W/blob.bin"; BLOBSUM=$(sha256sum <"$W/blob.bin" | cut -d' ' -f1)
x inet busybox httpd -p 80 -h "$W" &
x inet iperf3 -s -D --pidfile "$W/iperf.pid"
x inet socat -T 5 UDP6-RECVFROM:5353,fork,reuseaddr EXEC:cat &   # dual-stack UDP echo
x inet socat TCP-LISTEN:2222,fork,reuseaddr EXEC:'echo inet-tcp-ok' &
x rtr socat TCP-LISTEN:22,fork,reuseaddr EXEC:'echo router-ssh' &   # stands in for dropbear
sleep 1

# ---------------------------------------------------------------- clients
for c in c1 c2 g1 i1; do
	x $c env LEASE_DIR="$W/lease" busybox udhcpc -i eth0 -s "$HERE/udhcpc.script" -n -q -t 10 -T 1 >/dev/null 2>&1
done
ip_of() { sed -n 's/^ip=//p' "$W/lease/eth0.lease.$1" 2>/dev/null; }
# udhcpc writes eth0.lease for every client into the same dir; re-read per ns
for c in c1 c2 g1 i1; do x $c ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1 >"$W/$c.ip"; done
echo "--- diag"; for n in rtr c1 isp inet; do echo "[$n]"; x $n ip route; x $n ip -6 route | grep -v fe80; done; x rtr sysctl net.ipv4.ip_forward
C1=$(cat "$W/c1.ip"); C2=$(cat "$W/c2.ip"); G1=$(cat "$W/g1.ip"); I1=$(cat "$W/i1.ip")
case "$C1/$C2" in 192.168.1.1[0-9][0-9]/192.168.1.1[0-9][0-9]) res N03 PASS "LAN clients get DHCP leases (VLAN 1)" "c1=$C1 c2=$C2" ;; *) res N03 FAIL "LAN clients get DHCP leases" "c1=$C1 c2=$C2" ;; esac
case "$G1" in 192.168.20.*) res N04 PASS "guest client gets lease in guest VLAN 20" "g1=$G1" ;; *) res N04 FAIL "guest lease" "g1=$G1" ;; esac
case "$I1" in 192.168.30.*) res N05 PASS "IoT client gets lease in IoT VLAN 30" "i1=$I1" ;; *) res N05 FAIL "iot lease" "i1=$I1" ;; esac

out=$(x c1 busybox nslookup example.test 192.168.1.1 2>&1)
echo "$out" | grep -q "198.51.100.10" && res N06 PASS "DNS via router forwarder resolves" "example.test->198.51.100.10" || res N06 FAIL "DNS via router" "$(echo $out | head -c 120)"

x c1 ping -c3 -W1 192.168.1.1 >/dev/null && res N07 PASS "LAN client reaches router" || res N07 FAIL "LAN client reaches router"

before=$(x rtr nft list counter inet fw4 lan_fwd | awk '/packets/{print $2}')
x c1 ping -c5 -i0.2 -W1 "$C2" >/dev/null; okc=$?
after=$(x rtr nft list counter inet fw4 lan_fwd | awk '/packets/{print $2}')
[ $okc -eq 0 ] && [ "$before" = "$after" ] && res N08 PASS "client-to-client switched at L2 (not routed)" "fw4 lan_fwd delta=$((after-before))" \
	|| res N08 FAIL "client-to-client L2" "rc=$okc delta=$((after-before))"

x inet tcpdump -ni up1 -c1 -w "$W/nat.pcap" icmp >/dev/null 2>&1 & TD=$!; sleep 0.5
x c1 ping -c3 -W1 198.51.100.10 >/dev/null; okp=$?
sleep 0.3; kill $TD 2>/dev/null; wait $TD 2>/dev/null
src=$(tcpdump -nr "$W/nat.pcap" 2>/dev/null | awk '{print $3}' | head -1)
[ $okp -eq 0 ] && [ "$src" = "$WANIP" ] && res N09 PASS "LAN->Internet ping NATed to WAN address" "seen src=$src" \
	|| res N09 FAIL "LAN->Internet NAT" "rc=$okp src=$src"

body=$(x c1 busybox wget -q -T 3 -O - http://198.51.100.10/index.html 2>&1)
[ "$body" = "hello-from-internet" ] && res N10 PASS "TCP (HTTP) LAN->Internet" || res N10 FAIL "TCP LAN->Internet" "$body"
u=$(echo udp-probe | x c1 socat -T 2 - UDP4:198.51.100.10:5353 2>&1)
[ "$u" = "udp-probe" ] && res N11 PASS "UDP round trip LAN->Internet through NAT" || res N11 FAIL "UDP through NAT" "$u"

# sustained load + concurrent latency (veth: measures the software path only)
x c1 ping -i 0.05 -c 200 198.51.100.10 >"$W/ping-load.txt" 2>&1 & PP=$!
x c1 iperf3 -c 198.51.100.10 -t 8 -J >"$OUT/iperf3-lan-wan.json" 2>&1; ri=$?
wait $PP
bps=$(python3 -c "import json;d=json.load(open('$OUT/iperf3-lan-wan.json'));print(int(d['end']['sum_received']['bits_per_second']/1e6))" 2>/dev/null)
loss=$(sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p' "$W/ping-load.txt")
[ $ri -eq 0 ] && [ -n "$bps" ] && awk "BEGIN{exit !($loss < 1)}" && res N12 PASS "TCP under load, ping loss <1% (SIMULATED veth)" "${bps} Mbit/s, ping loss ${loss}%" \
	|| res N12 FAIL "TCP under load" "rc=$ri bps=$bps loss=$loss"
x c1 iperf3 -c 198.51.100.10 -u -b 200M -t 5 -J >"$OUT/iperf3-udp-lan-wan.json" 2>&1 \
	&& res N13 PASS "UDP 200 Mbit/s stream completes (SIMULATED)" "$(python3 -c "import json;d=json.load(open('$OUT/iperf3-udp-lan-wan.json'));s=d['end']['sum'];print(f\"loss {s['lost_percent']:.2f}%\")" 2>/dev/null)" \
	|| res N13 FAIL "UDP stream"

# zone isolation
x g1 ping -c2 -W1 198.51.100.10 >/dev/null && res N14 PASS "guest reaches Internet" || res N14 FAIL "guest reaches Internet"
x g1 ping -c2 -W1 "$C1" >/dev/null && res N15 FAIL "guest must not reach LAN client" || res N15 PASS "guest cannot reach LAN client"
r=$(x g1 socat -T 2 - TCP4:192.168.20.1:22,connect-timeout=2 2>&1)
[ "$r" = "router-ssh" ] && res N16 FAIL "guest must not reach router SSH" || res N16 PASS "guest cannot reach router SSH (input REJECT)"
x g1 busybox nslookup example.test 192.168.20.1 2>&1 | grep -q 198.51.100.10 && res N17 PASS "guest DNS allowed" || res N17 FAIL "guest DNS"
x i1 ping -c2 -W1 198.51.100.10 >/dev/null && res N18 FAIL "IoT must not reach Internet" || res N18 PASS "IoT has no Internet"
x i1 ping -c2 -W1 "$C1" >/dev/null && res N19 FAIL "IoT must not reach LAN" || res N19 PASS "IoT cannot initiate to LAN"
x c1 ping -c2 -W1 "$I1" >/dev/null && res N20 PASS "LAN can initiate to IoT" || res N20 FAIL "LAN to IoT"
x i1 ping -c2 -W1 "$G1" >/dev/null && res N21 FAIL "IoT must not reach guest" || res N21 PASS "IoT cannot reach guest"
# VLAN leakage at L2: a frame from the guest port must never be bridged to LAN ports
x c1 tcpdump -ni eth0 -c1 -w "$W/leak.pcap" "ether src $(x g1 cat /sys/class/net/eth0/address)" >/dev/null 2>&1 & TD=$!; sleep 0.5
x g1 arping -c3 -I eth0 192.168.1.1 >/dev/null 2>&1 || x g1 ping -b -c2 -W1 255.255.255.255 >/dev/null 2>&1
sleep 0.5; kill $TD 2>/dev/null; wait $TD 2>/dev/null
n=$(tcpdump -nr "$W/leak.pcap" 2>/dev/null | wc -l)
[ "$n" -eq 0 ] && res N22 PASS "no L2 leakage guest VLAN -> LAN ports" || res N22 FAIL "L2 leakage" "$n frames"

# WAN inbound policy
r=$(x inet socat -T 2 - TCP4:$WANIP:22,connect-timeout=2 2>&1)
[ "$r" = "router-ssh" ] && res N23 FAIL "router SSH must not be reachable from WAN" || res N23 PASS "router SSH blocked from WAN"
x inet ip route add 192.168.1.0/24 via 198.51.100.1 2>/dev/null; x isp ip route add 192.168.1.0/24 via "$WANIP" 2>/dev/null
x inet ping -c2 -W1 "$C1" >/dev/null && res N24 FAIL "unsolicited WAN->LAN must be dropped" || res N24 PASS "unsolicited WAN->LAN forwarding rejected"
x inet ping -c1 -W1 "$WANIP" >/dev/null && res N25 PASS "fw4 Allow-Ping on WAN" || res N25 FAIL "Allow-Ping"

# IPv6 (routed, SLAAC from dnsmasq RA)
sleep 3
C16=$(x c1 ip -6 -o addr show dev eth0 scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
case "$C16" in 2001:db8:1:1:*) res N26 PASS "LAN client SLAAC address from router RA" "$C16" ;; *) res N26 FAIL "SLAAC" "$C16" ;; esac
x c1 ping -6 -c3 -W2 2001:db8:100::10 >/dev/null && res N27 PASS "IPv6 LAN->Internet routed" || res N27 FAIL "IPv6 routing"
[ -n "$C16" ] && { u=$(echo v6probe | x c1 socat -T 2 - UDP6:[2001:db8:100::10]:5353 2>&1); [ "$u" = v6probe ] && res N28 PASS "IPv6 UDP round trip" || res N28 FAIL "IPv6 UDP" "$u"; }
r=$(x inet socat -T 2 - "TCP6:[2001:db8:1:1::1]:22,connect-timeout=2" 2>&1)
[ "$r" = "router-ssh" ] && res N29 FAIL "router SSH must be blocked from WAN (v6)" || res N29 PASS "router SSH blocked from WAN (IPv6)"

# flow offload: established flows hit the software flowtable
x rtr nft list flowtable inet fw4 ft >/dev/null 2>&1 && {
	x c1 busybox wget -q -T 5 -O /dev/null http://198.51.100.10/blob.bin
	n=$(x rtr conntrack -L 2>/dev/null | grep -c OFFLOAD)
	res N30 INFO "software flow offload flowtable present" "conntrack OFFLOAD entries now=$n"
	PASS=$((PASS+0)); FAIL=$((FAIL-1))
}

# congestion + loss on the uplink: transfer must still complete intact
x isp tc qdisc add dev wanp root netem delay 40ms 10ms loss 5%
got=$(x c1 busybox wget -q -T 60 -O - http://198.51.100.10/blob.bin | sha256sum | cut -d' ' -f1)
pl=$(x c1 ping -c 100 -i 0.02 -W1 198.51.100.10 2>/dev/null | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p')
[ "$got" = "$BLOBSUM" ] && res N31 PASS "5 MB TCP transfer intact over 5% loss/40ms uplink (SIMULATED)" "ping loss ${pl}%" \
	|| res N31 FAIL "transfer under loss" "sha mismatch"
x isp tc qdisc del dev wanp root
# SQM/CAKE shaping on WAN egress (functional check only)
if x rtr tc qdisc add dev wan root cake bandwidth 50mbit 2>/dev/null; then
	x c1 iperf3 -c 198.51.100.10 -t 5 -J >"$OUT/iperf3-cake.json" 2>&1
	bc=$(python3 -c "import json;d=json.load(open('$OUT/iperf3-cake.json'));print(int(d['end']['sum_received']['bits_per_second']/1e6))" 2>/dev/null)
	[ -n "$bc" ] && [ "$bc" -le 55 ] && res N32 PASS "CAKE 50 Mbit/s egress shaper enforces rate (SIMULATED)" "${bc} Mbit/s" || res N32 FAIL "CAKE shaping" "$bc"
	x rtr tc qdisc del dev wan root
else res N32 FAIL "CAKE qdisc unavailable"; fi

# failover: primary WAN carrier loss -> secondary default route
x isp ip link set wanp down; sleep 1
x rtr conntrack -F >/dev/null 2>&1
echo "--- failover diag"; x rtr ip link show wan; x rtr ip route; x rtr ip route get 198.51.100.10; x rtr sysctl net.ipv4.conf.all.ignore_routes_with_linkdown net.ipv4.conf.wan.ignore_routes_with_linkdown
t0=$(date +%s%N); ok=1
for i in $(seq 1 20); do x c1 ping -c1 -W1 198.51.100.10 >/dev/null && { ok=0; break; }; done
t1=$(date +%s%N)
x inet tcpdump -ni up2 -c1 -w "$W/fo.pcap" icmp >/dev/null 2>&1 & TD=$!; sleep 0.5
x c1 ping -c2 -W1 198.51.100.10 >/dev/null; sleep 0.3; kill $TD 2>/dev/null; wait $TD 2>/dev/null
src=$(tcpdump -nr "$W/fo.pcap" 2>/dev/null | awk '{print $3}' | head -1)
[ $ok -eq 0 ] && [ "$src" = "192.0.2.2" ] && res N33 PASS "failover to wan2 on primary carrier loss (kernel linkdown routes, SIMULATED)" "$(( (t1-t0)/1000000 )) ms, src=$src" \
	|| res N33 FAIL "failover" "ok=$ok src=$src"
x isp ip link set wanp up; sleep 1
x c1 ping -c2 -W1 198.51.100.10 >/dev/null && res N34 PASS "traffic resumes after primary WAN returns" || res N34 FAIL "recovery after WAN return"

x rtr nft list ruleset >"$OUT/ruleset-as-loaded.nft"
cp "$W"/*dnsmasq.log "$OUT/" 2>/dev/null
echo "pass=$PASS fail=$FAIL" >>"$RES"
printf 'SUMMARY pass=%s fail=%s (SIMULATION ONLY)\n' "$PASS" "$FAIL" >&3
[ "$FAIL" -eq 0 ]
