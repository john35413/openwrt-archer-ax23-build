#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline, read-only inspector for a raw dump of 0:APPSBLENV.

On the router (RAM-booted OpenWrt), dump the partition through the
read-only character device and copy it off the device:
    cat /dev/mtd7ro > /tmp/appsblenv.bin     # mtd7 = "0:APPSBLENV" per /proc/mtd
Then on the PC:
    ubootenv.py appsblenv.bin

It tries every plausible env size (and redundant-env layout) and reports
which one has a valid CRC32, plus the variables relevant to A/B boot
(tp_boot_idx, bootcmd, bootdelay). It never writes anything. A "no valid
CRC" result means U-Boot is running its built-in default environment (as
observed in a UART log of an AX21 v5 running AX23 v2 U-Boot) and that a
naive `fw_setenv` would REPLACE that default environment.
"""
import argparse
import binascii
import json
import struct
import sys

SIZES = [0x2000, 0x4000, 0x8000, 0x10000, 0x20000, 0x40000, 0x80000]
INTEREST = ("tp_boot_idx", "bootcmd", "bootdelay", "bootargs", "ipaddr", "serverip",
            "bootfile", "machid", "fdt_high")


def parse_vars(blob):
    out = {}
    for item in blob.split(b"\0"):
        if not item:
            break
        k, _, v = item.partition(b"=")
        out[k.decode("latin-1")] = v.decode("latin-1")
    return out


def analyse(data):
    results = []
    for size in SIZES:
        if size > len(data):
            continue
        # single env: crc32 (4) + data
        crc = struct.unpack_from("<I", data, 0)[0]
        ok = binascii.crc32(data[4:size]) & 0xffffffff == crc
        results.append({"layout": "single", "size": size, "crc_ok": ok,
                        "vars": parse_vars(data[4:size]) if ok else None})
        # redundant env: crc32 (4) + flags (1) + data
        ok_r = binascii.crc32(data[5:size]) & 0xffffffff == crc
        if ok_r:
            results.append({"layout": "redundant", "size": size, "crc_ok": True,
                            "flags": data[4], "vars": parse_vars(data[5:size])})
    return results


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dump")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    data = open(a.dump, "rb").read()
    res = analyse(data)
    valid = [r for r in res if r["crc_ok"]]
    erased = data[:64] == b"\xff" * 64
    summary = {"dump_bytes": len(data), "erased_header": erased,
               "valid": [{k: v for k, v in r.items() if k != "vars"} for r in valid],
               "variables": {k: valid[0]["vars"].get(k) for k in INTEREST} if valid else None}
    if a.json:
        print(json.dumps(summary, indent=1))
    else:
        print(f"dump: {len(data)} bytes, header erased (0xff): {erased}")
        if not valid:
            print("RESULT: NO valid environment CRC at any candidate size.")
            print("        U-Boot uses its built-in defaults; fw_setenv would replace them.")
        for r in valid:
            print(f"RESULT: valid {r['layout']} env, size {r['size']:#x}")
            for k in INTEREST:
                if k in r["vars"]:
                    print(f"   {k}={r['vars'][k]}")
    return 0 if valid else 2


if __name__ == "__main__":
    sys.exit(main())
