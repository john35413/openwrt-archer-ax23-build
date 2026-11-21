#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Compare AX23 dev files in the kernel's embedded zstd/newc archive to staging."""
import argparse
import ctypes
import hashlib
import stat
import sys
from pathlib import Path


def embedded_archive(image):
    lib = ctypes.CDLL("libzstd.so.1")
    for name, args in (
        ("ZSTD_findFrameCompressedSize", [ctypes.c_char_p, ctypes.c_size_t]),
        ("ZSTD_decompress", [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]),
    ):
        fn = getattr(lib, name)
        fn.argtypes = args
        fn.restype = ctypes.c_size_t
    archives = []
    offset = 0
    while True:
        pos = image.find(b"\x28\xb5\x2f\xfd", offset)
        if pos < 0:
            break
        offset = pos + 4
        frame = image[pos:]
        size = lib.ZSTD_findFrameCompressedSize(frame, len(frame))
        if size > len(frame):
            continue
        # Independent of the frame's advertised (possibly unknown) content size.
        buf = ctypes.create_string_buffer(128 << 20)
        n = lib.ZSTD_decompress(buf, len(buf), frame, size)
        if n <= len(buf) and buf[:6] == b"070701":
            archives.append(buf[:n])
        offset = pos + size
    if len(archives) != 1:
        raise ValueError(f"expected one embedded zstd/newc initramfs, found {len(archives)}")
    return archives[0]


def members(data):
    offset = 0
    while data[offset:offset + 6] == b"070701":
        fields = [int(data[i:i + 8], 16) for i in range(offset + 6, offset + 110, 8)]
        mode, size, namesize = fields[1], fields[6], fields[11]
        start = offset + 110
        end = start + namesize
        if not namesize or data[end-1:end] != b"\0":
            raise ValueError("incomplete newc name")
        name = data[start:end-1].decode().removeprefix("./")
        start = (end + 3) & ~3
        if start + size > len(data):
            raise ValueError("incomplete newc member")
        if name == "TRAILER!!!":
            if any(data[start:]):
                raise ValueError("unexpected data following initramfs trailer")
            return
        yield name, mode, data[start:start + size]
        offset = (start + size + 3) & ~3
    raise ValueError("incomplete newc archive")


def check(image, root):
    required = {"etc/init.d/ax23-radio-seq", "lib/preinit/08_ax23_radio_profile",
                "lib/preinit/09_mount_tp_data", "lib/upgrade/platform.sh",
                "etc/hotplug.d/firmware/11-ath11k-caldata", "lib/functions/caldata.sh"}
    for radio in ("IPQ5018", "QCN6122"):
        required.add(f"lib/firmware/ath11k/{radio}/hw1.0/board-2.bin")
    for module in ("ath11k", "ath11k_ahb"):
        paths = list(root.glob(f"lib/modules/*/{module}.ko"))
        if len(paths) != 1:
            raise ValueError(f"expected one staged {module} module")
        required.add(paths[0].relative_to(root).as_posix())
    seen = set()
    for name, mode, payload in members(embedded_archive(image)):
        if name in {p.replace("board-2.bin", "board.bin") for p in required if p.endswith("board-2.bin")}:
            raise ValueError(f"unexpected firmware fallback {name}")
        if name not in required:
            continue
        if name in seen or not stat.S_ISREG(mode) or payload != (root / name).read_bytes():
            raise ValueError(f"embedded file differs from staging or is duplicated: {name}")
        seen.add(name)
        print(hashlib.sha256(payload).hexdigest(), name)
    if missing := required - seen:
        raise ValueError("missing embedded files: " + ", ".join(sorted(missing)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("staged_root", type=Path)
    args = parser.parse_args()
    try:
        check(args.image.read_bytes(), args.staged_root)
    except (ValueError, OSError) as exc:
        sys.exit(f"FAIL {exc}")
