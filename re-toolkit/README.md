# re-toolkit

Python tools for reverse-engineering my WHOOP 4.0's Bluetooth protocol. `protocol/` is the **source of truth**:
the iOS app's Swift port must give byte-identical results.

```
protocol/   constants.py  UUIDs, packet types, opcodes, the command ALLOWLIST
            crc.py        CRC-8 / CRC-32 (hand-written, tested against zlib)
            frames.py     build/parse frames, reassemble split notifications, command builders
            parser.py     frame -> RealtimeHR / CommandResponse / Event / Metadata / HistoricalRecord
metrics/    Python reference of docs/METRICS.md (HRV, sleep, strain, recovery)
tools/      sniff.py          connect, subscribe to everything, log labelled JSONL captures
            decode_helper.py  compare captures to map unknown bytes
            make_metric_vectors.py  writes shared/test-vectors/metrics_v1.json (Swift parity tests read it)
            whoop_live.py     (your original script, still to be added)
tests/      unit tests + fixtures/sample_frames.json (real frames from other researchers)
docs/       PROTOCOL.md (what we know, with confidence tags) · CAPTURE_GUIDE.md
captures/   your recordings (gitignored: it's health data)
```

## Setup (Windows, PowerShell)

```powershell
cd re-toolkit
python -m venv .venv
.\.venv\Scripts\Activate.ps1          # if blocked: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
pip install -r requirements.txt
python -m pytest                      # 42 tests should pass
```

## First session with the band

```powershell
python -m tools.sniff --scan
python -m tools.sniff --label first_contact --duration 60
```
This sends **read-only** queries (hello, version, battery, clock, data range), prints the real GATT table, and logs
everything for 60 s. Copy the firmware version, service UUID and battery into PROTOCOL.md §11.

Then:
```powershell
python -m tools.sniff --label resting --hr-broadcast --realtime   # type labels as you change activity; q to quit
python -m tools.decode_helper summary captures/*.jsonl
python -m tools.decode_helper hr captures/<file>.jsonl --type 0x28
python -m tools.sniff --history                                    # peek at stored history, no ack
```

See [docs/CAPTURE_GUIDE.md](docs/CAPTURE_GUIDE.md) for experiment design and phone-side capture.

## Troubleshooting
| Symptom | Try |
|---|---|
| Band not found | It may be connected to another phone. Turn that phone's Bluetooth off. Double-tap the band. `--scan --all` |
| `write failed ... access denied` | `--pair` (bonds this PC with the band) |
| Connects, but no packets at all | Firmware may be withholding data (PROTOCOL.md §11). Note the version and report back |
| Garbage timestamps (1970) | Band clock not set: `--set-clock` |
