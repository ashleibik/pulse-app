"""
Turning valid frames into meaningful data.

decode(frame) looks at the packet type and returns one of the dataclasses below.
Anything we don't understand comes back as `Unknown` with the raw bytes. We never
guess silently.

All offsets are into frame.inner (inner[0] = packet type). Each field carries the
confidence tag from docs/PROTOCOL.md.
"""

from __future__ import annotations

import struct
from dataclasses import asdict, dataclass, field
from typing import Any

from .constants import (
    Cmd, EventId, MetaType, PacketType, ResponseStatus, enum_name, plausible_unix,
)
from .frames import Frame

RR_MIN_MS, RR_MAX_MS = 200, 2500   # 300 bpm .. 24 bpm. Anything outside is an artifact.


# ======================================================================================
# Result types
# ======================================================================================

@dataclass
class RealtimeHR:
    """PacketType.REALTIME_DATA (0x28). Layout REPORTED [OS] live.dart, consistent with [BW] sample."""
    kind: str = field(default="realtime_hr", init=False)
    timestamp: int = 0          # inner[2:6]  u32 unix seconds
    subsec: int = 0             # inner[6:8]  u16 (1/32768 s?)  UNKNOWN units
    hr: int = 0                 # inner[8]    bpm, 0 = no reading / off wrist
    rr_ms: list[int] = field(default_factory=list)  # inner[9]=count, inner[10+2i] i16 ms (max 4)
    wearing: bool | None = None  # inner[18]  REPORTED


@dataclass
class CommandResponse:
    """PacketType.COMMAND_RESPONSE (0x24). Layout REPORTED [OS] control.dart."""
    kind: str = field(default="command_response", init=False)
    opcode: int = 0             # inner[2]  echoes the command we sent
    opcode_name: str = ""
    request_seq: int | None = None  # inner[3]
    status: int | None = None       # inner[4]  0 fail / 1 ok / 2 deferred / 3 not implemented
    status_name: str = ""
    body_hex: str = ""              # inner[5:]
    decoded: dict[str, Any] = field(default_factory=dict)


@dataclass
class Event:
    """PacketType.EVENT (0x30). Layout REPORTED [OS] control.dart."""
    kind: str = field(default="event", init=False)
    event_id: int = 0           # inner[2:4] u16
    event_name: str = ""
    timestamp: int = 0          # inner[4:8] u32
    subsec: int = 0             # inner[8:10]
    body_hex: str = ""          # inner[12 : 12+len], len = u16 at inner[10:12]
    decoded: dict[str, Any] = field(default_factory=dict)


@dataclass
class Metadata:
    """PacketType.METADATA (0x31). HISTORY_END layout REPORTED [OS], matches [BW] sample."""
    kind: str = field(default="metadata", init=False)
    meta_type: int = 0          # inner[2]
    meta_name: str = ""
    timestamp: int | None = None        # inner[3:7]   (HISTORY_END only)
    expected_packets: int | None = None  # inner[9:13]
    token_hex: str | None = None         # inner[13:21] 8 bytes, echoed back in the ack


@dataclass
class HistoricalRecord:
    """
    PacketType.HISTORICAL_DATA (0x2F): one stored ~1 Hz record.
    Field offsets REPORTED [OS] (R24 / R12 layouts). Only partly decoded.
    """
    kind: str = field(default="history_record", init=False)
    version: int = 0            # inner[1]   record version (e.g. 12, 24)
    counter: int = 0            # inner[3:7]
    timestamp: int = 0          # inner[7:11]
    subsec: int = 0             # inner[11:13]
    hr: int = 0                 # inner[17]  0 = off wrist
    accel_g: tuple[float, float, float] | None = None  # inner[36:48] 3x float32 (gravity vector)
    # UNKNOWN: does history contain RR? We try the layout R10 records use (count at [18],
    # i16 ms at [19+2i]). If the values look sane we report them, clearly labelled as a guess.
    rr_ms_unverified: list[int] = field(default_factory=list)
    length: int = 0


