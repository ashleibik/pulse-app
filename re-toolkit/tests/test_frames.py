import pytest

from protocol.constants import ALLOWED_COMMANDS, KNOWN_DANGEROUS_COMMANDS, Cmd, PacketType
from protocol.frames import (
    FrameReassembler, SeqCounter, UnsafeCommandError, build_command, build_frame,
    cmd_get_battery, cmd_history_ack, cmd_hr_broadcast, cmd_realtime_hr, cmd_set_clock,
    parse_frame,
)


# ---------------------------------------------------------------- building

def test_builders_reproduce_real_captures_byte_for_byte(samples):
    # Our builder vs. what the official app actually sent: identical bytes.
    assert cmd_hr_broadcast(True, seq=0x08) == samples["hr_broadcast_on_seq8"]
    assert cmd_hr_broadcast(False, seq=0x07) == samples["hr_broadcast_off_seq7"]
    assert cmd_hr_broadcast(False, seq=0x09) == samples["hr_broadcast_off_seq9"]
    assert cmd_realtime_hr(True, seq=0x8C) == samples["realtime_on_seq8c"]


def test_inner_is_padded_to_multiple_of_4():
    raw = cmd_get_battery(seq=1)            # inner = 23 01 1a  -> padded with one 00
    f = parse_frame(raw)
    assert f.valid and len(f.inner) % 4 == 0
    assert f.inner == bytes([0x23, 0x01, 0x1A, 0x00])


def test_history_ack_layout():
    token = bytes.fromhex("2e47010004000000")
    f = parse_frame(cmd_history_ack(token, seq=5))
    assert f.valid
    assert f.inner == bytes([0x23, 0x05, Cmd.HISTORICAL_DATA_RESULT, 0x01]) + token
    with pytest.raises(ValueError):
        cmd_history_ack(b"\x00" * 7, seq=0)


def test_set_clock_payload_is_exactly_8_bytes():
    f = parse_frame(cmd_set_clock(seq=0, when=1_700_000_000.5))
    assert f.opcode == Cmd.SET_CLOCK
    # 3 header bytes + 8 payload bytes = 11, padded to 12. Body = 8 payload + 1 pad byte.
    assert len(f.inner) == 12 and f.body[8:] == b"\x00"
    assert int.from_bytes(f.body[0:4], "little") == 1_700_000_000
    assert int.from_bytes(f.body[4:6], "little") == 16384      # 0.5 s * 32768


# ---------------------------------------------------------------- safety

@pytest.mark.parametrize("cmd", sorted(KNOWN_DANGEROUS_COMMANDS))
def test_dangerous_commands_are_refused(cmd):
    with pytest.raises(UnsafeCommandError):
        build_command(cmd)


def test_unknown_opcodes_are_refused():
    # Allowlist, not blocklist: an opcode nobody has documented is refused too.
    with pytest.raises(UnsafeCommandError):
        build_command(0xEE)


def test_allowlist_and_dangerous_list_do_not_overlap():
    assert not (ALLOWED_COMMANDS & KNOWN_DANGEROUS_COMMANDS)


def test_seq_counter_wraps():
    s = SeqCounter(start=254)
    assert [s.next(), s.next(), s.next()] == [254, 255, 0]


# ---------------------------------------------------------------- parsing

def test_parse_rejects_garbage_and_short_input():
    assert parse_frame(b"") is None
    assert parse_frame(b"\x00" * 12) is None              # wrong start byte
    assert parse_frame(bytes.fromhex("aa0800a82308")) is None  # truncated


def test_parse_flags_corrupted_payload(samples):
    raw = bytearray(samples["hr_broadcast_on_seq8"])
    raw[6] ^= 0xFF                      # flip bits in the opcode
    f = parse_frame(bytes(raw))
    assert f is not None and f.header_crc_ok and not f.payload_crc_ok and not f.valid


def test_frame_accessors(samples):
    f = parse_frame(samples["hr_broadcast_on_seq8"])
    assert (f.packet_type, f.seq, f.opcode, f.body) == (PacketType.COMMAND, 8, 0x0E, b"\x01")
    assert f.type_name == "COMMAND"


# ---------------------------------------------------------------- reassembly

def test_reassembler_handles_split_and_joined_notifications(samples):
    a, b = samples["realtime_packet"], samples["history_end"]
    stream = a + b
    r = FrameReassembler()
    out = []
    # feed in awkward 7-byte chunks, as if the MTU were tiny
    for i in range(0, len(stream), 7):
        out += r.feed(stream[i:i + 7])
    assert [f.raw for f in out] == [a, b]
    assert all(f.valid for f in out)


def test_reassembler_resyncs_after_junk(samples):
    a = samples["realtime_packet"]
    r = FrameReassembler()
    frames = r.feed(b"\x13\x37\xaa\x99" + a)     # junk, including a fake 0xAA
    assert [f.raw for f in frames] == [a]
    assert r.dropped_bytes == 4


def test_reassembler_skips_zero_padding_between_frames(samples):
    a = samples["realtime_packet"]
    r = FrameReassembler()
    assert len(r.feed(a + b"\x00\x00\x00" + a)) == 2
    assert r.dropped_bytes == 0


def test_reassembler_result_does_not_depend_on_chunk_size(samples):
    stream = b"\x13\x37\xaa\x99" + samples["realtime_packet"] + b"\x00\x00" + samples["history_end"]
    results = set()
    for size in (1, 2, 3, 5, 7, 20, 244):
        r = FrameReassembler()
        frames = []
        for i in range(0, len(stream), size):
            frames += r.feed(stream[i:i + size])
        results.add((tuple(f.raw for f in frames), r.dropped_bytes))
    assert len(results) == 1


def test_build_frame_roundtrip():
    for n in range(0, 40):
        inner = bytes(range(n))
        f = parse_frame(build_frame(inner))
        assert f.valid and f.inner[:n] == inner
