#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Verify the per-image hashes of a FIT (flattened image tree), like U-Boot's
bootm does before booting, and check that a configuration exists.

  fit-verify.py IMAGE [--config config@mp02.1]

Reads a file or a raw volume dump (trailing bytes after the FDT are ignored).
Exit 0 if the FDT header is valid, every /images/* node with a "data"
property has at least one hash node and all hashes match, and the requested
configuration exists. Supports crc32, md5, sha1, sha256, sha384, sha512.
Offline tool; no device is touched.
"""
import hashlib
import struct
import sys
import zlib

FDT_MAGIC = 0xD00DFEED
BEGIN, END, PROP, NOP, FEND = 1, 2, 3, 4, 9


def parse(blob):
    if len(blob) < 40:
        raise ValueError("too short for an FDT header")
    magic, total, off_struct, off_strings, _, _, _, _, _, size_struct = struct.unpack(">10I", blob[:40])
    if magic != FDT_MAGIC:
        raise ValueError("no FDT magic")
    if total > len(blob):
        raise ValueError("FDT totalsize %d beyond available %d bytes" % (total, len(blob)))
    strings = blob[off_strings:total]
    p, end = off_struct, off_struct + size_struct
    root = {"props": {}, "children": {}}
    stack = [root]
    while p < end:
        (tok,) = struct.unpack(">I", blob[p:p + 4]); p += 4
        if tok == BEGIN:
            e = blob.index(b"\0", p); name = blob[p:e].decode(); p = (e + 4) & ~3
            node = {"props": {}, "children": {}}
            stack[-1]["children"][name] = node; stack.append(node)
        elif tok == END:
            stack.pop()
        elif tok == PROP:
            ln, nameoff = struct.unpack(">II", blob[p:p + 8]); p += 8
            name = strings[nameoff:strings.index(b"\0", nameoff)].decode()
            stack[-1]["props"][name] = blob[p:p + ln]; p = (p + ln + 3) & ~3
        elif tok == NOP:
            continue
        elif tok == FEND:
            break
        else:
            raise ValueError("bad FDT token %d" % tok)
    return root["children"].get("", root)      # the FDT root node is named ""


def digest(algo, data):
    algo = algo.rstrip(b"\0").decode()
    if algo == "crc32":
        return struct.pack(">I", zlib.crc32(data) & 0xFFFFFFFF)
    return hashlib.new(algo, data).digest()


def verify(blob, config=None):
    root = parse(blob)
    images = root["children"].get("images", {"children": {}})["children"]
    out, ok = [], bool(images)
    if not images:
        out.append("no /images nodes")
    for name, node in images.items():
        data = node["props"].get("data")
        if data is None:
            out.append("%s: no embedded data" % name); ok = False; continue
        hashes = [h for n, h in node["children"].items() if n.startswith("hash")]
        if not hashes:
            out.append("%s: no hash node" % name); ok = False; continue
        for h in hashes:
            good = digest(h["props"]["algo"], data) == h["props"]["value"]
            ok &= good
            out.append("%s: %s %s" % (name, h["props"]["algo"].rstrip(b"\0").decode(), "OK" if good else "MISMATCH"))
    if config:
        confs = root["children"].get("configurations", {"children": {}})["children"]
        has = config in confs
        ok &= has
        out.append("configuration %s %s" % (config, "present" if has else "MISSING"))
    return ok, out


def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    cfg = sys.argv[sys.argv.index("--config") + 1] if "--config" in sys.argv else None
    try:
        ok, lines = verify(open(sys.argv[1], "rb").read(), cfg)
    except (ValueError, struct.error, KeyError) as e:
        print("FAIL %s" % e); return 1
    print("\n".join(lines))
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
