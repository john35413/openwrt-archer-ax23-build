#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""ath11k board-2.bin inspector / packer (no third-party dependencies).

Format (drivers/net/wireless/ath/ath11k/hw.h, core.c):
  "QCA-ATH11K-BOARD\\0" padded to 4 bytes, then a list of IEs:
      le32 id, le32 len, data[len], pad to 4
  top-level id 0 = BOARD (contains sub-IEs: 0 = NAME, 1 = DATA)
  top-level id 1 = REGDB (same sub-IE layout)

Subcommands
  list   FILE                         print every board name + data sha256
  lookup FILE --chip-id N --board-id N [--variant V] [--bus ahb]
                                      emulate ath11k_core_fetch_bdf() name
                                      search order, report which entry wins
  pack   OUT NAME=FILE [NAME=FILE...] build a board-2.bin
  names  --chip-id N --board-id N [--variant V] [--bus ahb]
                                      print the names ath11k will try

This tool never fabricates board data: `pack` only wraps files you give it.
"""
import argparse
import hashlib
import struct
import sys

MAGIC = b"QCA-ATH11K-BOARD\0"
IE_BOARD, IE_REGDB = 0, 1
SUB_NAME, SUB_DATA = 0, 1


def _align4(n):
    return (n + 3) & ~3


def _ies(buf, off, end):
    while end - off > 8:
        ie_id, ie_len = struct.unpack_from("<II", buf, off)
        off += 8
        if end - off < _align4(ie_len) and end - off < ie_len:
            raise ValueError(f"truncated IE id={ie_id} len={ie_len} at {off-8:#x}")
        yield ie_id, buf[off:off + ie_len]
        off += _align4(ie_len)


def parse(buf):
    """Return list of (top_id, name, data) in file order."""
    mlen = _align4(len(MAGIC))
    if buf[:len(MAGIC)] != MAGIC:
        raise ValueError("bad magic (not a board-2.bin)")
    out = []
    for top_id, body in _ies(buf, mlen, len(buf)):
        name = None
        for sid, sdata in _ies(body, 0, len(body)):
            if sid == SUB_NAME:
                name = sdata.decode("ascii", "replace")
            elif sid == SUB_DATA:
                out.append((top_id, name, sdata))
    return out


def candidate_names(bus, chip_id, board_id, variant):
    """Same order as ath11k_core_fetch_bdf() for ATH11K_BDF_SEARCH_DEFAULT."""
    full = f"bus={bus},qmi-chip-id={chip_id},qmi-board-id={board_id}"
    names = []
    if variant:
        names.append(full + f",variant={variant}")
    names.append(full)                       # fallback name (no variant)
    names.append(f"bus={bus},qmi-chip-id={chip_id}")  # chip-id name
    return names


def lookup(entries, names):
    for n in names:
        for top_id, name, data in entries:
            if top_id == IE_BOARD and name == n:
                return n, data
    return None, None


def pack(pairs, regdb=()):
    out = bytearray(MAGIC)
    out += b"\0" * (_align4(len(out)) - len(out))

    def ie(i, d):
        return struct.pack("<II", i, len(d)) + d + b"\0" * (_align4(len(d)) - len(d))

    for top, items in ((IE_BOARD, pairs), (IE_REGDB, regdb)):
        for name, data in items:
            out += ie(top, ie(SUB_NAME, name.encode("ascii")) + ie(SUB_DATA, data))
    return bytes(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("list"); p.add_argument("file")
    for c in ("lookup", "names"):
        p = sp.add_parser(c)
        if c == "lookup":
            p.add_argument("file")
        p.add_argument("--bus", default="ahb")
        p.add_argument("--chip-id", type=int, required=True)
        p.add_argument("--board-id", type=int, required=True)
        p.add_argument("--variant", default="")
    p = sp.add_parser("pack"); p.add_argument("out"); p.add_argument("pairs", nargs="+")
    a = ap.parse_args(argv)

    if a.cmd == "names":
        print("\n".join(candidate_names(a.bus, a.chip_id, a.board_id, a.variant)))
        return 0
    if a.cmd == "pack":
        pairs = []
        for pr in a.pairs:
            # board names contain '=' themselves: split at the LAST '='
            name, _, path = pr.rpartition("=")
            if not path:
                ap.error(f"expected NAME=FILE, got {pr!r}")
            pairs.append((name, open(path, "rb").read()))
        open(a.out, "wb").write(pack(pairs))
        print(f"wrote {a.out}: {len(pairs)} board entr{'y' if len(pairs) == 1 else 'ies'}")
        return 0

    entries = parse(open(a.file, "rb").read())
    if a.cmd == "list":
        for top_id, name, data in entries:
            kind = "BOARD" if top_id == IE_BOARD else "REGDB"
            print(f"{kind} len={len(data):7d} sha256={hashlib.sha256(data).hexdigest()[:16]} {name}")
        return 0
    names = candidate_names(a.bus, a.chip_id, a.board_id, a.variant)
    hit, data = lookup(entries, names)
    for n in names:
        print(("MATCH " if n == hit else "miss  ") + n)
    if hit is None:
        print("RESULT: no entry matches; ath11k would fall back to board.bin")
        return 1
    print(f"RESULT: {hit} ({len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
