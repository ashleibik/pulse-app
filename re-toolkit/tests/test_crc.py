"""The CRC tests are what moved the frame format from 'reported' to VERIFIED."""

import os
import struct
import zlib

from protocol.crc import crc8, crc32


def test_crc32_matches_zlib_on_random_data():
    for n in (0, 1, 3, 4, 17, 96, 1000):
        data = os.urandom(n)
        assert crc32(data) == zlib.crc32(data)


def test_crc32_standard_check_value():
    # Every CRC catalogue lists "check" = CRC of ASCII "123456789". For CRC-32 it's 0xCBF43926.
    assert crc32(b"123456789") == 0xCBF43926


def test_crc8_standard_check_value():
    # CRC-8/SMBUS (poly 0x07, init 0) check value is 0xF4.
    assert crc8(b"123456789") == 0xF4


def test_every_sample_frame_passes_both_crcs(samples):
    for name, raw in samples.items():
        assert crc8(raw[1:3]) == raw[3], f"{name}: CRC-8 of length failed"
        inner = raw[4:-4]
        assert crc32(inner) == struct.unpack("<I", raw[-4:])[0], f"{name}: CRC-32 failed"
