import struct

from protocol.constants import Cmd, EventId, MetaType, PacketType
from protocol.frames import build_frame, parse_frame
from protocol.parser import (
    CommandResponse, Event, HistoricalRecord, Metadata, RealtimeHR, Unknown, decode,
    parse_heart_rate_measurement,
)


# ------------------------------------------------- real samples from [BW]

def test_realtime_sample(samples):
    r = decode(parse_frame(samples["realtime_packet"]))
    assert isinstance(r, RealtimeHR)
    assert r.timestamp == 1717930413       # 2024-06-09 UTC, a plausible capture date
    assert r.hr == 66
    # Layout says 1 RR value = 0x0667 = 1639 ms. That's long for 66 bpm (~909 ms).
    # Recorded as-is; Phase 1 captures will tell us whether the units are right.
    assert r.rr_ms == [1639]
    assert r.wearing is True


def test_history_end_sample_gives_token(samples):
    m = decode(parse_frame(samples["history_end"]))
    assert isinstance(m, Metadata)
    assert m.meta_type == MetaType.HISTORY_END
    assert m.timestamp == 0x66705CF6
    assert m.expected_packets == 0x43        # 67 records in this batch
    assert m.token_hex == "2e47010004000000"


def test_commands_decode_as_unknown_for_now(samples):
    # Phone->band commands aren't something we receive. They fall through to Unknown safely.
    assert isinstance(decode(parse_frame(samples["alarm_set"])), Unknown)


# ------------------------------------------------- synthetic packets (layouts per [OS])

def _frame(inner: bytes):
    return parse_frame(build_frame(inner))


def test_battery_response():
    inner = bytes([PacketType.COMMAND_RESPONSE, 0x09, Cmd.GET_BATTERY_LEVEL, 0x04, 0x01]) + struct.pack("<H", 765)
    r = decode(_frame(inner))
    assert isinstance(r, CommandResponse)
    assert r.opcode_name == "GET_BATTERY_LEVEL" and r.status_name == "OK" and r.request_seq == 4
    assert r.decoded["battery_pct"] == 76.5


def test_clock_response_rejects_unset_clock():
    inner = bytes([0x24, 0, Cmd.GET_CLOCK, 0, 1]) + struct.pack("<I", 12345)
    r = decode(_frame(inner))
    assert r.decoded["band_clock"] is None and r.decoded["band_clock_raw"] == 12345


def test_battery_event():
    body = b"\x00" + struct.pack("<I", 543) + struct.pack("<I", 3900) + b"\x01\x00\x00"
    inner = bytes([PacketType.EVENT, 0x00]) + struct.pack("<HIHH", EventId.BATTERY_LEVEL, 1_750_000_000, 0, len(body)) + body
    e = decode(_frame(inner))
    assert isinstance(e, Event) and e.event_name == "BATTERY_LEVEL"
    assert e.decoded == {"battery_pct": 54.3, "battery_mv": 3900, "charging": True}


def test_history_record():
    inner = bytearray(88)
    inner[0], inner[1] = PacketType.HISTORICAL_DATA, 24
    struct.pack_into("<I", inner, 3, 1001)            # counter
    struct.pack_into("<I", inner, 7, 1_750_000_000)   # timestamp
    inner[17] = 58                                    # HR
    struct.pack_into("<3f", inner, 36, 0.0, 0.0, 1.0)  # lying still: gravity on z
    rec = decode(_frame(bytes(inner)))
    assert isinstance(rec, HistoricalRecord)
    assert (rec.version, rec.counter, rec.timestamp, rec.hr) == (24, 1001, 1_750_000_000, 58)
    assert rec.accel_g == (0.0, 0.0, 1.0)


def test_history_record_with_crazy_accel_is_dropped():
    inner = bytearray(88)
    inner[0] = PacketType.HISTORICAL_DATA
    struct.pack_into("<3f", inner, 36, 50.0, 50.0, 50.0)
    assert decode(_frame(bytes(inner))).accel_g is None


# ------------------------------------------------- standard 0x2A37

def test_hrm_uint8_with_rr():
    d = parse_heart_rate_measurement(bytes([0x10, 64, 0x00, 0x04, 0x00, 0x03]))
    assert d["hr"] == 64
    assert d["rr_ms"] == [1000.0, 750.0]     # 1024/1024 s, 768/1024 s


def test_hrm_uint16_contact_and_energy():
    # flags: uint16 HR | contact supported+detected | energy present
    d = parse_heart_rate_measurement(bytes([0x01 | 0x06 | 0x08, 150, 0, 0x10, 0x00]))
    assert d == {"kind": "hrm_2a37", "hr": 150, "contact": True, "rr_ms": []}


def test_version_text_keeps_only_readable_runs():
    from protocol.frames import build_frame, parse_frame
    from protocol.parser import decode
    text = build_frame(bytes([0x24, 0x03, 0x07, 0x02, 0x01]) + b"41.17.4" + bytes([0, 1, 2]))
    binary = build_frame(bytes([0x24, 0x04, 0x07, 0x02, 0x01, 0x29, 0x00, 0x41, 0x00, 0x11, 0x23, 0x04, 0x00]))
    assert decode(parse_frame(text)).decoded["version_text"] == "41.17.4"
    assert decode(parse_frame(binary)).decoded["version_text"] is None
