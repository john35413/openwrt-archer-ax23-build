#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Unit tests for the project's offline tools (synthetic data only)."""
import binascii
import importlib.util
import os
import struct
import subprocess
import sys
import tempfile
import unittest

PROJ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def load(name, rel):
    spec = importlib.util.spec_from_file_location(name, os.path.join(PROJ, rel))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


board2 = load("board2", "tools/bdf/board2.py")
ubootenv = load("ubootenv", "tools/uboot/ubootenv.py")

AX23 = "bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=TP-Link-Archer-AX23-v2"


class Board2Robust(unittest.TestCase):
    """The OTP board id is unknown until the unit boots: the packed board-2.bin
    must resolve to the same data for any value via ath11k's lookup chain."""
    def _run(self, blob, stock):
        with tempfile.NamedTemporaryFile(suffix=".bin") as f:
            f.write(blob); f.flush()
            return board2.main(["robust", f.name, "--stock-board-id", str(stock)])

    def test_single_255_entry_is_not_robust(self):
        self.assertEqual(self._run(board2.pack([(AX23, os.urandom(4096))]), 36), 1)

    def test_three_names_same_data_is_robust(self):
        d = os.urandom(4096)
        v = ",variant=TP-Link-Archer-AX23-v2"
        blob = board2.pack([(AX23, d), ("bus=ahb,qmi-chip-id=0,qmi-board-id=36" + v, d),
                            ("bus=ahb,qmi-chip-id=0", d)])
        self.assertEqual(self._run(blob, 36), 0)

    def test_different_data_under_names_is_rejected(self):
        v = ",variant=TP-Link-Archer-AX23-v2"
        blob = board2.pack([(AX23, os.urandom(4096)), ("bus=ahb,qmi-chip-id=0", os.urandom(4096)),
                            ("bus=ahb,qmi-chip-id=0,qmi-board-id=36" + v, os.urandom(4096))])
        self.assertEqual(self._run(blob, 36), 1)


class Board2(unittest.TestCase):
    def test_roundtrip(self):
        a, b = os.urandom(131072), os.urandom(1001)  # odd length exercises padding
        blob = board2.pack([(AX23, a), ("bus=ahb,qmi-chip-id=0,qmi-board-id=255", b)])
        ents = board2.parse(blob)
        self.assertEqual([(e[1], e[2]) for e in ents],
                         [(AX23, a), ("bus=ahb,qmi-chip-id=0,qmi-board-id=255", b)])

    def test_name_order_matches_ath11k(self):
        # Order and format taken from the AX23 v2 UART log (forum t/254876):
        # variant name, then no-variant name, then chip-id name.
        self.assertEqual(board2.candidate_names("ahb", 0, 255, "TP-Link-Archer-AX23-v2"),
                         [AX23, "bus=ahb,qmi-chip-id=0,qmi-board-id=255", "bus=ahb,qmi-chip-id=0"])

    def test_variant_wins_over_generic(self):
        blob = board2.pack([("bus=ahb,qmi-chip-id=0,qmi-board-id=255", b"G"), (AX23, b"V")])
        hit, data = board2.lookup(board2.parse(blob),
                                  board2.candidate_names("ahb", 0, 255, "TP-Link-Archer-AX23-v2"))
        self.assertEqual((hit, data), (AX23, b"V"))

    def test_other_board_does_not_match(self):
        blob = board2.pack([("bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=TP-Link-Archer-AX55-v1", b"X")])
        hit, _ = board2.lookup(board2.parse(blob),
                               board2.candidate_names("ahb", 0, 255, "TP-Link-Archer-AX23-v2"))
        self.assertIsNone(hit)

    def test_bad_magic(self):
        with self.assertRaises(ValueError):
            board2.parse(b"NOT-A-BOARD-FILE" + b"\0" * 32)

    def test_cli_lookup_exit_codes(self):
        with tempfile.TemporaryDirectory() as d:
            f = os.path.join(d, "b.bin")
            open(f, "wb").write(board2.pack([(AX23, b"x" * 8)]))
            ok = subprocess.run([sys.executable, "-I", os.path.join(PROJ, "tools/bdf/board2.py"),
                                 "lookup", f, "--chip-id", "0", "--board-id", "255",
                                 "--variant", "TP-Link-Archer-AX23-v2"], capture_output=True, text=True)
            self.assertEqual(ok.returncode, 0, ok.stdout)
            self.assertIn("MATCH " + AX23, ok.stdout)
            # pack CLI: NAME contains '=', so NAME=FILE must split at the last '='
            src = os.path.join(d, "src.bin"); open(src, "wb").write(b"abc")
            out = os.path.join(d, "packed.bin")
            pk = subprocess.run([sys.executable, "-I", os.path.join(PROJ, "tools/bdf/board2.py"),
                                 "pack", out, AX23 + "=" + src], capture_output=True, text=True)
            self.assertEqual(pk.returncode, 0, pk.stderr)
            self.assertEqual(board2.parse(open(out, "rb").read()), [(0, AX23, b"abc")])
            miss = subprocess.run([sys.executable, "-I", os.path.join(PROJ, "tools/bdf/board2.py"),
                                   "lookup", f, "--chip-id", "1", "--board-id", "255"],
                                  capture_output=True, text=True)
            self.assertEqual(miss.returncode, 1)


