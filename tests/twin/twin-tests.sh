#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Runs INSIDE the helper VM started by run-twin.sh. Args: OUTDIR SSH_KEY
# DIGITAL TWIN / SIMULATION ONLY - see run-twin.sh for what is not emulated.
set -uo pipefail
OUT="$1"; KEY="$2"; HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$OUT/results.tsv"; : >"$RES"
W=$(mktemp -d /tmp/twin.XXXX)
PASS=0; FAIL=0
res() {
	printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$RES"
	printf '%-4s %-4s %s %s\n' "$1" "$2" "$3" "${4:-}"
	case "$2" in PASS) PASS=$((PASS+1)) ;; FAIL) FAIL=$((FAIL+1)) ;; esac
}
x() { local n=$1; shift; ip netns exec "$n" "$@"; }
for m in veth sch_netem; do modprobe "$m" 2>/dev/null; done
ifmac() { for d in /sys/class/net/*; do [ "$(cat "$d/address")" = "$1" ] && { basename "$d"; return; }; done; }
for n in isp inet c1 c2 c3; do ip netns add $n; x $n ip link set lo up; done
# cables: aa:00:00 <-> wan, :01 <-> lan1, :02 <-> lan2, :03 <-> lan3
ip link set "$(ifmac 52:54:00:aa:00:00)" netns isp name wanp
ip link set "$(ifmac 52:54:00:aa:00:01)" netns c1 name eth0
ip link set "$(ifmac 52:54:00:aa:00:02)" netns c2 name eth0
ip link set "$(ifmac 52:54:00:aa:00:03)" netns c3 name eth0
x isp ip link set wanp up
for n in c1 c2 c3; do x $n ip link set eth0 up; done
ip link add up1 netns inet type veth peer name dn netns isp
x inet ip link set up1 up; x isp ip link set dn up
x inet ip addr add 93.184.215.10/24 dev up1; x inet ip route add default via 93.184.215.1
x inet ip -6 addr add 2001:db8:100::10/64 dev up1 nodad; x inet ip -6 route add default via 2001:db8:100::1 dev up1
x isp ip addr add 93.184.215.1/24 dev dn; x isp ip addr add 203.0.113.1/24 dev wanp
x isp ip -6 addr add 2001:db8:100::1/64 dev dn nodad; x isp ip -6 addr add 2001:db8:ffff::1/64 dev wanp nodad
x isp sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1
x isp dnsmasq --conf-file=/dev/null --interface=wanp --bind-interfaces --except-interface=lo \
	--dhcp-range=203.0.113.100,203.0.113.150,255.255.255.0,1h --dhcp-option=3,203.0.113.1 --dhcp-option=6,203.0.113.1 \
	--enable-ra --dhcp-range=2001:db8:ffff::,ra-only,64,1h \
	--no-resolv --no-hosts --address=/inet.example.net/93.184.215.10 --address=/inet.example.net/2001:db8:100::10 \
	--log-queries --dhcp-leasefile="$W/isp.leases" --pid-file="$W/isp.pid" --log-facility="$OUT/isp-dnsmasq.log"
echo hello-from-internet >"$W/index.html"; head -c 3000000 /dev/urandom >"$W/blob.bin"; BLOB=$(sha256sum <"$W/blob.bin" | cut -d' ' -f1)
x inet busybox httpd -p 80 -h "$W" &
x inet iperf3 -s -D --pidfile "$W/iperf.pid"
x inet socat UDP4-RECVFROM:5353,fork,reuseaddr EXEC:cat &
x inet socat TCP-LISTEN:2222,fork,reuseaddr EXEC:'echo inet-ok' &
x c2 iperf3 -s -D --pidfile "$W/iperf-c2.pid"
mkdir -p "$W/l"
dhcp() { x "$1" env LEASE_DIR="$W/l" busybox udhcpc -i eth0 -s "$HERE/../network/udhcpc.script" -n -q -t 4 -T 2 >/dev/null 2>&1; }
ipof() { x "$1" ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1 | head -1; }

# NOTE: the simulated Internet uses 93.184.215.0/24 (only inside these isolated
# VMs). Documentation nets (192.0.2/24, 198.51.100/24, 203.0.113/24) are treated
# as private by dnsmasq's DNS-rebind protection, so answers pointing there are
# (correctly) refused by the router.
# ------------------------------------------------------------ boot
t0=$(date +%s); up=0
for _ in $(seq 1 120); do dhcp c1 && { up=1; break; }; sleep 3; done
t1=$(date +%s)
[ $up = 1 ] && res T01 PASS "router VM boots; LAN DHCP answers" "$((t1-t0)) s after helper start (TCG emulation)" \
	|| { res T01 FAIL "router boot / LAN DHCP"; echo "SUMMARY pass=$PASS fail=$FAIL"; exit 1; }
SSHO=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR -o BatchMode=yes)
R() { x c1 ssh "${SSHO[@]}" root@192.168.1.1 "$@"; }
for _ in $(seq 1 30); do R true 2>/dev/null && break; sleep 3; done
R true && res T02 PASS "SSH to router from LAN (key auth)" || res T02 FAIL "SSH to router"
R 'uname -a; cat /etc/openwrt_release; free; ip -br link; iw dev; logread | tail -40' >"$OUT/router-state-boot.txt" 2>&1

b=$(R 'ls /sys/class/net/br-lan/brif | sort | tr "\n" " "')
case "$b" in *lan1*lan2*lan3*lan4*) res T03 PASS "AX23 port names; br-lan members" "$b" ;; *) res T03 FAIL "br-lan members" "$b" ;; esac
for _ in $(seq 1 40); do WANIP=$(R 'ifstatus wan | jsonfilter -e "@[\"ipv4-address\"][0].address"' 2>/dev/null); [ -n "$WANIP" ] && break; sleep 3; done
[ -n "$WANIP" ] && res T04 PASS "WAN DHCP lease from ISP" "$WANIP" || res T04 FAIL "WAN DHCP"
sleep 5; v6=$(R 'ip -6 -o addr show dev wan scope global' | awk '{print $4}' | head -1)
case "$v6" in 2001:db8:ffff:*) res T05 PASS "WAN IPv6 (SLAAC/RA via wan6)" "$v6" ;; *) res T05 FAIL "WAN IPv6" "$v6" ;; esac
R 'ping -6 -c2 -W2 2001:db8:100::10' >/dev/null && res T06 PASS "router IPv6 reachability to Internet" || res T06 FAIL "router IPv6 ping"
code=$(x c1 curl -s -o "$OUT/luci-page.html" -w '%{http_code}' --max-time 30 http://192.168.1.1/cgi-bin/luci/)
form=$(grep -c 'name="luci_username"' "$OUT/luci-page.html" 2>/dev/null)
login=$(x c1 curl -s -o /dev/null -w '%{http_code} %header{set-cookie}' --max-time 30 --data 'luci_username=root&luci_password=' http://192.168.1.1/cgi-bin/luci/)
case "$code:$form:$login" in 403:[1-9]*:302*sysauth*) res T07 PASS "LuCI login page served (HTTP 403 = not yet authenticated, by design) and root login yields a session" "login: ${login%% *}" ;;
	*) res T07 FAIL "LuCI" "page=$code form=$form login=${login:0:60}" ;; esac

# ------------------------------------------------------------ wired
dhcp c2; dhcp c3; C1=$(ipof c1); C2=$(ipof c2); C3=$(ipof c3)
case "$C1/$C2/$C3" in 192.168.1.*/192.168.1.*/192.168.1.*) res T08 PASS "DHCP on lan1, lan2, lan3" "$C1 $C2 $C3" ;; *) res T08 FAIL "wired DHCP" "$C1 $C2 $C3" ;; esac
x c1 busybox nslookup inet.example.net 192.168.1.1 2>&1 | grep -q 93.184.215.10 && res T09 PASS "DNS through router dnsmasq" || res T09 FAIL "DNS"
x c1 ping -c3 -W2 "$C2" >/dev/null && res T10 PASS "lan1 <-> lan2 client-to-client" || res T10 FAIL "lan1<->lan2"
x isp tcpdump -ni dn -c1 -w "$W/nat.pcap" icmp >/dev/null 2>&1 & TD=$!; sleep 1
x c1 ping -c3 -W2 93.184.215.10 >/dev/null; ok=$?; sleep 0.5; kill $TD 2>/dev/null; wait $TD 2>/dev/null
src=$(tcpdump -nr "$W/nat.pcap" 2>/dev/null | awk '{print $3}' | head -1)
[ $ok = 0 ] && [ "$src" = "$WANIP" ] && res T11 PASS "LAN -> Internet NAT" "src=$src" || res T11 FAIL "NAT" "ok=$ok src=$src"
[ "$(x c1 busybox wget -q -T 10 -O - http://93.184.215.10/index.html)" = hello-from-internet ] && res T12 PASS "TCP (HTTP) through NAT" || res T12 FAIL "TCP NAT"
[ "$(echo u | x c1 socat -T 3 - UDP4:93.184.215.10:5353)" = u ] && res T13 PASS "UDP through NAT" || res T13 FAIL "UDP NAT"
got=$(x c1 busybox wget -q -T 60 -O - http://93.184.215.10/blob.bin | sha256sum | cut -d' ' -f1)
[ "$got" = "$BLOB" ] && res T14 PASS "3 MB download intact through router" || res T14 FAIL "download integrity"
x c1 iperf3 -c 93.184.215.10 -t 10 -J >"$OUT/iperf-wired-nat.json" 2>&1 && \
	res T15 PASS "iperf3 LAN->WAN through NAT (TCG-emulated CPU)" "$(python3 -c "import json;print(int(json.load(open('$OUT/iperf-wired-nat.json'))['end']['sum_received']['bits_per_second']/1e6))") Mbit/s" || res T15 FAIL "iperf3 NAT"
x c1 iperf3 -c "$C2" -t 10 -J >"$OUT/iperf-wired-lanlan.json" 2>&1 && \
	res T16 PASS "iperf3 lan1->lan2 (software bridge here; switch ASIC on the AX23)" "$(python3 -c "import json;print(int(json.load(open('$OUT/iperf-wired-lanlan.json'))['end']['sum_received']['bits_per_second']/1e6))") Mbit/s" || res T16 FAIL "iperf3 LAN-LAN"
r=$(x inet socat -T 3 - "TCP4:$WANIP:22,connect-timeout=3" 2>&1 | head -c 40)
case "$r" in SSH-*) res T17 FAIL "SSH reachable from WAN" ;; *) res T17 PASS "router SSH not reachable from WAN" ;; esac
r=$(x inet socat -T 3 - "TCP4:$WANIP:80,connect-timeout=3" 2>&1 | head -c 40)
x inet busybox wget -q -T 5 -O /dev/null "http://$WANIP/" 2>/dev/null && res T18 FAIL "LuCI reachable from WAN" || res T18 PASS "LuCI not reachable from WAN"

