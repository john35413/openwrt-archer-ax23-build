#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Unit tests for the project's offline tools (synthetic data only)."""
import binascii
import importlib.util
import hashlib
import lzma
from pathlib import Path
import shutil
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


class Board2Scope(unittest.TestCase):
    def test_scope_for_each_radio(self):
        data = bytes(131072)
        for sid in (36, 96):
            exact = [(AX23, data), (AX23.replace("255", str(sid)), data)]
            for pairs, valid in ((exact, True), (exact[:1], False),
                                 (exact + [("bus=ahb,qmi-chip-id=0", data)], False),
                                 (exact + exact[:1], False),
                                 ([exact[0], (exact[1][0], bytes([1])*131072)], False)):
                with self.subTest(sid=sid, keys=[k for k, _ in pairs]):
                    with tempfile.NamedTemporaryFile() as f:
                        f.write(board2.pack(pairs))
                        f.flush()
                        rc = board2.main(["scoped", f.name, "--stock-board-id", str(sid)])
                        self.assertEqual(rc == 0, valid)
                        if valid:
                            self.assertEqual(board2.main(["scoped", f.name, "--stock-board-id",
                                                          str(sid), "--eu"]), 1)
            entries = board2.parse(board2.pack(exact))
            for bid, variant in [(7, "TP-Link-Archer-AX23-v2"), (sid, "Other"), (255, "")]:
                self.assertIsNone(board2.lookup(entries, board2.candidate_names("ahb", 0, bid, variant))[0])


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


@unittest.skipUnless(shutil.which("dtc"), "dtc required for synthetic FIT")
class FitBootPath(unittest.TestCase):
    def test_selected_payloads(self):
        fit = load("fit_verify", "tools/fit-verify.py")
        with tempfile.TemporaryDirectory() as dirname:
            d = Path(dirname)
            def image(name, kind, comp, data, extra=""):
                (d / name).write_bytes(data)
                digest = hashlib.sha256(data).hexdigest()
                return f'{name} {{ type="{kind}"; compression="{comp}"; data=/incbin/("{name}"); {extra} hash {{ algo="sha256"; value=[{digest}]; }}; }};'
            packed = lzma.compress(b"kernel fixture", format=lzma.FORMAT_ALONE)
            nodes = image("kernel", "kernel", "lzma", packed,
                          "load=<0x41000000>; entry=<0x41000000>;")
            nodes += image("first", "flat_dt", "none", b"unused")
            nodes += image("board", "flat_dt", "none", b"selected")
            cfg = "config@mp02.1"
            for default, dtb, valid in [(cfg, "board", True), ("other", "board", False),
                                        (cfg, "missing", False), (cfg, "kernel", False)]:
                dts = f'/dts-v1/; / {{ images {{ {nodes} }}; configurations {{ default="{default}"; {cfg} {{ kernel="kernel"; fdt="{dtb}"; }}; }}; }};'
                (d / "in.dts").write_text(dts)
                blob = subprocess.check_output(["dtc", "-q", "-I", "dts", "-O", "dtb", "in.dts"], cwd=d)
                self.assertTrue(fit.verify(blob, cfg)[0])
                if valid:
                    self.assertEqual(fit.ram_boot_dtb(blob, cfg), b"selected")
                    self.assertFalse(fit.verify(blob.replace(b"selected", b"corrupt!"), cfg)[0])
                else:
                    with self.assertRaises((ValueError, KeyError)):
                        fit.ram_boot_dtb(blob, cfg)


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

    def test_extra_unlabelled_partition(self):
        checker = load("dtb_checker", "tests/static/check_dtb.py")
        parts = "".join(f'partition@{off:x} {{ label="{name}"; reg=<0x{off:x} 0x{size:x}>; read-only; }};'
                        for name, (off, size) in checker.EXPECTED.items())
        result = self.run_check(parts + 'partition@7e40000 { reg=<0x7e40000 0x20000>; };')
        self.assertIn("FAIL exactly 16 physical partition nodes", result.stdout)

    def test_q6_wrong_address_correct_size(self):
        r = self.run_check('wcss@4b000000 { reg=<0x0 0x45000000 0x0 0x3000000>; };')
        self.assertIn("FAIL q6 region", r.stdout)

    def test_overlap_detected(self):
        text = ('/ {\npartition@0 { label = "a"; reg = <0x0 0x200000>; read-only; };\n'
                'partition@100000 { label = "b"; reg = <0x100000 0x100000>; read-only; };\n};\n')
        r = self.run_check(text)
        self.assertIn("FAIL no partition overlap", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
