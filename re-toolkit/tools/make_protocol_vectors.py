"""
make_protocol_vectors.py: write shared/test-vectors/protocol_v1.json.

The Python protocol package (re-toolkit/protocol) is the source of truth. This script records
what it produces for a set of inputs: checksums, parsed frames, every command builder,
reassembly of split notifications, and decoded packets. The Swift port
(ios/PulseCore/Sources/PulseCore/Protocol) must reproduce every one of them.

    python -m tools.make_protocol_vectors          # from re-toolkit/
"""

from __future__ import annotations

import json
import random
import struct
from pathlib import Path

from protocol.constants import ALLOWED_COMMANDS, Cmd, EventId, MetaType, PacketType
from protocol.crc import crc8, crc32
from protocol.frames import (
    FrameReassembler, build_frame, cmd_get_battery, cmd_get_clock, cmd_get_data_range, cmd_get_hello,
    cmd_history_ack, cmd_hr_broadcast, cmd_raw_stream, cmd_realtime_hr, cmd_report_version, cmd_send_historical_data,
    cmd_set_clock, parse_frame,
)
from protocol.parser import decode, parse_heart_rate_measurement, to_dict

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "shared" / "test-vectors" / "protocol_v1.json"
SAMPLES = Path(__file__).resolve().parents[1] / "tests" / "fixtures" / "sample_frames.json"


def synthetic_packets() -> dict[str, bytes]:
    """Inner byte layouts from docs/PROTOCOL.md, wrapped into frames."""
    p: dict[str, bytes] = {}
    p["battery_response"] = build_frame(bytes([0x24, 0x09, Cmd.GET_BATTERY_LEVEL, 0x04, 0x01]) + struct.pack("<H", 765))
    p["battery_response_failed"] = build_frame(bytes([0x24, 0x0A, Cmd.GET_BATTERY_LEVEL, 0x05, 0x00]) + struct.pack("<H", 2000))
    p["clock_response"] = build_frame(bytes([0x24, 0x01, Cmd.GET_CLOCK, 0x03, 0x01]) + struct.pack("<I", 1_750_000_000))
    p["clock_response_unset"] = build_frame(bytes([0x24, 0x01, Cmd.GET_CLOCK, 0x03, 0x01]) + struct.pack("<I", 4242))
    dr = bytearray(66)
    dr[0], dr[1], dr[2], dr[3], dr[4], dr[5] = 0x24, 0x02, Cmd.GET_DATA_RANGE, 0x05, 0x01, 0x01
    for off, val in ((14, 900), (18, 120), (22, 3), (26, 4096), (30, 70000), (34, 50000),
                     (38, 1_749_000_000), (62, 1_750_000_000)):
        struct.pack_into("<I", dr, off, val)
    p["data_range_response"] = build_frame(bytes(dr))
    p["version_response"] = build_frame(bytes([0x24, 0x03, Cmd.REPORT_VERSION_INFO, 0x02, 0x01]) + b"41.17.4\x00\x01\x02")
    # Binary numbers only, with stray printable bytes ("A", "#"): no readable version text.
    p["version_response_binary"] = build_frame(bytes([0x24, 0x04, Cmd.REPORT_VERSION_INFO, 0x02, 0x01]) +
                                               bytes([0x29, 0x00, 0x41, 0x00, 0x11, 0x23, 0x04, 0x00, 0x02, 0x00, 0x00]))
    body = b"\x00" + struct.pack("<I", 543) + struct.pack("<I", 3900) + b"\x01\x00\x00"
    p["event_battery"] = build_frame(bytes([PacketType.EVENT, 0x00]) +
                                     struct.pack("<HIHH", EventId.BATTERY_LEVEL, 1_750_000_100, 7, len(body)) + body)
    p["event_wrist_off"] = build_frame(bytes([PacketType.EVENT, 0x01]) +
                                       struct.pack("<HIHH", EventId.WRIST_OFF, 1_750_000_200, 0, 0))
    p["event_too_short"] = build_frame(bytes([PacketType.EVENT, 0x01, 0x09, 0x00]))
    p["meta_history_start"] = build_frame(bytes([PacketType.METADATA, 0x00, MetaType.HISTORY_START]))
    p["meta_history_complete"] = build_frame(bytes([PacketType.METADATA, 0x00, MetaType.HISTORY_COMPLETE]))
    rec = bytearray(88)
    rec[0], rec[1] = PacketType.HISTORICAL_DATA, 24
    struct.pack_into("<I", rec, 3, 1001)
    struct.pack_into("<I", rec, 7, 1_750_000_000)
    struct.pack_into("<H", rec, 11, 16384)
    rec[17] = 58
    rec[18] = 2                                   # 2 RR values (layout unverified)
    struct.pack_into("<hh", rec, 19, 1032, 150)   # second one is impossible -> dropped
    struct.pack_into("<3f", rec, 36, 0.01, -0.02, 0.99)
    p["history_record"] = build_frame(bytes(rec))
    bad = bytearray(rec)
    struct.pack_into("<3f", bad, 36, 50.0, 50.0, 50.0)
    p["history_record_bad_accel"] = build_frame(bytes(bad))
    p["history_too_short"] = build_frame(bytes([PacketType.HISTORICAL_DATA, 12, 0, 0]))
    p["console_log"] = build_frame(bytes([PacketType.CONSOLE_LOGS, 0x00]) + b"hello")
    # REALTIME_RAW motion variant (NOOP's WHOOP 4 layout): 100 samples per axis, signed.
    raw = bytearray(1920)
    raw[0], raw[1], raw[2] = PacketType.REALTIME_RAW, 0x11, 0x0A
    struct.pack_into("<IH", raw, 11, 1_795_000_000, 16384)
    raw[17] = 92
    for start, scale in ((85, 37), (285, -11), (485, 5)):
        struct.pack_into("<100h", raw, start, *[4096 + scale * (i - 50) if start == 485 else scale * (i - 50) for i in range(100)])
    p["raw_motion"] = build_frame(bytes(raw))
    optical = bytearray(1924)
    optical[0] = PacketType.REALTIME_RAW
    p["raw_optical"] = build_frame(bytes(optical))
    return p


