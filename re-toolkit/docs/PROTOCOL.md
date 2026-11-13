# WHOOP 4.0 BLE Protocol: Working Notes

Living document. Every fact has a **confidence tag**:

| Tag | Meaning |
|---|---|
| ✅ **VERIFIED** | We checked it ourselves (math on sample packets, or a capture from my band) |
| 🟢 **CONFIRMED (2 sources)** | Two independent reference projects agree, not yet tested on my band |
| 🟡 **REPORTED (1 source)** | One reference says so. Plausible, untested |
| 🔴 **UNKNOWN / CONFLICTING** | Nobody knows, or sources disagree |

Sources:
- **[BW]** bWanShiTong, reverse-engineering-whoop-post. https://github.com/bWanShiTong/reverse-engineering-whoop-post
- **[OS]** OpenStrap protocol (Dart, AGPL-3.0). https://github.com/OpenStrap/protocol (`constants.dart`, `crc.dart`, README)
- **[CM]** christianmeurer, whoop-reader (Python, MIT). https://github.com/christianmeurer/whoop-reader

> **License note:** OpenStrap is AGPL-3.0. We use it as a **reference for facts** (opcode numbers, byte offsets),
> which are not copyrightable, but we **write our own code** and do not copy theirs. That keeps this repo's license our choice.

---

## 1. GATT layout

| Name (from decompiled app, per [BW]) | UUID | Props | Tag |
|---|---|---|---|
| Custom service | `61080000-8d6d-82b8-614a-1c8cb0f8dcc6` | n/a | 🟢 [CM] + prompt notes |
| CMD_TO_STRAP | `61080002-8d6d-82b8-614a-1c8cb0f8dcc6` | write | 🟢 [BW] [CM] |
| CMD_FROM_STRAP | `61080003-…` | notify | 🟡 [BW] |
| EVENTS_FROM_STRAP | `61080004-…` | notify | 🔴 [BW] says events; [CM] says this is the **data** stream |
| DATA_FROM_STRAP | `61080005-8d6d-82b8-614a-1c8cb0f8dcc6` | notify | 🟡 [BW] |
| MEMFAULT (crash logs) | `61080007-…` | notify | 🟡 [BW] |
| Std Heart Rate Measurement | `0x2A37` | notify | 🟢 works only after HR broadcast is enabled |

Phase 1 `sniff.py` will subscribe to **all** notify characteristics and log which packet types appear on which one,
which settles the 0004 vs 0005 conflict.

The band uses a **random BLE address** (it can change), so we identify it by advertised name or service UUID, not by MAC.

## 2. Frame format ✅ VERIFIED

```
 byte:  0      1   2      3        4      5     6     7 … n-5     n-4 … n-1
      ┌────┬─────────┬───────┬──────┬─────┬─────┬────────────┬──────────────┐
      │ AA │ len (LE)│ CRC8  │ type │ seq │ cmd │  payload…  │ CRC32 (LE)   │
      └────┴─────────┴───────┴──────┴─────┴─────┴────────────┴──────────────┘
        SOF  u16       of len  └──────── "inner" ─────────────┘
```

- `len` = number of bytes **after** the 4-byte header, including the CRC32.
- **CRC-8**: poly `0x07`, init `0x00`, no reflection, no final XOR, computed over the 2 length bytes only. [OS]
- **CRC-32**: standard zlib/IEEE CRC-32 (poly `0x04C11DB7`, reflected form `0xEDB88320`, init `0xFFFFFFFF`,
  final XOR `0xFFFFFFFF`). Python: `zlib.crc32(inner)`. Computed over `type … payload`. Stored little-endian. [OS]
- `seq` = rolling counter. The band does not appear to check it. [BW]

**How we verified it:** 9 sample frames from [BW] (HR on/off, start activity, reboot, realtime, alarm, sync-end, erase)
all pass both CRCs. 

**Conflict resolved:** [BW] lists CRC-32 params "init 0x0, xorout 0xF43F44AC", found with a CRC brute-forcer.
[CM] mixes init 0xFFFFFFFF with that xorout. The plain zlib CRC over the inner bytes matches every sample,
so we treat the [BW]/[CM] parameter sets as artifacts of brute-forcing over a different byte range.

## 3. Packet types (byte 4)

From [OS] `constants.dart`. Rows marked ✅ also appear in [BW] sample packets with the same meaning.

| Hex | Name | Tag |
|---|---|---|
| 0x23 | command (phone → band) | ✅ |
| 0x24 | command response | 🟡 |
| 0x28 | realtime data (compact HR) | ✅ ([BW] realtime sample) |
| 0x2B | realtime raw data | 🟡 |
| 0x2F | historical data (record per second) | ✅ ([BW] 96-byte sync packets `aa5c00f02f…`) |
| 0x30 | event | ✅ ([BW] events `…30`) |
| 0x31 | metadata (history start/end/complete) | ✅ ([BW] sync-end `…31`) |
| 0x32 | console logs | 🟡 |
| 0x33 / 0x34 | realtime / historical IMU stream | 🟡 |

## 4. Commands (byte 6, when type = 0x23)

### Allowlist: the toolkit may send these