def mkenv(size, kv, redundant=False):
    body = b"\0".join(f"{k}={v}".encode() for k, v in kv.items()) + b"\0\0"
    hdr = 5 if redundant else 4
    data = body + b"\0" * (size - hdr - len(body))
    crc = binascii.crc32(data) & 0xffffffff
    return struct.pack("<I", crc) + (b"\x01" if redundant else b"") + data


class UbootEnv(unittest.TestCase):
    def test_detects_size_and_vars(self):
        env = mkenv(0x40000, {"bootcmd": "bootipq", "tp_boot_idx": "1"}) + b"\xff" * 0x40000
        res = [r for r in ubootenv.analyse(env) if r["crc_ok"]]
        self.assertEqual([(r["layout"], r["size"]) for r in res], [("single", 0x40000)])
        self.assertEqual(res[0]["vars"]["tp_boot_idx"], "1")

    def test_erased_env_has_no_valid_crc(self):
        self.assertFalse(any(r["crc_ok"] for r in ubootenv.analyse(b"\xff" * 0x80000)))

    def test_redundant_layout(self):
        env = mkenv(0x20000, {"bootcmd": "bootipq"}, redundant=True)
        res = [r for r in ubootenv.analyse(env) if r["crc_ok"]]
        self.assertEqual(res[0]["layout"], "redundant")


class DtbChecker(unittest.TestCase):
    """Feed check_dtb.py a minimal synthetic DTS: a wrong layout must FAIL."""

    def run_check(self, text):
        with tempfile.TemporaryDirectory() as d:
            f = os.path.join(d, "x.dts")
            open(f, "w").write(text)
            return subprocess.run([sys.executable, "-I", os.path.join(PROJ, "tests/static/check_dtb.py"), f],
                                  capture_output=True, text=True)

    def test_writable_art_fails(self):
        text = ('/ { model = "TP-Link Archer AX23 v2"; compatible = "tplink,archer-ax23-v2";\n'
                'partition@4c0000 { label = "0:ART"; reg = <0x4c0000 0x100000>; };\n};\n')
        r = self.run_check(text)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("FAIL partition 0:ART read-only", r.stdout)
        self.assertIn("PASS partition 0:ART offset/size", r.stdout)

    def test_overlap_detected(self):
        text = ('/ {\npartition@0 { label = "a"; reg = <0x0 0x200000>; read-only; };\n'
                'partition@100000 { label = "b"; reg = <0x100000 0x100000>; read-only; };\n};\n')
        r = self.run_check(text)
        self.assertIn("FAIL no partition overlap", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
