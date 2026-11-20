"""The 100 Hz motion stream: SEND_R10_R11_REALTIME (0x3F) and the REALTIME_RAW (0x2B) motion packet."""

import struct

from protocol.constants import ALLOWED_COMMANDS, KNOWN_DANGEROUS_COMMANDS, Cmd, PacketType
from protocol.frames import build_frame, cmd_raw_stream, parse_frame
from protocol.parser import RawMotion, Unknown, decode


def test_raw_stream_is_allowed_and_not_dangerous():
    assert Cmd.SEND_R10_R11_REALTIME in ALLOWED_COMMANDS
    assert Cmd.SEND_R10_R11_REALTIME not in KNOWN_DANGEROUS_COMMANDS
    on = parse_frame(cmd_raw_stream(True, 5))
    off = parse_frame(cmd_raw_stream(False, 6))
    assert on.valid and on.inner[2] == 0x3F and on.inner[3] == 1
    assert off.valid and off.inner[2] == 0x3F and off.inner[3] == 0


def test_motion_packet_decodes_three_axes_of_100_samples():
    inner = bytearray(1920)
    inner[0] = PacketType.REALTIME_RAW
    struct.pack_into("<I", inner, 11, 1_795_000_000)
    inner[17] = 88
    x = list(range(-50, 50))
    struct.pack_into("<100h", inner, 85, *x)
    struct.pack_into("<100h", inner, 485, *([4096] * 100))
    packet = decode(parse_frame(build_frame(bytes(inner))))
    assert isinstance(packet, RawMotion)
    assert packet.timestamp == 1_795_000_000 and packet.hr == 88
    assert packet.accel[0] == x and packet.accel[1] == [0] * 100 and packet.accel[2] == [4096] * 100


def test_optical_variant_stays_unknown():
    inner = bytearray(1924)
    inner[0] = PacketType.REALTIME_RAW
    assert isinstance(decode(parse_frame(build_frame(bytes(inner)))), Unknown)