# ------------------------------------------------------------ Wi-Fi (mac80211_hwsim)
for _ in $(seq 1 40); do n=$(R 'ubus call network.wireless status' 2>/dev/null | grep -c '"up": true'); [ "$n" -ge 2 ] && break; sleep 3; done
[ "${n:-0}" -ge 2 ] && res W01 PASS "both radios up under netifd/hostapd" "radio0 (2.4G) + radio1 (5G)" || res W01 FAIL "radios up" "$n"
R 'iw dev' >"$OUT/router-iw-dev.txt" 2>&1
R "logread | grep -iE 'hostapd|wifi-scripts|country|regdom|nl80211|wpa'" >"$OUT/router-logread-wifi.txt" 2>&1
R 'iw reg get' >"$OUT/router-reg.txt" 2>&1; grep -q "country DE" "$OUT/router-reg.txt" && res W02 PASS "regulatory domain DE (EU) applied" || res W02 FAIL "regdomain" "$(head -2 "$OUT/router-reg.txt" | tr '\n' ' ')"
c2g=$(R 'iw dev phy0-ap0 info' | grep -o "channel [0-9]* ([0-9]* MHz), width: [0-9]* MHz"); c5g=$(R 'iw dev phy1-ap0 info' | grep -o "channel [0-9]* ([0-9]* MHz), width: [0-9]* MHz")
case "$c2g|$c5g" in "channel 6 "*"width: 20 MHz|channel 36 "*"width: 80 MHz") res W03 PASS "AP channels/widths" "$c2g ; $c5g" ;; *) res W03 FAIL "AP channels" "$c2g ; $c5g" ;; esac
ssids=$(R 'iw dev' | awk '/ssid/{print $2}' | sort | tr '\n' ' ')
case "$ssids" in *AX23-2G*AX23-5G*CHANGE-ME-guest*CHANGE-ME-iot*) res W04 PASS "4 SSIDs broadcast (main 2G/5G, guest, IoT)" "$ssids" ;; *) res W04 FAIL "SSIDs" "$ssids" ;; esac

