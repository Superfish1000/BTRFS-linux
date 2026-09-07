#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
Dump the RAID56 write-intent log blocks of btrfs device images or block
devices (see fs/btrfs/raid56-wib.h for the on-disk layout).

Usage: raid56_wib_dump.py <device-or-image>...

The checksum is verified with the checksum type of the primary superblock
(crc32c, xxhash64 if the xxhash module is available, sha256, blake2b).
"""

import hashlib
import struct
import sys

OFFSET = 512 * 1024
SLOT_SIZE = 4096
NR_SLOTS = 2
MAGIC = 0x4c49575f36354952
HEADER = struct.Struct("<32s16sQQIIQ6Q")   # csum, fsid, magic, seq, nr, shift, flags, reserved
ENTRY = struct.Struct("<QQQ")               # bytenr, bitmap, error
SUPER_OFFSET = 64 * 1024
SUPER_MAGIC = b"_BHRfS_M"
CSUM_NAMES = {0: "crc32c", 1: "xxhash64", 2: "sha256", 3: "blake2b"}


def crc32c(data):
    # btrfs csum type 0 (crc32c) with the ~0 seed / final inversion, as in the kernel.
    try:
        import crc32c as _c
        return _c.crc32c(data).to_bytes(4, "little")
    except ImportError:
        pass
    poly = 0x82F63B78
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ (poly & -(crc & 1))
    return (crc ^ 0xFFFFFFFF).to_bytes(4, "little")


def checksum(csum_type, data):
    """Return the checksum bytes, or None if the type cannot be computed here."""
    if csum_type == 0:
        return crc32c(data)
    if csum_type == 1:
        try:
            import xxhash
            return xxhash.xxh64(data).intdigest().to_bytes(8, "little")
        except ImportError:
            return None
    if csum_type == 2:
        return hashlib.sha256(data).digest()
    if csum_type == 3:
        return hashlib.blake2b(data, digest_size=32).digest()
    return None


def read_csum_type(f):
    f.seek(SUPER_OFFSET)
    sb = f.read(4096)
    if sb[0x40:0x48] != SUPER_MAGIC:
        return None
    return struct.unpack_from("<H", sb, 0xc4)[0]


def dump(path):
    with open(path, "rb") as f:
        csum_type = read_csum_type(f)
        if csum_type is None:
            print(f"{path}: no btrfs superblock, assuming crc32c")
            csum_type = 0
        for slot in range(NR_SLOTS):
            f.seek(OFFSET + slot * SLOT_SIZE)
            blk = f.read(SLOT_SIZE)
            csum, fsid, magic, seq, nr, shift, flags = HEADER.unpack_from(blk)[:7]
            if magic != MAGIC:
                print(f"{path} slot {slot}: no log block (magic 0x{magic:x})")
                continue
            calc = checksum(csum_type, blk[32:])
            if calc is None:
                state = f"unverified ({CSUM_NAMES.get(csum_type, csum_type)})"
            else:
                state = "OK" if csum[:len(calc)] == calc else "BAD"
            print(f"{path} slot {slot}: seq {seq} entries {nr} block_shift {shift} "
                  f"fsid {fsid.hex()} csum {state}")
            for i in range(min(nr, (SLOT_SIZE - HEADER.size) // ENTRY.size)):
                bytenr, bitmap, error = ENTRY.unpack_from(blk, HEADER.size + ENTRY.size * i)
                blocks = [bytenr + (b << shift) for b in range(64) if (bitmap | error) & (1 << b)]
                print(f"    region {bytenr} inflight 0x{bitmap:016x} error 0x{error:016x} "
                      f"-> {len(blocks)} dirty 64K blocks"
                      + (f" starting at {blocks[0]}" if blocks else ""))


if __name__ == "__main__":
    for p in sys.argv[1:]:
        dump(p)
