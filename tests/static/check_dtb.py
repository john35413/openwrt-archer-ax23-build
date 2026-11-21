#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Static checks on the decompiled AX23 v2 DTB (dtc -I dtb -O dts output).

Usage: check_dtb.py FILE.dts [--json]
Exit status 0 = all checks passed, 1 = at least one FAIL.
"""
import json
import re
import sys

NAND_SIZE = 128 * 1024 * 1024
ERASE = 128 * 1024
# Partitions that must never be writable from OpenWrt (factory/boot data).
# Since patch 0015 every partition is read-only while no validated install
# procedure exists (the RAM image must not be able to write NAND at all):
# 0:APPSBLENV, the two stock slots and "data" (empty UBI auto-attached at boot).
MUST_RO = {"0:SBL1", "0:MIBIB", "0:BOOTCONFIG", "0:BOOTCONFIG1", "0:QSEE",
           "0:DEVCFG", "0:CDT", "0:APPSBL", "0:ART", "0:TRAINING",
           "tp_data", "radio",
           "0:APPSBLENV", "rootfs", "rootfs_1", "data"}
# Layout documented from the stock partition table (docs/HARDWARE.md) and
# /proc/mtd on hardware (forum t/254876 #57).
EXPECTED = {
    "0:SBL1": (0x0, 0x80000), "0:MIBIB": (0x80000, 0x80000),
    "0:BOOTCONFIG": (0x100000, 0x40000), "0:BOOTCONFIG1": (0x140000, 0x40000),
    "0:QSEE": (0x180000, 0x100000), "0:DEVCFG": (0x280000, 0x40000),
    "0:CDT": (0x2c0000, 0x40000), "0:APPSBLENV": (0x300000, 0x80000),
    "0:APPSBL": (0x380000, 0x140000), "0:ART": (0x4c0000, 0x100000),
    "0:TRAINING": (0x5c0000, 0x80000), "rootfs": (0x640000, 0x3580000),
    "rootfs_1": (0x3bc0000, 0x3580000), "tp_data": (0x7140000, 0x840000),
    "radio": (0x7980000, 0x440000), "data": (0x7dc0000, 0x80000),
}


def nodes(text, name_re):
    """Yield (name, body) for nodes whose name matches name_re (flat bodies)."""
    for m in re.finditer(r"(" + name_re + r")\s*\{", text):
        start = m.end()
        depth, i = 1, start
        while depth:
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
        yield m.group(1), text[start:i - 1]


def prop(body, name):
    m = re.search(r"(?:^|;)\s*" + re.escape(name) + r"\s*(=\s*([^;]*))?;", body)
    if not m:
        return None
    return True if m.group(2) is None else m.group(2).strip()


def cells(v):
    """Integer cells from '<0x.. 0x..>' or from dtc's string rendering of
    printable cell bytes (e.g. 0x4c400000 is printed as "L@\\0")."""
    v = v.strip()
    if v.startswith('"'):
        raw = bytearray()
        body = v[1:v.rindex('"')]
        i = 0
        while i < len(body):
            c = body[i]
            if c == "\\":
                n = body[i + 1]
                if n == "0":
                    raw.append(0)
                elif n == "x":
                    raw.append(int(body[i + 2:i + 4], 16)); i += 2
                else:
                    raw.append({"n": 10, "t": 9, "r": 13}.get(n, ord(n)))
                i += 2
                continue
            raw.append(ord(c)); i += 1
        raw.append(0)  # implicit terminator dtc assumed
        if len(raw) % 4:
            return []
        return [int.from_bytes(raw[j:j + 4], "big") for j in range(0, len(raw), 4)]
    return [int(x, 16) for x in re.findall(r"0x[0-9a-fA-F]+", v)]


def main():
    path = sys.argv[1]
    text = open(path).read()
    res = []

    def check(name, ok, detail=""):
        res.append({"check": name, "status": "PASS" if ok else "FAIL", "detail": detail})

    check("model", 'model = "TP-Link Archer AX23 v2"' in text)
    check("compatible", re.search(r'compatible = "tplink,archer-ax23-v2(\\0|")', text) is not None)

    parts = {}
    for _, body in nodes(text, r"partition@[0-9a-f]+"):
        label = prop(body, "label")
        reg = cells(prop(body, "reg") or "")
        if label and len(reg) == 2:
            parts[label.strip('"')] = (reg[0], reg[1], bool(prop(body, "read-only")))
    check("partition count", len(parts) == len(EXPECTED), f"{len(parts)} found")
    for lbl, (off, size) in EXPECTED.items():
        got = parts.get(lbl)
        check(f"partition {lbl} offset/size", got is not None and got[:2] == (off, size),
              f"got {got and (hex(got[0]), hex(got[1]))} want {(hex(off), hex(size))}")
    for lbl in MUST_RO:
        check(f"partition {lbl} read-only", lbl in parts and parts[lbl][2])
    srt = sorted(parts.values())
    end = 0
    overlap = False
    for off, size, _ in srt:
        overlap |= off < end
        end = max(end, off + size)
    check("no partition overlap", not overlap)
    check("partitions within 128 MiB", end <= NAND_SIZE, hex(end))
    check("erase-block aligned", all(o % ERASE == 0 and s % ERASE == 0 for o, s, _ in srt))

    radios = {}
    for name, body in nodes(text, r"wifi@[0-9a-f]+"):
        if prop(body, "status") == '"okay"':
            radios[name] = body
    check("two radios enabled", set(radios) == {"wifi@c000000", "wifi@b00a040"}, ",".join(sorted(radios)))
    for name, body in radios.items():
        check(f"{name} calibration-variant", prop(body, "qcom,ath11k-calibration-variant") == '"TP-Link-Archer-AX23-v2"')
        mm = prop(body, "qcom,ath11k-fw-memory-mode")
        check(f"{name} fw-memory-mode 2", mm is not None and cells(mm) == [2], str(mm))
    if "wifi@b00a040" in radios:
        b = radios["wifi@b00a040"]
        check("qcn6122 userpd2", prop(b, "qcom,userpd-subsys-name") == '"q6v5_wcss_userpd2"')
        check("qcn6122 bdf-addr inside q6 region", cells(prop(b, "qcom,bdf-addr") or "") == [0x4d100000])
    if "wifi@c000000" in radios:
        check("ipq5018 bdf-addr", cells(prop(radios["wifi@c000000"], "qcom,bdf-addr") or "") == [0x4c400000])

    q6 = [cells(prop(b, "reg") or "") for n, b in nodes(text, r"(?:q6|wcss)[-_a-z0-9]*@4b000000")]
    check("q6 region 0x4b000000+0x3000000 (covers bdf/m3 addrs)",
          any(c[-2:] == [0x4b000000, 0x3000000] or c[-1:] == [0x3000000] for c in q6), str(q6))

    trig = {}
    for name, body in nodes(text, r"led-wifi-[25]g"):
        trig[name] = prop(body, "linux,default-trigger")
    check("2.4G LED on phy0tpt", trig.get("led-wifi-2g") == '"phy0tpt"', str(trig))
    check("5G LED on phy1tpt", trig.get("led-wifi-5g") == '"phy1tpt"', str(trig))

    sw = list(nodes(text, r"switch@1d"))
    check("rtl8365mb switch@1d", bool(sw) and '"realtek,rtl8365mb"' in sw[0][1])
    check("cpu port 2500base-x", bool(sw) and '"2500base-x"' in sw[0][1])

    fails = [r for r in res if r["status"] == "FAIL"]
    if "--json" in sys.argv:
        print(json.dumps(res, indent=1))
    else:
        for r in res:
            print(f"{r['status']:4} {r['check']} {r['detail']}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