| Hex | Name [OS] | What [BW] saw | Tag |
|---|---|---|---|
| 0x01 | linkValid | n/a | 🟡 |
| 0x03 | toggleRealtimeHr | "start/stop activity", then ~1/s packets on DATA | 🟢 |
| 0x07 | reportVersionInfo (firmware version) | n/a | 🟡 **we want this first: check firmware** |
| 0x0B | getClock | n/a | 🟡 |
| 0x0E | setGenericHrProfile | **HR broadcast on/off** (enables 0x2A37) | 🟢 ⚠️ see below |
| 0x16 | sendHistoricalData | triggers history download | 🟢 |
| 0x17 | historicalDataResult (ack a batch) | "request next batch" with batch token | 🟢 |
| 0x1A | getBatteryLevel | n/a | 🟡 response format 🔴 unknown |
| 0x22 | getDataRange | n/a | 🟡 |
| 0x73/0x74 | getConfigKeyCount / getConfigKeyName | sent at end of sync | 🟢 |
| 0x91 | getHello | n/a | 🟡 |

⚠️ **0x0E is on OpenStrap's "dangerous" list** because it writes a persistent setting on the band. But it is exactly
what [BW] used (and what the official app's "HR broadcast" toggle does), with verified frames:
- ON: `aa0800a823080e016c935474`
- OFF: `aa0800a823070e00c7e40f08`

We'll allow it, with a confirmation prompt the first time.

### Needed but payload unknown 🔴
- **0x0A setClock.** The band's clock can be unset, which gives garbage timestamps [OS]. Payload format is TBD; we'll read OpenStrap `commands.dart` in Phase 1.

### Blocklist: the toolkit refuses to send these
`0x0F` forgetBonds, `0x19` forceTrim (**erases data**), `0x1D` reboot, `0x20` powerCycle, `0x21` setReadPointer,
`0x24–0x26` firmware update, `0x8A`, `0x94`, `0x95`, `0x99`, `0x9A`, `0x77`, `0x78`. Source: [OS] `dangerousCmds`.

## 5. Realtime packet (type 0x28) 🟡

[BW] sample: `aa1800ff 28 02 ad896566 f065 42 01 6706 0000000000000101 3ba00d4d`

| Offset | Bytes | Meaning | Tag |
|---|---|---|---|
| 6–9 | `ad896566` | Unix time LE = 1716947373 (2024-05-29) | 🟢 plausible date |
| 10–11 | `f065` | sub-seconds? | 🔴 |
| 12 | `42` | heart rate = 66 bpm | 🟡 |
| 13 | `01` | RR interval count | 🟡 |
| 14–… | `6706…` | RR values | 🔴 `0x0667` = 1639, which doesn't fit 66 bpm (~909 ms). Units/offset unknown |

Phase 1 will capture 0x28 and standard 0x2A37 (which has well-defined RR in 1/1024 s) **at the same time** to solve this.

## 6. Historical sync 🟢 ([BW] flow matches [OS] constants)

1. Connect, subscribe to all notify characteristics, raise the MTU.
2. Set the clock (0x0A). 🔴 payload TBD
3. Send `sendHistoricalData` (0x16).
4. Band streams `0x2F` records (1 Hz), then a `0x31` metadata packet where byte 6 = `02` (**historyEnd**) carrying a batch token.
   - [BW] sample: `aa1c00ab 31 18 02 f65c7066 804043000000 2e470100 04000000000000 7f873cf3`
5. Phone **saves the batch first**, then acks with `historicalDataResult` (0x17) + the token.
   **Without the ack, the band resends the same batch forever** [OS]. If we ack before saving, we can lose data.
6. Repeat until `historyComplete` (metadata byte 6 = `03`). 🟡

The band reportedly stores **~2 weeks** of ~1 Hz data while away from a phone. This matters for the app design (see the plan).

## 7. Historical record (type 0x2F, "R24", 1 Hz) 🟡 [OS]

Offsets into the inner payload: `[1]` record version · `[3:7]` counter · `[7:11]` unix ts · `[11:13]` sub-seconds ·
**`[17]` HR bpm (0 = off wrist)** · `[29]` green PPG ADC · `[36:48]` 3× float32 accel (g) · `[64]` red ADC · `[66]` IR ADC · `[70]` ambient light.
SpO2/temperature/ambient are **raw, uncalibrated ADC counts**, not percentages or °C.

RR intervals in history records: 🔴 **unknown**. This is the biggest open question for overnight HRV
(see the plan, risk R3).

## 8. Low-confidence source warning ⚠️

[CM] whoop-reader's 96-byte table (HR at bytes 1–2, SpO2 % at 5, skin temp °C at 6) **contradicts** [BW] and [OS].
Those offsets would land inside the frame header. The README also has internal inconsistencies.
We **do not** use [CM]'s field map until a capture from my band backs it up. (Security lesson: verify sources,
even ones that look authoritative.)

## 9. Firmware risk ⚠️

- [OS] warns that some newer firmware withholds history/live data without a WHOOP-signed membership token,
  and advises **keeping the band away from the official WHOOP app** so it can't auto-update.
  I could **not** independently confirm the specific version numbers.
- **Action:** read the firmware version (0x07) as the very first thing in Phase 1 and record it here.

| Field | Value |
|---|---|
| My band firmware | _TBD (Phase 1)_ |
| Advertised name | _TBD_ |
