#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Runs on the Raspberry Pi. Polls the router's ubus JSON-RPC (LAN only) with
the read-only pi-monitor account, prints one JSON line per poll (feed it to
your logger/Prometheus textfile/Home Assistant) and sends ntfy alerts on state
changes. Stdlib only.

  AX23_URL=http://192.168.1.1/ubus AX23_PASS_FILE=~/.config/ax23/rpc.pass \
  NTFY_URL=http://localhost:8080/router ./ax23-monitor.py
"""
import json
import os
import sys
import time
import urllib.request

URL = os.environ.get("AX23_URL", "http://192.168.1.1/ubus")
USER = os.environ.get("AX23_USER", "pi-monitor")
PASSF = os.path.expanduser(os.environ.get("AX23_PASS_FILE", "~/.config/ax23/rpc.pass"))
NTFY = os.environ.get("NTFY_URL", "")
INTERVAL = int(os.environ.get("AX23_INTERVAL", "60"))
MEM_ALERT_KB = int(os.environ.get("AX23_MEM_ALERT_KB", str(40 * 1024)))
NULL_SID = "00000000000000000000000000000000"


def rpc(sid, obj, method, args=None):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "call",
                       "params": [sid, obj, method, args or {}]}).encode()
    req = urllib.request.Request(URL, body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        res = json.load(r).get("result", [1])
    if res[0] != 0:
        raise RuntimeError(f"ubus {obj}.{method} -> status {res[0]}")
    return res[1] if len(res) > 1 else {}


def login():
    pw = open(PASSF).read().strip()
    return rpc(NULL_SID, "session", "login", {"username": USER, "password": pw})["ubus_rpc_session"]


def notify(msg):
    print(json.dumps({"alert": msg}), file=sys.stderr)
    if NTFY:
        try:
            urllib.request.urlopen(urllib.request.Request(NTFY, msg.encode(), {"Title": "AX23 router"}), timeout=5)
        except OSError as e:
            print(f"ntfy failed: {e}", file=sys.stderr)


def sample(sid):
    info = rpc(sid, "system", "info")
    ifs = {i["interface"]: i for i in rpc(sid, "network.interface", "dump")["interface"]}
    wl = rpc(sid, "network.wireless", "status")
    radios_up = sorted(r for r, v in wl.items() if v.get("up"))
    stations = 0
    for dev in rpc(sid, "iwinfo", "devices").get("devices", []):
        stations += len(rpc(sid, "iwinfo", "assoclist", {"device": dev}).get("results", []))
    return {"ts": int(time.time()), "uptime": info["uptime"],
            "load1": info["load"][0] / 65536, "mem_avail_kb": info["memory"].get("available", 0) // 1024,
            "wan_up": ifs.get("wan", {}).get("up", False), "radios_up": radios_up, "stations": stations}


def main():
    sid, prev = None, {}
    while True:
        try:
            sid = sid or login()
            s = sample(sid)
            print(json.dumps(s), flush=True)
            if prev:
                if prev["wan_up"] and not s["wan_up"]:
                    notify("WAN went down")
                if s["uptime"] < prev["uptime"]:
                    notify(f"router rebooted (uptime {s['uptime']} s)")
                if prev["radios_up"] != s["radios_up"]:
                    notify(f"radios up changed: {prev['radios_up']} -> {s['radios_up']}")
            if s["mem_avail_kb"] < MEM_ALERT_KB and (not prev or prev["mem_avail_kb"] >= MEM_ALERT_KB):
                notify(f"low memory: {s['mem_avail_kb']} kB available")
            prev = s
        except (OSError, RuntimeError, KeyError) as e:
            print(json.dumps({"error": str(e)}), file=sys.stderr, flush=True)
            sid = None
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
