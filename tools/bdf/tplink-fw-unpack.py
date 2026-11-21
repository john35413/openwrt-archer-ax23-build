#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Verify and unpack an official TP-Link Archer AX23 v2 firmware image.

  tplink-fw-unpack.py FIRMWARE.bin OUT.ubi

Implements the scheme in TP-Link's own GPL source for this device
(GPL_AX23v2.tar.gz: u-boot-2016/lib/nvrammanager/nm_fwup.c, rsaVerify.c):

  0x000  be32 total length
  0x004  16-byte MD5 field          (unused here)
  0x014  signed region starts       (RSA signature field zeroed for hashing)
  0x110+2  signature type: 1 = RSA-1024 PKCS#1 over MD5, 2 = RSA-2048 PSS/SHA-256
  0x130  signature (0x80 or 0x100 bytes)

RSA-1024 images ("1024_sign", PKCS#1 v1.5 / SHA-1 over the MD5) carry a plaintext UBI image.
RSA-2048 PSS images ("2048_sign") are AES-128-CBC encrypted from 0x230 on,
with key = PSS salt[0:16] and IV = salt[16:32] (the salt is recovered while
verifying the signature with TP-Link's public key, which is published in the
GPL source above).

The signature is checked with TP-Link's public key; an image that does not
verify is rejected. Nothing is ever written to a router. The output is
TP-Link's proprietary firmware: keep it local, do not redistribute it.
"""
import base64
import hashlib
import struct
import subprocess
import sys

# Public keys from GPL_AX23v2.tar.gz u-boot-2016/lib/nvrammanager/nm_fwup.c
RSA2048_BLOB = ("BgIAAAwkAABSU0ExAAgAAAEAAQCdocMdSvAkLmNelNXLolhx4/OqVrxm6g1XCIlMdTgWAAbA4GkS"
                "ZbU4juBCWdUgc7oYCinkzpjttbZpFY1FS1GfYAiga2S9czL3tB2+7YMcwozwXW504nXGEJ5Shmvv"
                "Zy6iu/N54hFauwram8Sbc7ax1sJ1rRA78jWz7i1mX/AeIPgWw336DQeYhAyZlFjVGkyFK1miLDgD"
                "eMmejJVZu3v3iu6VyuyVSGngRP+RyROzjvefY45kBM3h+2HM9oF3BkeUvS6TMasCmgMQEepVOLLc"
                "gbPlogmpxxlFRxTm0sjyIIhMj422ClU06ze31E+TBwtFiagwfw85f+gqzsOIo8e2")
RSA1024_BLOB = ("BgIAAACkAABSU0ExAAQAAAEAAQD9lxDCQ5DFNSYJBriTmTmZlEMYVgGcZTO+AIwm"
                "dVjhaeJI6wWtN7DqCaHQlOqJ2xvKNrLB+wA1NxUh7VDViymotq/+9QDf7qEtJHmesji"
                "rvPN6Hfrf+FO4/hmjbVXgytHORxGta5KW4QHVIwyMSVPOvMC4A5lFIh+D1kJW5GXWtA==")
FWTYPE, SIG_OFF, PAYLOAD = 0x14, 0x130, 0x230


def pubkey(blob):
    """Microsoft PUBLICKEYBLOB -> (n, e)."""
    b = base64.b64decode(blob)
    magic, bits, e = struct.unpack_from("<4sII", b, 8)
    assert magic == b"RSA1", magic
    n = int.from_bytes(b[20:20 + bits // 8], "little")
    return n, e, bits


def mgf1(seed, length):
    out = b""
    c = 0
    while len(out) < length:
        out += hashlib.sha256(seed + c.to_bytes(4, "big")).digest()
        c += 1
    return out[:length]


def pss_recover_salt(msg, sig):
    n, e, bits = pubkey(RSA2048_BLOB)
    em = pow(int.from_bytes(sig, "little"), e, n).to_bytes(bits // 8, "big")  # rsaVerify.c reverses the signature bytes
    if em[-1] != 0xBC:
        raise ValueError("PSS trailer mismatch: not a valid signature for this key")
    hlen = 32
    masked, h = em[:-hlen - 1], em[-hlen - 1:-1]
    db = bytearray(a ^ b for a, b in zip(masked, mgf1(h, len(masked))))
    db[0] &= 0xFF >> (8 * len(em) - (bits - 1))
    i = db.index(1)
    if any(db[:i]):
        raise ValueError("PSS padding invalid")
    salt = bytes(db[i + 1:])
    mhash = hashlib.sha256(msg).digest()
    if hashlib.sha256(b"\0" * 8 + mhash + salt).digest() != h:
        raise ValueError("PSS hash mismatch: image modified or wrong key")
    return salt


def pkcs1_md5_verify(msg, sig):
    """RSA-1024: PuTTY rsa2_verifysig = PKCS#1 v1.5, SHA-1 DigestInfo over the
    16-byte MD5 of the signed region (handle_fw_cloud passes the MD5 as data)."""
    n, e, bits = pubkey(RSA1024_BLOB)
    em = pow(int.from_bytes(sig, "little"), e, n).to_bytes(bits // 8, "big")
    digestinfo = bytes.fromhex("3021300906052b0e03021a05000414")
    want = digestinfo + hashlib.sha1(hashlib.md5(msg).digest()).digest()
    return em.startswith(b"\x00\x01\xff") and em.endswith(b"\x00" + want)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    buf = bytearray(open(src, "rb").read())
    if struct.unpack(">I", buf[:4])[0] != len(buf):
        sys.exit("length field does not match file size")
    kind = buf[SIG_OFF - 0x20 + 2]
    siglen = 0x100 if kind == 2 else 0x80
    sig = bytes(buf[SIG_OFF:SIG_OFF + siglen])
    msg = bytearray(buf)
    msg[SIG_OFF:SIG_OFF + siglen] = b"\0" * siglen
    msg = bytes(msg[FWTYPE:])
    if kind == 2:
        salt = pss_recover_salt(msg, sig)
        print(f"RSA-2048 PSS signature VALID (salt {len(salt)} bytes)")
        key, iv = salt[:16].hex(), salt[16:32].hex()
        enc = bytes(buf[PAYLOAD:])
        enc = enc[:len(enc) // 16 * 16]
        out = subprocess.run(["openssl", "enc", "-d", "-aes-128-cbc", "-nopad", "-K", key, "-iv", iv],
                             input=enc, capture_output=True, check=True).stdout
    else:
        if not pkcs1_md5_verify(msg, sig):
            sys.exit("RSA-1024 signature INVALID")
        print("RSA-1024 PKCS#1/MD5 signature VALID (plaintext payload)")
        out = bytes(buf[PAYLOAD:])
    i = out.find(b"UBI#")
    if i < 0:
        sys.exit("no UBI image found in payload")
    open(dst, "wb").write(out[i:])
    print(f"UBI image at payload+{i:#x}: {len(out) - i} bytes -> {dst}")


if __name__ == "__main__":
    main()