def build_vectors() -> dict:
    rng = random.Random(5)

    crc_cases = []
    for n in (0, 1, 2, 3, 7, 32, 96):
        data = bytes(rng.randrange(256) for _ in range(n))
        crc_cases.append({"hex": data.hex(), "crc8": crc8(data), "crc32": crc32(data)})

    samples = json.loads(SAMPLES.read_text(encoding="utf-8"))["frames"]
    raw_frames = {name: bytes.fromhex(f["hex"].replace(" ", "")) for name, f in samples.items()}
    corrupted = bytearray(raw_frames["hr_broadcast_on_seq8"])
    corrupted[6] ^= 0xFF
    raw_frames["corrupted_payload"] = bytes(corrupted)
    bad_header = bytearray(raw_frames["realtime_packet"])
    bad_header[3] ^= 0x01
    raw_frames["corrupted_header"] = bytes(bad_header)

    frames = []
    for name, raw in raw_frames.items():
        f = parse_frame(raw)
        frames.append({"name": name, "hex": raw.hex(), "parsed": f is not None,
                       "header_crc_ok": f.header_crc_ok if f else None,
                       "payload_crc_ok": f.payload_crc_ok if f else None,
                       "inner_hex": f.inner.hex() if f else None})
    for name, raw in (("too_short", bytes.fromhex("aa0800a82308")), ("wrong_start", bytes(12))):
        frames.append({"name": name, "hex": raw.hex(), "parsed": parse_frame(raw) is not None,
                       "header_crc_ok": None, "payload_crc_ok": None, "inner_hex": None})

    builders = [
        {"name": "hr_broadcast", "on": True, "seq": 8, "hex": cmd_hr_broadcast(True, 8).hex()},
        {"name": "hr_broadcast", "on": False, "seq": 7, "hex": cmd_hr_broadcast(False, 7).hex()},
        {"name": "realtime_hr", "on": True, "seq": 0x8C, "hex": cmd_realtime_hr(True, 0x8C).hex()},
        {"name": "realtime_hr", "on": False, "seq": 255, "hex": cmd_realtime_hr(False, 255).hex()},
        {"name": "raw_stream", "on": True, "seq": 0x21, "hex": cmd_raw_stream(True, 0x21).hex()},
        {"name": "raw_stream", "on": False, "seq": 1, "hex": cmd_raw_stream(False, 1).hex()},
        {"name": "report_version", "seq": 1, "hex": cmd_report_version(1).hex()},
        {"name": "get_battery", "seq": 2, "hex": cmd_get_battery(2).hex()},
        {"name": "get_clock", "seq": 3, "hex": cmd_get_clock(3).hex()},
        {"name": "get_hello", "seq": 0, "hex": cmd_get_hello(0).hex()},
        {"name": "get_data_range", "seq": 4, "hex": cmd_get_data_range(4).hex()},
        {"name": "send_historical_data", "seq": 5, "hex": cmd_send_historical_data(5).hex()},
        {"name": "set_clock", "seq": 6, "when": 1_750_000_000.25, "hex": cmd_set_clock(6, 1_750_000_000.25).hex()},
        {"name": "set_clock", "seq": 7, "when": 1_700_000_000.999, "hex": cmd_set_clock(7, 1_700_000_000.999).hex()},
        {"name": "history_ack", "seq": 9, "token": "2e47010004000000",
         "hex": cmd_history_ack(bytes.fromhex("2e47010004000000"), 9).hex()},
    ]

    # Reassembly: two frames + junk + zero padding, cut into awkward chunks.
    a, b = raw_frames["realtime_packet"], raw_frames["history_end"]
    stream = b"\x13\x37\xaa\x99" + a + b"\x00\x00" + b + a
    reassembly = []
    for size in (1, 5, 7, 20, 244):
        r = FrameReassembler()
        out = []
        chunks = [stream[i:i + size] for i in range(0, len(stream), size)]
        for c in chunks:
            out += r.feed(c)
        reassembly.append({"chunk_size": size, "stream_hex": stream.hex(),
                           "frames": [f.raw.hex() for f in out], "valid": [f.valid for f in out],
                           "dropped": r.dropped_bytes})

    decoded = []
    all_packets = {name: raw_frames[name] for name in ("realtime_packet", "history_end", "alarm_set")}
    all_packets.update(synthetic_packets())
    for name, raw in all_packets.items():
        f = parse_frame(raw)
        assert f is not None and f.valid, name
        decoded.append({"name": name, "hex": raw.hex(), "decoded": to_dict(decode(f))})

    hrm = []
    for raw in (bytes([0x10, 64, 0x00, 0x04, 0x00, 0x03]), bytes([0x01 | 0x06 | 0x08, 150, 0, 0x10, 0x00]),
                bytes([0x16, 58, 0x9A, 0x03]), bytes([0x00, 72])):
        hrm.append({"hex": raw.hex(), "decoded": parse_heart_rate_measurement(raw)})

    return {
        "protocol_version": 1,
        "generated_by": "re-toolkit/tools/make_protocol_vectors.py",
        "crc": crc_cases,
        "frames": frames,
        "builders": builders,
        "allowed_opcodes": sorted(int(c) for c in ALLOWED_COMMANDS),
        "refused_opcodes": sorted({c for c in range(256)} - {int(x) for x in ALLOWED_COMMANDS}),
        "reassembly": reassembly,
        "decode": decoded,
        "hrm": hrm,
    }


def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(build_vectors(), indent=1) + "\n", encoding="utf-8")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