# station helper on the router: move a spare hwsim phy into its own netns
R 'cat > /tmp/sta-dhcp.sh <<"EOS"
#!/bin/sh
case "$1" in bound|renew) ip -4 addr flush dev "$interface"; ip addr add "$ip/${mask:-24}" dev "$interface"; [ -n "$router" ] && ip route replace default via "${router%% *}" dev "$interface" ;; deconfig) ip -4 addr flush dev "$interface"; ip link set "$interface" up ;; esac
EOS
chmod +x /tmp/sta-dhcp.sh
for p in phy2 phy3; do ip netns add sta-$p 2>/dev/null; iw phy $p set netns name sta-$p; done; sleep 1
for p in phy2 phy3; do ip netns exec sta-$p ip link set lo up; done'
STA() {	# STA phyN ssid keymgmt psk -> prints ip or empty
	local p=$1 ssid=$2 km=$3 psk=$4 extra=""
	[ "$km" = SAE ] && extra="ieee80211w=2"
	R "ns=sta-$p; i=\$(ip netns exec \$ns iw dev | awk '/Interface/{print \$2}' | head -1)
	   [ -n \"\$i\" ] || { ip netns exec \$ns iw phy $p interface add sta-$p type managed; i=sta-$p; }
	   ip netns exec \$ns sh -c 'kill \$(cat /tmp/wpa-$p.pid 2>/dev/null) 2>/dev/null'; sleep 1
	   printf 'ctrl_interface=/var/run/wpa-$p\nnetwork={\n ssid=\"$ssid\"\n key_mgmt=$km\n psk=\"$psk\"\n $extra\n scan_ssid=1\n}\n' > /tmp/wpa-$p.conf
	   ip netns exec \$ns ip link set \$i up
	   ip netns exec \$ns wpa_supplicant -B -i \$i -c /tmp/wpa-$p.conf -P /tmp/wpa-$p.pid >/dev/null 2>&1
	   for k in \$(seq 1 40); do ip netns exec \$ns iw dev \$i link | grep -q 'Connected' && break; sleep 1; done
	   ip netns exec \$ns udhcpc -i \$i -s /tmp/sta-dhcp.sh -n -q -t 6 -T 2 >/dev/null 2>&1
	   ip netns exec \$ns ip -4 -o addr show dev \$i | awk '{print \$4}' | cut -d/ -f1"
}
SX() { local p=$1; shift; R "ip netns exec sta-$p $*"; }
STAD() {	# STA with diagnostics saved on failure: STAD label phy ssid km psk
	local label=$1; shift; local ip; ip=$(STA "$@")
	if [ -z "$ip" ]; then
		{ echo "== $label: STA $*"; R "ip netns exec sta-$1 wpa_cli -p /var/run/wpa-$1 status; ip netns exec sta-$1 iw dev; cat /tmp/wpa-$1.conf; iw dev | grep -E 'Interface|ssid'; logread | grep -iE 'hostapd|wpa|$2|dnsmasq-dhcp' | tail -25"; } >>"$OUT/sta-diagnostics.txt" 2>&1
	fi
	echo "$ip"
}

S2=$(STA phy2 AX23-2G WPA-PSK twin-test-wpa2)
case "$S2" in 192.168.1.*) res W05 PASS "2.4 GHz WPA2-PSK client associates + DHCP" "$S2" ;; *) res W05 FAIL "2.4G WPA2 assoc/DHCP" "$S2" ;; esac
S5=$(STA phy3 AX23-5G SAE twin-test-wpa3)
case "$S5" in 192.168.1.*) res W06 PASS "5 GHz WPA3-SAE (PMF required) client associates + DHCP" "$S5" ;; *) res W06 FAIL "5G WPA3 assoc/DHCP" "$S5" ;; esac
km=$(SX phy3 wpa_cli -p /var/run/wpa-phy3 status 2>/dev/null | sed -n 's/^key_mgmt=//p')
[ "$km" = SAE ] && res W07 PASS "5 GHz link uses SAE (WPA3)" "key_mgmt=$km" || res W07 FAIL "SAE" "$km"
he=$(R 'for i in phy0-ap0 phy1-ap0; do hostapd_cli -i $i all_sta; done' | grep -c "\[HE\]")
[ "$he" -ge 2 ] && res W08 PASS "both clients associated with 802.11ax (HE) capabilities" "$he HE stations" || res W08 FAIL "802.11ax association" "$he"
w2=$(R 'iw dev phy0-ap0 station dump' | grep -m1 "tx bitrate" | sed 's/^\s*//'); w5=$(R 'iw dev phy1-ap0 station dump' | grep -m1 "tx bitrate" | sed 's/^\s*//')
res W09 INFO "station rates reported by hwsim (not RF)" "2G: $w2 | 5G: $w5"
SX phy2 ping -c3 -W2 192.168.1.1 >/dev/null && SX phy3 ping -c3 -W2 192.168.1.1 >/dev/null && res W10 PASS "Wi-Fi clients reach router (both bands)" || res W10 FAIL "Wi-Fi -> router"
SX phy2 ping -c3 -W3 93.184.215.10 >/dev/null && SX phy3 ping -c3 -W3 93.184.215.10 >/dev/null && res W11 PASS "Wi-Fi clients reach Internet via NAT (both bands)" || res W11 FAIL "Wi-Fi -> Internet"
[ "$(SX phy3 wget -q -T 10 -O - http://93.184.215.10/index.html)" = hello-from-internet ] && res W12 PASS "HTTP over 5 GHz Wi-Fi" || res W12 FAIL "HTTP over Wi-Fi"
SX phy2 ping -c3 -W2 "$C1" >/dev/null && x c1 ping -c3 -W2 "$S5" >/dev/null && res W13 PASS "Wi-Fi <-> wired LAN both directions" || res W13 FAIL "Wi-Fi <-> LAN"
x c1 busybox nslookup inet.example.net 192.168.1.1 >/dev/null 2>&1; d=$(SX phy3 nslookup inet.example.net 192.168.1.1 2>&1 | grep -c 93.184.215.10)
[ "$d" -ge 1 ] && res W14 PASS "DNS for Wi-Fi clients" || res W14 FAIL "Wi-Fi DNS"
# simultaneous dual-band traffic
R "ip netns exec sta-phy2 ping -c 30 -i 1 93.184.215.10 > /tmp/p2.txt 2>&1 & ip netns exec sta-phy3 ping -c 30 -i 1 93.184.215.10 > /tmp/p5.txt 2>&1 & wait"
R "cat /tmp/p2.txt /tmp/p5.txt" >"$OUT/dualband-ping.txt" 2>&1
l2=$(R "sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p' /tmp/p2.txt"); l5=$(R "sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p' /tmp/p5.txt")
[ "$l2" = 0 ] && [ "$l5" = 0 ] && res W15 PASS "simultaneous dual-band traffic, 0% loss" "2G loss $l2% / 5G loss $l5% (30 pings each, concurrent)" || res W15 FAIL "dual-band concurrent" "2G $l2% 5G $l5%"
for b in phy2:2.4G phy3:5G; do p=${b%%:*}; n=${b##*:}
	SX $p iperf3 -c 93.184.215.10 -t 8 -J >"$OUT/iperf-wifi-$n.json" 2>&1 && \
		res W16 PASS "iperf3 over $n Wi-Fi to Internet (hwsim+TCG, NOT RF)" "$(python3 -c "import json;print(round(json.load(open('$OUT/iperf-wifi-$n.json'))['end']['sum_received']['bits_per_second']/1e6,1))") Mbit/s" \
		|| res W16 FAIL "iperf3 over $n Wi-Fi"
done
# negative security tests
bad=$(STA phy3 AX23-5G SAE wrong-password-123)
[ -z "$bad" ] && res W17 PASS "WPA3 rejects a wrong password" || res W17 FAIL "WPA3 accepted wrong password" "$bad"
bad=$(STA phy3 AX23-5G WPA-PSK twin-test-wpa3)
[ -z "$bad" ] && res W18 PASS "WPA2-PSK client cannot join the SAE-only 5 GHz SSID" || res W18 FAIL "SAE-only SSID accepted WPA2" "$bad"
# reconnect stability (SAE)
S5=$(STA phy3 AX23-5G SAE twin-test-wpa3); okc=0; t0=$(date +%s)
for _ in $(seq 1 20); do
	r=$(R "ip netns exec sta-phy3 wpa_cli -p /var/run/wpa-phy3 disconnect >/dev/null; sleep 1; ip netns exec sta-phy3 wpa_cli -p /var/run/wpa-phy3 reconnect >/dev/null
	       for j in \$(seq 1 30); do ip netns exec sta-phy3 wpa_cli -p /var/run/wpa-phy3 status | grep -q wpa_state=COMPLETED && break; sleep 1; done
	       ip netns exec sta-phy3 ping -c1 -W3 192.168.1.1 >/dev/null && echo ok")
	[ "$r" = ok ] && okc=$((okc+1))
done
[ $okc = 20 ] && res W19 PASS "20/20 WPA3 disconnect/reconnect cycles with traffic" "$(( $(date +%s)-t0 )) s total" || res W19 FAIL "reconnects" "$okc/20"
# guest and IoT SSIDs
G=$(STAD guest phy2 CHANGE-ME-guest SAE twin-test-guest)
case "$G" in 192.168.20.*) res W20 PASS "guest SSID (WPA3) -> guest network" "$G" ;; *) res W20 FAIL "guest SSID" "$G" ;; esac
SX phy2 ping -c2 -W3 93.184.215.10 >/dev/null && res W21 PASS "guest Wi-Fi reaches Internet" || res W21 FAIL "guest Internet"
SX phy2 ping -c2 -W2 "$C1" >/dev/null && res W22 FAIL "guest reached wired LAN" || res W22 PASS "guest Wi-Fi isolated from LAN"
r=$(R "command -v nc >/dev/null || { echo NO-NC; exit; }; ip netns exec sta-phy2 sh -c 'echo | nc -w 3 192.168.20.1 22'" 2>&1 | head -c 20)
case "$r" in SSH-*) res W23 FAIL "guest reached router SSH" ;; NO-NC*) res W23 BLOCKED "guest->router SSH check" "no nc in image" ;; *) res W23 PASS "guest Wi-Fi cannot reach router SSH" ;; esac
I=$(STAD iot phy2 CHANGE-ME-iot WPA-PSK twin-test-iot)
case "$I" in 192.168.30.*) res W24 PASS "IoT SSID (WPA2) -> IoT network" "$I" ;; *) res W24 FAIL "IoT SSID" "$I" ;; esac
SX phy2 ping -c2 -W3 93.184.215.10 >/dev/null && res W25 FAIL "IoT reached Internet" || res W25 PASS "IoT Wi-Fi has no Internet"
x c1 ping -c2 -W3 "$I" >/dev/null && res W26 PASS "LAN can reach IoT device (e.g. Pi home automation)" || res W26 FAIL "LAN -> IoT"

