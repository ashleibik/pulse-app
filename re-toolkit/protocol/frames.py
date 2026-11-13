"""
Building and parsing WHOOP 4.0 frames.

Frame layout  (VERIFIED, see tests/test_frames.py):

    byte:  0      1   2       3        4 ...................... n-5   n-4 ... n-1
         +----+----------+---------+-------------------------------+--------------+
         | AA | len (LE) | CRC8    |  inner (padded to 4 bytes)    | CRC32 (LE)   |
         +----+----------+---------+-------------------------------+--------------+
                           of len    inner[0] = packet type
                                     inner[1] = seq (commands) / record version (data)
                                     inner[2] = opcode (commands/responses)
                                     inner[3:] = body

    len   = len(inner) + 4   (everything after the header, including the CRC32)
    CRC8  = crc8(len bytes)
    CRC32 = crc32(inner), stored little-endian
    inner is zero-padded to a multiple of 4 bytes  (REPORTED [OS] framing.dart,
          consistent with every [BW] sample)

"LE" = little-endian: the least significant byte comes first. 0x0008 is stored as 08 00.
"""

from __future__ import annotations

import struct
import time
from dataclasses import dataclass
from datetime import datetime

from .constants import (
    ALLOWED_COMMANDS, CRC32_LEN, HEADER_LEN, MAX_FRAME_LEN, SOF,
    Cmd, PacketType, enum_name,
)
from .crc import crc8, crc32


# ======================================================================================
# Parsing
# ======================================================================================

@dataclass(frozen=True)
class Frame:
    """One complete frame, plus whether its checksums passed."""
    raw: bytes            # the full frame, AA ... CRC32
    inner: bytes          # the bytes between header and CRC32 (still includes padding)
    header_crc_ok: bool
    payload_crc_ok: bool

    @property
    def valid(self) -> bool:
        return self.header_crc_ok and self.payload_crc_ok

    # Accessors return -1 / empty when the inner part is too short, so they never crash.
    @property
    def packet_type(self) -> int:
        return self.inner[0] if len(self.inner) > 0 else -1

    @property
    def seq(self) -> int:
        return self.inner[1] if len(self.inner) > 1 else -1

    @property
    def opcode(self) -> int:
        return self.inner[2] if len(self.inner) > 2 else -1

    @property
    def body(self) -> bytes:
        return self.inner[3:]

    @property
    def type_name(self) -> str:
        return enum_name(PacketType, self.packet_type)


def parse_frame(raw: bytes) -> Frame | None:
    """
    Parse exactly one frame from the start of `raw`.

    Returns None if `raw` doesn't hold a complete frame (wrong start byte, too short, or the
    declared length is nonsense). Returns a Frame with valid=False if the bytes are all there
    but a checksum fails. Callers should check frame.valid before trusting the contents.
    """
    raw = bytes(raw)
    if len(raw) < HEADER_LEN + CRC32_LEN or raw[0] != SOF:
        return None
    declared = struct.unpack_from("<H", raw, 1)[0]
    if declared < CRC32_LEN or HEADER_LEN + declared > MAX_FRAME_LEN:
        return None
    total = HEADER_LEN + declared
    if len(raw) < total:
        return None  # incomplete: wait for more bytes

    header_ok = crc8(raw[1:3]) == raw[3]
    inner = raw[HEADER_LEN: total - CRC32_LEN]
    stored_crc32 = struct.unpack_from("<I", raw, total - CRC32_LEN)[0]
    return Frame(
        raw=raw[:total],
        inner=inner,
        header_crc_ok=header_ok,
        payload_crc_ok=crc32(inner) == stored_crc32,
    )


class FrameReassembler:
    """
    Turns a stream of BLE notification chunks back into frames.

    Why we need it: one BLE notification holds at most MTU-3 bytes (often 20, up to ~244).
    A 96-byte history record can arrive in several pieces, and one notification can also
    hold the end of one frame plus the start of the next.

    How it works: keep a buffer, read the length from the header, and wait until that
    many bytes have arrived. If the header is garbage (bad start byte, or bad CRC-8 on
    the length), skip forward to the next 0xAA and try again. That's called "resyncing".
    We trust the length, not the 0xAA, because 0xAA can also appear inside data.

    One reassembler per characteristic, so streams don't mix.
    """

    MAX_BUFFER = 8192  # if we're this far behind, something is badly wrong: start over

    def __init__(self) -> None:
        self._buf = bytearray()
        self.dropped_bytes = 0  # how many junk bytes we skipped while resyncing (for diagnostics)

    def feed(self, chunk: bytes) -> list[Frame]:
        self._buf.extend(chunk)
        if len(self._buf) > self.MAX_BUFFER:
            self.dropped_bytes += len(self._buf)
            self._buf.clear()
            return []

        frames: list[Frame] = []
        while True:
            # 0) [OS] notes zero bytes may sit between records as padding: skip them (not "junk").
            #    Done at the top of the loop so the result doesn't depend on how BLE split the bytes.
            while self._buf and self._buf[0] == 0x00:
                del self._buf[0]
            if len(self._buf) < HEADER_LEN:
                break
            # 1) Find a plausible header.
            if self._buf[0] != SOF or crc8(self._buf[1:3]) != self._buf[3]:
                self._resync()
                continue
            declared = struct.unpack_from("<H", self._buf, 1)[0]
            if declared < CRC32_LEN or HEADER_LEN + declared > MAX_FRAME_LEN:
                self._resync()
                continue
            total = HEADER_LEN + declared
            # 2) Wait until the whole frame has arrived.
            if len(self._buf) < total:
                break
            # 3) Cut it out and parse it.
            frame = parse_frame(bytes(self._buf[:total]))
            del self._buf[:total]
            if frame is not None:
                frames.append(frame)
        return frames

    def _resync(self) -> None:
        """Drop the first byte, then skip ahead to the next 0xAA."""
        nxt = self._buf.find(bytes([SOF]), 1)
        cut = nxt if nxt != -1 else len(self._buf)
        self.dropped_bytes += cut
        del self._buf[:cut]


# ======================================================================================
# Building
# ======================================================================================

def pad4(data: bytes) -> bytes:
    """Zero-pad to a multiple of 4 bytes."""
    return data + b"\x00" * (-len(data) % 4)


def build_frame(inner: bytes) -> bytes:
    """Wrap inner bytes in header + CRC32. Use build_command() for commands."""
    inner = pad4(inner)
    length = struct.pack("<H", len(inner) + CRC32_LEN)
    return bytes([SOF]) + length + bytes([crc8(length)]) + inner + struct.pack("<I", crc32(inner))


class UnsafeCommandError(ValueError):
    """Raised when code tries to build a command that isn't on the allowlist."""


def build_command(cmd: int, payload: bytes = b"\x00", seq: int = 0) -> bytes:
    """
    Build a phone -> band command frame:  inner = [0x23, seq, opcode, *payload].

    SAFETY: refuses any opcode not in constants.ALLOWED_COMMANDS. There is deliberately
    no "force=True" override. To allow a new command, edit the allowlist in a commit.
    """
    if cmd not in ALLOWED_COMMANDS:
        raise UnsafeCommandError(
            f"Refusing to build command {enum_name(Cmd, cmd)} (0x{cmd:02x}): not on the allowlist. "
            "See constants.ALLOWED_COMMANDS."
        )
    inner = bytes([PacketType.COMMAND, seq & 0xFF, cmd & 0xFF]) + bytes(payload)
    return build_frame(inner)


class SeqCounter:
    """
    Rolling 0-255 sequence number for commands. [BW] reports the band doesn't check it,
    but responses echo it back (inner[3] of a response), which helps match replies.
    """

    def __init__(self, start: int = 0) -> None:
        self._n = start & 0xFF

    def next(self) -> int:
        n = self._n
        self._n = (self._n + 1) & 0xFF
        return n


# ----- Named command builders. These are the only ones the tools use. ------------------

def cmd_hr_broadcast(on: bool, seq: int) -> bytes:
    """
    Turn the standard Heart Rate Service (0x2A37) on/off.  VERIFIED: reproduces [BW]'s captures.
    Note: this is a *persistent* setting on the band ([OS] flags 0x0E as dangerous for that reason).
    """
    return build_command(Cmd.SET_GENERIC_HR_PROFILE, bytes([1 if on else 0]), seq)


def cmd_realtime_hr(on: bool, seq: int) -> bytes:
    """Start/stop ~1 Hz REALTIME_DATA (0x28) packets on the DATA characteristic.  VERIFIED vs [BW]."""
    return build_command(Cmd.TOGGLE_REALTIME_HR, bytes([1 if on else 0]), seq)


def cmd_report_version(seq: int) -> bytes:
    return build_command(Cmd.REPORT_VERSION_INFO, b"", seq)


def cmd_get_battery(seq: int) -> bytes:
    return build_command(Cmd.GET_BATTERY_LEVEL, b"", seq)


def cmd_get_clock(seq: int) -> bytes:
    return build_command(Cmd.GET_CLOCK, b"\x00", seq)


def cmd_get_hello(seq: int) -> bytes:
    """Gen4 'hello'. Part of the official app's start-up sequence ([OS] initPackets)."""
    return build_command(Cmd.GET_HELLO_HARVARD, b"\x00", seq)


def cmd_get_data_range(seq: int) -> bytes:
    """Ask what time range of history the band holds. Useful before syncing."""
    return build_command(Cmd.GET_DATA_RANGE, b"\x00", seq)


def cmd_set_clock(seq: int, when: datetime | float | None = None) -> bytes:
    """
    Set the band's clock.  REPORTED [OS]: payload = u32 seconds LE, u16 sub-seconds LE
    (units of 1/32768 s), then two zero bytes. Exactly 8 bytes: [OS] warns a wrong length
    is ACKed but ignored.
    """
    if when is None:
        ts = time.time()
    elif isinstance(when, datetime):
        ts = when.timestamp()
    else:
        ts = float(when)
    secs = int(ts)
    subsec = int((ts - secs) * 32768) & 0xFFFF
    return build_command(Cmd.SET_CLOCK, struct.pack("<IHxx", secs, subsec), seq)


def cmd_send_historical_data(seq: int) -> bytes:
    """Ask the band to start sending stored history.  CONFIRMED [BW][OS]."""
    return build_command(Cmd.SEND_HISTORICAL_DATA, b"\x00", seq)


def cmd_history_ack(token: bytes, seq: int) -> bytes:
    """
    Acknowledge one history batch so the band sends the next one.
    payload = 0x01 + the 8-byte token from the HISTORY_END metadata packet.  REPORTED [OS].

    ⚠ Only call this AFTER the batch is safely saved. After an ack the band considers that
      data delivered and may reuse the flash space.
    """
    if len(token) != 8:
        raise ValueError(f"history token must be 8 bytes, got {len(token)}")
    return build_command(Cmd.HISTORICAL_DATA_RESULT, b"\x01" + bytes(token), seq)