@dataclass
class Unknown:
    kind: str = field(default="unknown", init=False)
    packet_type: int = 0
    type_name: str = ""
    inner_hex: str = ""


# ======================================================================================
# Decoding
# ======================================================================================

def _u16(b: bytes, off: int) -> int:
    return struct.unpack_from("<H", b, off)[0]


def _u32(b: bytes, off: int) -> int:
    return struct.unpack_from("<I", b, off)[0]


def _rr_list(inner: bytes, count_off: int, max_count: int = 4) -> list[int]:
    """Read `count` little-endian int16 RR values after a count byte, dropping impossible ones."""
    if len(inner) <= count_off:
        return []
    count = inner[count_off]
    if count > max_count:
        return []
    out = []
    for i in range(count):
        off = count_off + 1 + 2 * i
        if off + 2 > len(inner):
            break
        v = struct.unpack_from("<h", inner, off)[0]
        if RR_MIN_MS <= v <= RR_MAX_MS:
            out.append(v)
    return out


def decode_realtime(inner: bytes) -> RealtimeHR | None:
    if len(inner) < 10:
        return None
    return RealtimeHR(
        timestamp=_u32(inner, 2),
        subsec=_u16(inner, 6),
        hr=inner[8],
        rr_ms=_rr_list(inner, 9),
        wearing=bool(inner[18]) if len(inner) > 18 else None,
    )


def decode_command_response(inner: bytes) -> CommandResponse:
    r = CommandResponse(opcode=inner[2] if len(inner) > 2 else -1)
    r.opcode_name = enum_name(Cmd, r.opcode)
    if len(inner) > 3:
        r.request_seq = inner[3]
    if len(inner) > 4:
        r.status = inner[4]
        r.status_name = enum_name(ResponseStatus, r.status)
    r.body_hex = inner[5:].hex()

    # Per-command decoding. Each is REPORTED [OS] until we see it on my band.
    if r.opcode == Cmd.GET_BATTERY_LEVEL and len(inner) >= 7:
        pct = _u16(inner, 5) / 10           # gen4: deci-percent
        if 0 <= pct <= 100:
            r.decoded["battery_pct"] = round(pct, 1)
    elif r.opcode == Cmd.GET_CLOCK and len(inner) >= 9:
        ts = _u32(inner, 5)
        r.decoded["band_clock"] = ts if plausible_unix(ts) else None
        r.decoded["band_clock_raw"] = ts
    elif r.opcode == Cmd.GET_DATA_RANGE and len(inner) >= 38:
        r.decoded.update(
            write_page=_u32(inner, 14), trim_page=_u32(inner, 18), wrap_count=_u32(inner, 22),
            capacity_pages=_u32(inner, 26), used_records=_u32(inner, 30), free_records=_u32(inner, 34),
        )
        if len(inner) >= 66:
            oldest, newest = _u32(inner, 38), _u32(inner, 62)
            if plausible_unix(oldest) and plausible_unix(newest):
                r.decoded.update(oldest_record=oldest, newest_record=newest)
    elif r.opcode == Cmd.REPORT_VERSION_INFO:
        # UNKNOWN layout. Nobody has published it for gen4. We show readable text if there is
        # any, and leave the rest to decode_helper + your eyes.
        text = "".join(chr(c) if 32 <= c < 127 else "." for c in inner[5:])
        r.decoded["ascii_view"] = text
    return r


def decode_event(inner: bytes) -> Event | None:
    if len(inner) < 12:
        return None
    e = Event(event_id=_u16(inner, 2), timestamp=_u32(inner, 4), subsec=_u16(inner, 8))
    e.event_name = enum_name(EventId, e.event_id)
    body_len = _u16(inner, 10)
    body = inner[12: 12 + body_len]
    e.body_hex = body.hex()
    if e.event_id == EventId.BATTERY_LEVEL and len(body) >= 10:
        pct = _u32(body, 1) / 10
        if 0 <= pct <= 100:
            e.decoded["battery_pct"] = round(pct, 1)
            mv = _u32(body, 5)
            if 2500 <= mv <= 4500:
                e.decoded["battery_mv"] = mv
            e.decoded["charging"] = body[9] != 0
    return e