# ------------------------------------------------------------ stability / resources
R 'free; cat /proc/meminfo | head -5' >"$OUT/router-mem-after.txt"
ma=$(R "awk '/MemAvailable/{print \$2}' /proc/meminfo")
res S01 INFO "router MemAvailable with 4 SSIDs + 2 clients (200 MiB VM; hwsim, not ath11k)" "${ma} kB"
c=$(R 'dmesg' | grep -ciE "oops|panic|bug:|oom-kill|segfault")
[ "$c" = 0 ] && res S02 PASS "no kernel oops/panic/OOM/segfault" || res S02 FAIL "kernel errors" "$c"
h=$(R 'pidof hostapd'); [ -n "$h" ] && res S03 PASS "hostapd still running" || res S03 FAIL "hostapd died"
# 3-minute mixed load: wired NAT + both Wi-Fi bands, router must stay responsive
S5=$(STA phy3 AX23-5G SAE twin-test-wpa3); S2=$(STA phy2 AX23-2G WPA-PSK twin-test-wpa2)
x c1 iperf3 -c 93.184.215.10 -t 180 >/dev/null 2>&1 & IP1=$!
R "ip netns exec sta-phy3 iperf3 -c 93.184.215.10 -t 170 >/dev/null 2>&1 &"
x c2 ping -i 0.5 -c 340 192.168.1.1 >"$W/soak-ping.txt" 2>&1 & PP=$!
wait $IP1; wait $PP
sl=$(sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p' "$W/soak-ping.txt")
SX phy2 ping -c3 -W3 93.184.215.10 >/dev/null && aw=ok || aw=fail
awk "BEGIN{exit !($sl < 1)}" && [ $aw = ok ] && res S04 PASS "3 min mixed wired+Wi-Fi load: router responsive" "LAN ping loss ${sl}%, 2.4G client still online" || res S04 FAIL "3 min load" "loss=$sl wifi=$aw"
# reboot and full recovery
R 'reboot' >/dev/null 2>&1; sleep 20; t0=$(date +%s); back=0
for _ in $(seq 1 120); do dhcp c1 && R true 2>/dev/null && { back=1; break; }; sleep 3; done
for _ in $(seq 1 40); do n=$(R 'ubus call network.wireless status' 2>/dev/null | grep -c '"up": true'); [ "${n:-0}" -ge 2 ] && break; sleep 3; done
[ $back = 1 ] && [ "${n:-0}" -ge 2 ] && R 'ping -c2 -W2 93.184.215.10' >/dev/null && res S05 PASS "reboot: LAN, WAN and both radios come back" "$(( $(date +%s)-t0 )) s" || res S05 FAIL "recovery after reboot" "back=$back radios=$n"
R 'logread' >"$OUT/router-logread-final.txt" 2>&1; R 'dmesg' >"$OUT/router-dmesg-final.txt" 2>&1
echo "pass=$PASS fail=$FAIL" >>"$RES"
echo "SUMMARY pass=$PASS fail=$FAIL (DIGITAL TWIN - software stack only)"
[ $FAIL -eq 0 ]
