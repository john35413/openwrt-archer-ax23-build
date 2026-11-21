#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Runs on a PC/Raspberry Pi connected to the RAM-booted AX23 v2. Measures, it
# does not assume. Results -> results-<ts>/ (raw iperf3 JSON + summary.tsv).
#
#   pc-traffic-tests.sh --mode lan-wan  --server <iperf3 host BEHIND the WAN port>
#   pc-traffic-tests.sh --mode lan-lan  --server <second client on another LAN port>
#   pc-traffic-tests.sh --mode wifi     --server <wired host>   (run on a Wi-Fi client)
#   pc-traffic-tests.sh --mode trunk-gaps --server <host across the router>
#
# lan-lan measures switch-local forwarding (client-to-client, should not touch
# the CPU); lan-wan measures routing+NAT through the 2.5G trunk and the CPU.
# trunk-gaps sends 100 pings/s for 10 min and reports loss bursts; a burst
# every ~10 s would implicate the 777-08 SerDes health-check park (20 ms).
set -euo pipefail
MODE=""; SRV=""; DUR=30; ROUTER=192.168.1.1
while [ $# -gt 0 ]; do case "$1" in
	--mode) MODE="$2"; shift 2 ;; --server) SRV="$2"; shift 2 ;;
	--duration) DUR="$2"; shift 2 ;; --router) ROUTER="$2"; shift 2 ;;
	*) echo "bad arg $1"; exit 2 ;; esac; done
[ -n "$MODE" ] && [ -n "$SRV" ] || { sed -n '3,16p' "$0"; exit 2; }
OUT="results-$MODE-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"; S="$OUT/summary.tsv"
rec() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" | tee -a "$S"; }
mbps() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));e=d['end'];k='sum_received' if 'sum_received' in e else 'sum';print(round(e[k]['bits_per_second']/1e6,1))" "$1"; }

ping -c 5 -W 1 "$ROUTER" >/dev/null && rec P01 PASS "router reachable" "$ROUTER" || rec P01 FAIL "router reachable" "$ROUTER"
case "$MODE" in
lan-wan|lan-lan|wifi)
	for dir in "" "-R"; do
		tag=$([ -z "$dir" ] && echo up || echo down)
		iperf3 -c "$SRV" -t "$DUR" $dir -J >"$OUT/tcp1-$tag.json" && rec T-$tag PASS "TCP 1 stream $tag" "$(mbps "$OUT/tcp1-$tag.json") Mbit/s" || rec T-$tag FAIL "TCP $tag" "iperf3 error"
		iperf3 -c "$SRV" -t "$DUR" -P 4 $dir -J >"$OUT/tcp4-$tag.json" && rec T4-$tag PASS "TCP 4 streams $tag" "$(mbps "$OUT/tcp4-$tag.json") Mbit/s" || rec T4-$tag FAIL "TCP x4 $tag" "iperf3 error"
	done
	iperf3 -c "$SRV" -u -b 300M -t 15 -J >"$OUT/udp.json" && rec U1 INFO "UDP 300M offered" \
		"$(python3 -c "import json;s=json.load(open('$OUT/udp.json'))['end']['sum'];print(f\"{s['bits_per_second']/1e6:.0f} Mbit/s loss {s['lost_percent']:.2f}% jitter {s['jitter_ms']:.2f} ms\")")"
	ping -c 100 -i 0.2 "$SRV" >"$OUT/ping-idle.txt"; rec L1 INFO "idle latency" "$(tail -1 "$OUT/ping-idle.txt")"
	( iperf3 -c "$SRV" -t 20 -P 4 >/dev/null 2>&1 & ); ping -c 80 -i 0.25 "$SRV" >"$OUT/ping-load.txt"
	rec L2 INFO "latency under load (bufferbloat)" "$(tail -1 "$OUT/ping-load.txt"); $(grep -o '[0-9.]*% packet loss' "$OUT/ping-load.txt")"
	;;
trunk-gaps)
	ping -D -i 0.01 -W 1 -c 60000 "$SRV" >"$OUT/ping-10min.txt" 2>&1 || true
	python3 - "$OUT/ping-10min.txt" <<'PY' | tee -a "$S"
import re,sys
seqs=[int(m.group(1)) for m in re.finditer(r"icmp_seq=(\d+)", open(sys.argv[1]).read())]
got=set(seqs); top=max(seqs) if seqs else 0
lost=[s for s in range(1,top+1) if s not in got]
bursts=[]; start=None; prev=None
for s in lost:
    if prev is None or s!=prev+1: 
        if start is not None: bursts.append((start,prev))
        start=s
    prev=s
if start is not None: bursts.append((start,prev))
gaps=[round((b[0]-a[0])*0.01,1) for a,b in zip(bursts,bursts[1:])]
periodic=sum(1 for g in gaps if 9<=g<=11)
st="FAIL" if periodic>=3 else "PASS"
print(f"G1\t{st}\ttrunk loss bursts (10 s periodicity => 777-08 park)\t{len(lost)} lost of {top}, {len(bursts)} bursts, {periodic} gaps of ~10 s")
PY
	;;
*) echo "unknown mode"; exit 2 ;;
esac
echo "results in $OUT"