def decode_metadata(inner: bytes) -> Metadata:
    m = Metadata(meta_type=inner[2] if len(inner) > 2 else -1)
    m.meta_name = enum_name(MetaType, m.meta_type)
    if m.meta_type == MetaType.HISTORY_END:
        if len(inner) >= 7 and plausible_unix(_u32(inner, 3)):
            m.timestamp = _u32(inner, 3)
        if len(inner) >= 13:
            m.expected_packets = _u32(inner, 9)
        if len(inner) >= 21:
            m.token_hex = inner[13:21].hex()
    return m


def decode_history(inner: bytes) -> HistoricalRecord | None:
    if len(inner) < 18:
        return None
    rec = HistoricalRecord(
        version=inner[1], counter=_u32(inner, 3), timestamp=_u32(inner, 7),
        subsec=_u16(inner, 11), hr=inner[17], length=len(inner),
    )
    if len(inner) >= 48:
        x, y, z = struct.unpack_from("<3f", inner, 36)
        mag2 = x * x + y * y + z * z
        if 0.25 <= mag2 <= 3.24:   # 0.5 g .. 1.8 g: a sane gravity vector ([OS] uses the same gate)
            rec.accel_g = (round(x, 4), round(y, 4), round(z, 4))
    rec.rr_ms_unverified = _rr_list(inner, 18)
    return rec


def decode(frame: Frame):
    """Decode one frame. Call only on frame.valid frames."""
    inner = frame.inner
    t = frame.packet_type
    result = None
    if t == PacketType.REALTIME_DATA:
        result = decode_realtime(inner)
    elif t == PacketType.COMMAND_RESPONSE:
        result = decode_command_response(inner)
    elif t == PacketType.EVENT:
        result = decode_event(inner)
    elif t == PacketType.METADATA:
        result = decode_metadata(inner)
    elif t == PacketType.HISTORICAL_DATA:
        result = decode_history(inner)
    if result is None:
        result = Unknown(packet_type=t, type_name=frame.type_name, inner_hex=inner.hex())
    return result


def to_dict(obj) -> dict:
    """Dataclass -> plain dict (for JSON logs)."""
    return asdict(obj)


# ======================================================================================
# Standard Heart Rate Measurement (0x2A37)
# Bluetooth SIG spec, not WHOOP-specific, so CONFIRMED by the official specification:
# https://www.bluetooth.com/specifications/specs/heart-rate-service-1-0/
# ======================================================================================

def parse_heart_rate_measurement(data: bytes) -> dict:
    """
    flags (1 byte):
        bit 0     HR format: 0 = uint8, 1 = uint16
        bit 1-2   sensor contact status
        bit 3     energy expended present (uint16, skip it)
        bit 4     RR intervals present (uint16 each, units of 1/1024 s)
    """
    data = bytes(data)
    flags = data[0]
    i = 1
    if flags & 0x01:
        hr = _u16(data, i)
        i += 2
    else:
        hr = data[i]
        i += 1
    contact = None
    if flags & 0x04:                 # contact status is supported
        contact = bool(flags & 0x02)
    if flags & 0x08:
        i += 2                       # skip energy expended
    rr_ms: list[float] = []
    if flags & 0x10:
        while i + 1 < len(data):
            rr_1024 = _u16(data, i)
            rr_ms.append(round(rr_1024 * 1000 / 1024, 1))  # convert 1/1024 s -> ms
            i += 2
    return {"kind": "hrm_2a37", "hr": hr, "contact": contact, "rr_ms": rr_ms}
