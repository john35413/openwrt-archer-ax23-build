#!/usr/bin/env bash
# Twin debug probe: guest/IoT DHCP ranges in dnsmasq
OUT="$1"; KEY="$2"; HERE="$(cd "$(dirname "$0")" && pwd)"
x() { local n=$1; shift; ip netns exec "$n" "$@"; }
ifmac() { for d in /sys/class/net/*; do [ "$(cat "$d/address")" = "$1" ] && { basename "$d"; return; }; done; }
ip netns add c1; x c1 ip link set lo up; ip link set "$(ifmac 52:54:00:aa:00:01)" netns c1 name eth0; x c1 ip link set eth0 up
mkdir -p /tmp/l; for i in $(seq 1 120); do x c1 env LEASE_DIR=/tmp/l busybox udhcpc -i eth0 -s "$HERE/../network/udhcpc.script" -n -q -t 4 -T 2 >/dev/null 2>&1 && break; sleep 3; done
SSHO=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR -o BatchMode=yes)
R() { x c1 ssh "${SSHO[@]}" root@192.168.1.1 "$@"; }
for i in $(seq 1 40); do R true 2>/dev/null && break; sleep 3; done; sleep 60
{
echo "=== dhcp config"; R 'uci show dhcp | grep -E "guest|iot|\.lan"'
echo "=== ifstatus guest/iot"; R 'ifstatus guest | head -20; ifstatus iot | grep -E "\"up\"|address"'
echo "=== dnsmasq dhcp-range lines BEFORE reload"; R 'grep -h "dhcp-range" /var/etc/dnsmasq.conf.*'
echo "=== logread dnsmasq/procd"; R 'logread | grep -iE "dnsmasq|procd.*trigger" | grep -v "using only" | tail -20'
R '/etc/init.d/dnsmasq reload; sleep 5'
echo "=== dnsmasq dhcp-range lines AFTER reload"; R 'grep -h "dhcp-range" /var/etc/dnsmasq.conf.*'
echo "=== service triggers"; R 'ubus call service list "{\"name\":\"dnsmasq\",\"verbose\":true}" | grep -A3 -iE "trigger|interface" | head -40'
} > "$OUT/debug-probe.txt" 2>&1
