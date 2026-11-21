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
import argparse
import hashlib
import lzma
from pathlib import Path
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


def ram_boot_payloads(blob, config):
    """Check the default boot path and bound the actual decompressed kernel."""
    root = parse(blob)["children"]
    confs = root["configurations"]
    if confs["props"]["default"] != config.encode() + b"\0":
        raise ValueError("unexpected default configuration")
    props = confs["children"][config]["props"]
    images = root["images"]["children"]

    def selected(role, expected_type):
        name = props[role].removesuffix(b"\0").decode()
        image = images[name]["props"]
        if image["type"] != expected_type:
            raise ValueError(f"incorrect type for {role}: {name}")
        return image

    kernel = selected("kernel", b"kernel\0")
    fdt = selected("fdt", b"flat_dt\0")
    load = 0x41000000
    fit_base = 0x44000000
    if kernel["load"] != struct.pack(">I", load) or kernel["entry"] != kernel["load"]:
        raise ValueError("unexpected kernel load or entry point")
    if kernel["compression"] != b"lzma\0" or fdt["compression"] != b"none\0":
        raise ValueError("unexpected payload compression")
    limit = fit_base - load
    decoder = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE, memlimit=128 << 20)
    image = decoder.decompress(kernel["data"], max_length=limit + 1)
    if not image or not decoder.eof or len(image) > limit:
        raise ValueError("truncated kernel or decompression extends into the FIT")
    if fit_base + len(blob) > 0x4b000000:
        raise ValueError("FIT overlaps Q6 reservation")
    return fdt["data"], image


def ram_boot_dtb(blob, config):
    return ram_boot_payloads(blob, config)[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("--config")
    parser.add_argument("--ram-boot-dtb", type=Path,
                        help="check the AX23 RAM layout and extract its selected DTB")
    parser.add_argument("--ram-boot-kernel", type=Path, help="extract the selected decompressed kernel")
    args = parser.parse_args()
    if (args.ram_boot_dtb or args.ram_boot_kernel) and not args.config:
        parser.error("--ram-boot-dtb requires --config")
    try:
        blob = args.image.read_bytes()
        ok, lines = verify(blob, args.config)
        if ok and (args.ram_boot_dtb or args.ram_boot_kernel):
            dtb, kernel = ram_boot_payloads(blob, args.config)
            if args.ram_boot_dtb:
                args.ram_boot_dtb.write_bytes(dtb)
            if args.ram_boot_kernel:
                args.ram_boot_kernel.write_bytes(kernel)
    except (ValueError, IndexError, struct.error, KeyError, lzma.LZMAError) as e:
        print("FAIL %s" % e); return 1
    print("\n".join(lines))
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
