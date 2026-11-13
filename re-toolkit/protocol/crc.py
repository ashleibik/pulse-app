"""
Checksums used by WHOOP 4.0 frames.  VERIFIED against 9 sample frames from [BW]
(see tests/test_crc.py).

A checksum (CRC) is a small number computed from the bytes of a message. The receiver
computes it again; if the numbers differ, the message got corrupted in transit.
(It's NOT security: anyone can recompute a CRC. It only catches accidents.)

The frame uses two of them:
    CRC-8   over the 2 length bytes   -> catches a corrupted length before we trust it
    CRC-32  over the inner bytes      -> catches corruption anywhere in the content

We implement both by hand (instead of only calling zlib) for two reasons:
    1. Learning: you can see exactly what a CRC does.
    2. The Swift port (Phase 5) needs the same algorithm, and these tests prove our
       version matches the standard one, so the Swift version can be tested against it too.
"""

# ----------------------------------------------------------------------------- CRC-8
# Parameters (source [OS] crc.dart, verified by us):
#   polynomial 0x07, init 0x00, no reflection, no final XOR  ("CRC-8/SMBUS")

def crc8(data: bytes) -> int:
    crc = 0x00
    for byte in data:
        crc ^= byte
        for _ in range(8):
            # If the top bit is set, shift left and XOR with the polynomial; otherwise just shift.
            if crc & 0x80:
                crc = ((crc << 1) ^ 0x07) & 0xFF
            else:
                crc = (crc << 1) & 0xFF
    return crc


# ---------------------------------------------------------------------------- CRC-32
# Standard IEEE 802.3 / zlib CRC-32 (the one in ZIP files and Ethernet).
#   polynomial 0x04C11DB7 (written "reflected" as 0xEDB88320), init 0xFFFFFFFF,
#   reflected in/out, final XOR 0xFFFFFFFF.
# Python's zlib.crc32() gives the same answer; tests check that.

def _make_crc32_table() -> list[int]:
    """Precompute the CRC of every possible byte value. Makes crc32() ~8x faster."""
    table = []
    for n in range(256):
        c = n
        for _ in range(8):
            c = (0xEDB88320 ^ (c >> 1)) if (c & 1) else (c >> 1)
        table.append(c)
    return table


_CRC32_TABLE = _make_crc32_table()


def crc32(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for byte in data:
        crc = _CRC32_TABLE[(crc ^ byte) & 0xFF] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFF
