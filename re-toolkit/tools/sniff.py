"""
sniff.py: connect to MY WHOOP 4.0, listen to everything it says, and log it with a label.

Run from the re-toolkit/ folder:

    python -m tools.sniff --scan                          # just list nearby bands
    python -m tools.sniff --label resting                 # connect + log (read-only queries only)
    python -m tools.sniff --label resting --hr-broadcast  # also enable standard HR (0x2A37) with RR
    python -m tools.sniff --label walking --realtime      # also ask for 0x28 realtime packets
    python -m tools.sniff --history                       # peek at the first batch of stored history (no ack)
    python -m tools.sniff --history --ack                 # download history, acking each batch AFTER saving it

While it runs, type into the terminal:
    <word> + Enter   change the label (e.g. "walking"); every later line is tagged with it
    b + Enter        ask for battery level
    q + Enter        quit cleanly (or press Ctrl+C)

Output: captures/<date>_<label>.jsonl (one JSON object per line; gitignored because it's health data).
Analyse it with tools/decode_helper.py.

Safety:
    * Only commands on the allowlist (protocol/constants.py) can be built at all.
    * By default only READ-ONLY queries are sent. Everything that changes band state needs a flag.
    * --hr-broadcast asks for confirmation (persistent setting) and is switched back off on exit.
    * History batches are never acked unless you pass --ack, and only after they're fsync'ed to disk.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

from bleak import BleakClient, BleakScanner
from bleak.backends.characteristic import BleakGATTCharacteristic

from protocol import constants as C
from protocol.frames import (
    FrameReassembler, SeqCounter, cmd_get_battery, cmd_get_clock, cmd_get_data_range,
    cmd_get_hello, cmd_history_ack, cmd_hr_broadcast, cmd_realtime_hr, cmd_report_version,
    cmd_send_historical_data, cmd_set_clock,
)
from protocol.parser import (
    CommandResponse, Event, HistoricalRecord, Metadata, RealtimeHR, Unknown, decode,
    parse_heart_rate_measurement, to_dict,
)

CAPTURE_DIR = Path(__file__).resolve().parent.parent / "captures"
COMMAND_GAP_S = 0.15        # pause between commands; [OS] spaces its start-up packets ~120 ms apart

# Never crash on a character the Windows console can't print.
sys.stdout.reconfigure(errors="replace")


# ======================================================================================
# Logging
# ======================================================================================

def iso(ts: float | int | None) -> str:
    if not ts:
        return "-"
    return datetime.fromtimestamp(ts, timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S")


def clean_label(text: str) -> str:
    return re.sub(r"[^a-z0-9_-]+", "_", text.strip().lower())[:32] or "unlabeled"


class CaptureLog:
    """Append-only JSON Lines file. Every record gets a timestamp and the current label."""

    def __init__(self, label: str) -> None:
        CAPTURE_DIR.mkdir(exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        self.path = CAPTURE_DIR / f"{stamp}_{label}.jsonl"
        self._f = open(self.path, "a", encoding="utf-8")
        self.label = label

    def write(self, kind: str, **fields) -> None:
        rec = {"t": round(time.time(), 3), "label": self.label, "kind": kind, **fields}
        self._f.write(json.dumps(rec, default=str) + "\n")
        self._f.flush()

    def fsync(self) -> None:
        """Force data onto the disk (not just the OS cache) before we ack history."""
        self._f.flush()
        os.fsync(self._f.fileno())

    def close(self) -> None:
        self.fsync()
        self._f.close()


# ======================================================================================
# Finding the band
# ======================================================================================

async def scan(seconds: float, address: str | None, show_all: bool):
    """Return [(device, adv, name)] sorted by signal strength, WHOOP-looking ones only."""
    print(f"Scanning {seconds:.0f}s... (wear the band; double-tap it if it doesn't show up)")
    found = await BleakScanner.discover(timeout=seconds, return_adv=True)
    out = []
    for dev, adv in found.values():
        name = adv.local_name or dev.name or ""
        uuids = [u.lower() for u in adv.service_uuids]
        looks_like_whoop = "whoop" in name.lower() or any(u.startswith(C.WHOOP_UUID_PREFIX) for u in uuids)
        if address and dev.address.lower() == address.lower():
            looks_like_whoop = True
        if looks_like_whoop or show_all:
            out.append((dev, adv, name))
    out.sort(key=lambda x: x[1].rssi, reverse=True)
    return out


# ======================================================================================
# Pretty one-line summaries for the console
# ======================================================================================

def summarize(obj) -> str:
    if isinstance(obj, RealtimeHR):
        return f"RT    hr={obj.hr:3d}  rr={obj.rr_ms}  wearing={obj.wearing}  ts={iso(obj.timestamp)}"
    if isinstance(obj, CommandResponse):
        detail = obj.decoded or (obj.body_hex[:48] + ("..." if len(obj.body_hex) > 48 else ""))
        return f"RESP  {obj.opcode_name} [{obj.status_name}]  {detail}"
    if isinstance(obj, Event):
        return f"EVENT {obj.event_name} at {iso(obj.timestamp)}  {obj.decoded or obj.body_hex[:40]}"
    if isinstance(obj, Metadata):
        return f"META  {obj.meta_name}  expected={obj.expected_packets}  token={obj.token_hex}"
    if isinstance(obj, HistoricalRecord):
        rr = f"  rr?={obj.rr_ms_unverified}" if obj.rr_ms_unverified else ""
        return f"HIST  v{obj.version} #{obj.counter} {iso(obj.timestamp)} hr={obj.hr} acc={obj.accel_g}{rr}"
    if isinstance(obj, Unknown):
        return f"???   {obj.type_name} len={len(obj.inner_hex) // 2}  {obj.inner_hex[:56]}"
    return repr(obj)


# ======================================================================================
# The sniffer
# ======================================================================================

class Sniffer:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.log = CaptureLog(clean_label(args.label))
        self.seq = SeqCounter()
        self.client: BleakClient | None = None
        self.cmd_char: BleakGATTCharacteristic | None = None
        self.loop = asyncio.get_running_loop()
        self.notifications: asyncio.Queue = asyncio.Queue()
        self.lines: asyncio.Queue = asyncio.Queue()
        self.reassemblers: dict[int, FrameReassembler] = {}   # one per characteristic handle
        self.write_lock = asyncio.Lock()
        self.stop = asyncio.Event()
        self.hr_broadcast_on = False
        self.realtime_on = False
        self.history_records = 0
        self.history_batches = 0

    # ------------------------------------------------------------------ main flow
    async def run(self) -> None:
        a = self.args
        found = await scan(a.scan_time, a.address, show_all=False)
        if not found:
            print("No WHOOP band found. Tips: band charged? not connected to another phone? "
                  "Try --scan --all to see every device.")
            return
        dev, adv, name = found[0]
        print(f"Connecting to {name or '?'} [{dev.address}] RSSI {adv.rssi} ...")
        self.log.write("session", device_name=name, address=dev.address, rssi=adv.rssi, args=vars(a))

        async with BleakClient(dev, disconnected_callback=self._on_disconnect,
                               timeout=30, pair=a.pair) as client:
            self.client = client
            print(f"Connected. MTU={client.mtu_size}. Logging to {self.log.path}")
            consumer: asyncio.Task | None = None
            try:
                await self._dump_gatt()
                await self._read_all_readable()
                await self._subscribe_all()
                consumer = asyncio.create_task(self._consume())
                await self._startup_commands()
                self._start_stdin_thread()
                print(f"\nListening. Label = '{self.log.label}'. Type a new label + Enter, 'b' battery, 'q' quit.\n")
                await self._wait_until_done()
            except asyncio.CancelledError:
                print("\nCtrl+C: stopping...")
            finally:
                await self._cleanup()      # turn off what we turned on, while still connected
                if consumer:
                    consumer.cancel()
        self.log.close()
        print(f"Saved {self.log.path}")

    # ------------------------------------------------------------------ GATT discovery
    async def _dump_gatt(self) -> None:
        """Print + log every service/characteristic. This settles the UUID questions in PROTOCOL.md."""
        print("\nGATT table:")
        table = []
        for svc in self.client.services:
            print(f"  service {svc.uuid}  ({svc.description})")
            for ch in svc.characteristics:
                print(f"    char {ch.uuid}  handle={ch.handle:<4} {','.join(ch.properties):<32} {C.char_name(ch.uuid)}")
                table.append({"service": svc.uuid, "char": ch.uuid, "handle": ch.handle, "props": ch.properties})
                if ch.uuid.lower() == C.CHAR_CMD_TO_STRAP:
                    self.cmd_char = ch
        self.log.write("gatt", table=table)
        if self.cmd_char is None:
            raise RuntimeError("Command characteristic 61080002 not found. Is this a WHOOP 4.0?")

    async def _read_all_readable(self) -> None:
        """Reading is harmless. Standard chars like Firmware Revision (2a26) may answer the firmware question."""
        for svc in self.client.services:
            for ch in svc.characteristics:
                if "read" not in ch.properties:
                    continue
                try:
                    val = bytes(await self.client.read_gatt_char(ch))
                except Exception as e:  # some reads need pairing; log and move on
                    self.log.write("read_error", char=ch.uuid, error=str(e))
                    continue
                text = val.decode("ascii") if val and all(32 <= b < 127 for b in val) else ""
                shown = repr(text) if text else ""
                print(f"  read {C.char_name(ch.uuid):<10} {ch.uuid[:8]}: {val.hex()}  {shown}")
                self.log.write("read", char=ch.uuid, hex=val.hex(), text=text)

    async def _subscribe_all(self) -> None:
        for svc in self.client.services:
            for ch in svc.characteristics:
                if "notify" in ch.properties or "indicate" in ch.properties:
                    try:
                        await self.client.start_notify(ch, self._on_notify)
                        self.reassemblers[ch.handle] = FrameReassembler()
                        print(f"  subscribed {C.char_name(ch.uuid)} ({ch.uuid[:8]})")
                    except Exception as e:
                        print(f"  could not subscribe {ch.uuid[:8]}: {e}")
                        self.log.write("subscribe_error", char=ch.uuid, error=str(e))

    # ------------------------------------------------------------------ sending
    async def _send(self, frame: bytes, what: str) -> None:
        async with self.write_lock:
            self.log.write("tx", what=what, hex=frame.hex())
            if self.args.verbose:
                print(f"  -> {what}: {frame.hex()}")
            try:
                await self.client.write_gatt_char(self.cmd_char, frame, response=True)
            except Exception as e:
                print(f"  !! write failed for {what}: {e}\n     (if this says access denied / not authenticated, retry with --pair)")
                self.log.write("tx_error", what=what, error=str(e))
            await asyncio.sleep(COMMAND_GAP_S)

    async def _confirm(self, question: str) -> bool:
        if self.args.yes:
            return True
        answer = await asyncio.to_thread(input, f"{question} [y/N] ")
        return answer.strip().lower() in ("y", "yes")

    async def _startup_commands(self) -> None:
        a = self.args
        print("\nRead-only queries:")
        await self._send(cmd_get_hello(self.seq.next()), "GET_HELLO_HARVARD")
        await self._send(cmd_report_version(self.seq.next()), "REPORT_VERSION_INFO")
        await self._send(cmd_get_battery(self.seq.next()), "GET_BATTERY_LEVEL")
        await self._send(cmd_get_clock(self.seq.next()), "GET_CLOCK")
        await self._send(cmd_get_data_range(self.seq.next()), "GET_DATA_RANGE")
        await asyncio.sleep(1.0)   # let the answers print before any prompt

        if a.set_clock:
            await self._send(cmd_set_clock(self.seq.next()), "SET_CLOCK")
        if a.hr_broadcast:
            if await self._confirm("Enable HR broadcast? This is saved on the band; I'll turn it off when we exit."):
                await self._send(cmd_hr_broadcast(True, self.seq.next()), "HR_BROADCAST_ON")
                self.hr_broadcast_on = True
        if a.realtime:
            await self._send(cmd_realtime_hr(True, self.seq.next()), "REALTIME_HR_ON")
            self.realtime_on = True
        if a.history:
            if a.ack and not await self._confirm(
                    "--ack tells the band each batch was received; it may then free that storage. Continue?"):
                a.ack = False
            mode = "ACKing after each save" if a.ack else "peek only, NOT acking"
            print(f"Requesting stored history ({mode})...")
            await self._send(cmd_send_historical_data(self.seq.next()), "SEND_HISTORICAL_DATA")

    # ------------------------------------------------------------------ receiving
    def _on_notify(self, char: BleakGATTCharacteristic, data: bytearray) -> None:
        # Called by bleak for every notification. Hand it to the event loop thread-safely and
        # return fast. The real work happens in _consume().
        self.loop.call_soon_threadsafe(self.notifications.put_nowait, (char, bytes(data)))

    async def _consume(self) -> None:
        while True:
            char, data = await self.notifications.get()
            uuid = char.uuid.lower()
            self.log.write("rx", char=uuid, handle=char.handle, hex=data.hex())

            if uuid == C.CHAR_HEART_RATE_MEASUREMENT:
                hrm = parse_heart_rate_measurement(data)
                self.log.write("hrm", **hrm)
                print(f"[{self.log.label}] HRM   hr={hrm['hr']:3d}  rr_ms={hrm['rr_ms']}")
                continue

            if not uuid.startswith(C.WHOOP_UUID_PREFIX):
                print(f"[{self.log.label}] {uuid[:8]} {data.hex()}")
                continue

            for frame in self.reassemblers[char.handle].feed(data):
                await self._handle_frame(char, frame)

    async def _handle_frame(self, char, frame) -> None:
        name = C.char_name(char.uuid)
        if not frame.valid:
            self.log.write("frame", char=char.uuid, valid=False, hex=frame.raw.hex())
            print(f"[{self.log.label}] {name:<8} BAD CRC  {frame.raw.hex()[:60]}")
            return
        obj = decode(frame)
        self.log.write("frame", char=char.uuid, valid=True, type=frame.packet_type,
                       type_name=frame.type_name, hex=frame.raw.hex(), decoded=to_dict(obj))

        if isinstance(obj, HistoricalRecord):
            self.history_records += 1
            # thousands of these: print 1 in 60 unless verbose
            if not (self.args.verbose or self.history_records % 60 == 1):
                return
        print(f"[{self.log.label}] {name:<8} {summarize(obj)}")

        if isinstance(obj, Metadata):
            if obj.meta_type == C.MetaType.HISTORY_END and obj.token_hex:
                await self._on_history_batch_end(obj)
            elif obj.meta_type == C.MetaType.HISTORY_COMPLETE:
                print(f"History complete: {self.history_batches} batches, {self.history_records} records.")

    async def _on_history_batch_end(self, meta: Metadata) -> None:
        print(f"  batch done: {self.history_records} records so far "
              f"(band said this batch has {meta.expected_packets})")
        if not self.args.ack:
            print("  Not acking (peek mode). The band keeps this data and will resend it later.")
            return
        if self.args.max_batches and self.history_batches >= self.args.max_batches:
            print(f"  Reached --max-batches {self.args.max_batches}; not acking further.")
            return
        self.log.fsync()  # 1) make sure it's on disk ...
        await self._send(cmd_history_ack(bytes.fromhex(meta.token_hex), self.seq.next()), "HISTORY_ACK")  # 2) ... then ack
        self.history_batches += 1

    # ------------------------------------------------------------------ keyboard input
    def _start_stdin_thread(self) -> None:
        # input() blocks, so it runs in a daemon thread (daemon = won't keep Python alive on exit).
        def reader():
            for line in sys.stdin:
                self.loop.call_soon_threadsafe(self.lines.put_nowait, line)
            self.loop.call_soon_threadsafe(self.lines.put_nowait, None)
        threading.Thread(target=reader, daemon=True).start()

    async def _handle_lines(self) -> None:
        while True:
            line = await self.lines.get()
            if line is None or line.strip().lower() in ("q", "quit", "exit"):
                self.stop.set()
                return
            cmd = line.strip()
            if not cmd:
                continue
            if cmd.lower() == "b":
                await self._send(cmd_get_battery(self.seq.next()), "GET_BATTERY_LEVEL")
                continue
            self.log.label = clean_label(cmd)
            self.log.write("label", label=self.log.label)
            print(f"--- label is now '{self.log.label}' ---")

    async def _wait_until_done(self) -> None:
        waiters = [asyncio.create_task(self.stop.wait()), asyncio.create_task(self._handle_lines())]
        if self.args.duration:
            waiters.append(asyncio.create_task(asyncio.sleep(self.args.duration)))
        _, pending = await asyncio.wait(waiters, return_when=asyncio.FIRST_COMPLETED)
        for t in pending:
            t.cancel()

    def _on_disconnect(self, _client) -> None:
        print("\n!! Band disconnected.")
        self.log.write("disconnected")
        self.loop.call_soon_threadsafe(self.stop.set)

    # ------------------------------------------------------------------ cleanup
    async def _cleanup(self) -> None:
        """Put the band back the way we found it."""
        if not (self.client and self.client.is_connected):
            return
        if self.realtime_on:
            await self._send(cmd_realtime_hr(False, self.seq.next()), "REALTIME_HR_OFF")
        if self.hr_broadcast_on and not self.args.leave_hr_on:
            await self._send(cmd_hr_broadcast(False, self.seq.next()), "HR_BROADCAST_OFF")
        await asyncio.sleep(0.5)  # let final responses arrive


# ======================================================================================
# CLI
# ======================================================================================

def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Log everything my WHOOP 4.0 says over BLE.")
    p.add_argument("--label", default="unlabeled", help="what you're doing: resting, walking, sleeping...")
    p.add_argument("--scan", action="store_true", help="only scan and list bands, don't connect")
    p.add_argument("--all", action="store_true", help="with --scan: list every BLE device, not just WHOOPs")
    p.add_argument("--scan-time", type=float, default=8.0)
    p.add_argument("--address", help="connect to this address (the band's address is random and may change)")
    p.add_argument("--pair", action="store_true", help="pair/bond while connecting (needed if writes are refused)")
    p.add_argument("--duration", type=float, help="stop after N seconds")
    p.add_argument("--hr-broadcast", action="store_true", help="enable standard HR 0x2A37 (asks first)")
    p.add_argument("--leave-hr-on", action="store_true", help="don't turn HR broadcast off on exit")
    p.add_argument("--realtime", action="store_true", help="enable 0x28 realtime packets")
    p.add_argument("--set-clock", action="store_true", help="set the band's clock to this computer's time")
    p.add_argument("--history", action="store_true", help="request stored history")
    p.add_argument("--ack", action="store_true", help="with --history: ack batches (after saving) to get more")
    p.add_argument("--max-batches", type=int, default=0, help="with --ack: stop acking after N batches")
    p.add_argument("-y", "--yes", action="store_true", help="don't ask for confirmations")
    p.add_argument("-v", "--verbose", action="store_true", help="print every packet and every command sent")
    return p.parse_args(argv)


async def main_async(args) -> None:
    if args.scan:
        for dev, adv, name in await scan(args.scan_time, args.address, args.all):
            print(f"  {adv.rssi:>4} dBm  {dev.address}  {name or '?':<24} {', '.join(adv.service_uuids)}")
        return
    await Sniffer(args).run()


def main() -> None:
    try:
        asyncio.run(main_async(parse_args()))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
