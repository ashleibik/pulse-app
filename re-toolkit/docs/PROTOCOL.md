# WHOOP 4.0 BLE Protocol: Working Notes

This document changes as we learn. The code in `re-toolkit/protocol/` implements exactly what's written here.
Every fact has a **confidence tag**:

| Tag | Meaning |
|---|---|
| ✅ **VERIFIED** | We checked it ourselves (math on real packets, or a capture from my band) |
| 🟢 **CONFIRMED** | Two independent sources agree, or one source matches a real sample packet |
| 🟡 **REPORTED** | One source says so. Plausible, untested |
| 🔴 **UNKNOWN / CONFLICTING** | Nobody knows, or sources disagree |

Sources:
- **[BW]** bWanShiTong, reverse-engineering-whoop-post (real captures). https://github.com/bWanShiTong/reverse-engineering-whoop-post
- **[OS]** OpenStrap protocol (Dart, AGPL-3.0): `constants.dart`, `framing.dart`, `crc.dart`, `commands.dart`, `control.dart`, `live.dart`, `band.dart`. https://github.com/OpenStrap/protocol
- **[CM]** christianmeurer, whoop-reader (Python, MIT). https://github.com/christianmeurer/whoop-reader
- **[NOOP]** ryanbr/noop docs (`PROTOCOL_COMMANDS.md`, `PROTOCOL_SENSORS.md`, `PROTOCOL_WHOOP4.md`) at commit 2a1de76, with
  WHOOP 4 device captures. https://github.com/ryanbr/noop

> **License note:** OpenStrap is AGPL-3.0. We use it as a **reference for facts** (opcode numbers, byte offsets),
> which aren't copyrightable, and **write all code ourselves**. That keeps this repo's license our choice.

> **Offset convention:** unless stated otherwise, offsets are into the **inner** bytes (see §2), where `inner[0]` = packet type.
> Frame offset = inner offset + 4.

---

## 0. Verification log

| Date | What | Result |
|---|---|---|
| 2026-11-12 | CRC-8 + CRC-32 on 9 [BW] frames | ✅ all pass (`tests/test_crc.py`) |
| 2026-11-13 | Our command builder vs [BW] captured HR-broadcast and realtime-on frames | ✅ byte-identical (`tests/test_frames.py`) |
| 2026-11-13 | [OS] 0x28 realtime layout vs [BW] realtime sample | 🟢 timestamp, HR, RR count and wearing byte all land on sane values |
| 2026-11-13 | [OS] HISTORY_END layout vs [BW] sync-end sample | 🟢 timestamp (2024-06-17), count 67, token all sane |
| 2026-11-13 | Swift port (`ios/PulseCore/.../Protocol`) vs this Python package on `shared/test-vectors/protocol_v1.json` | ✅ identical: CRCs, frames, all builders, allowlist, reassembly, decoding |
| 2026-11-13 | Reassembler fix: zero padding is skipped at the top of the loop, so the result no longer depends on how BLE splits notifications | ✅ tested for chunk sizes 1-244 |
| 2026-11-17 | First real sync (my WS40) failed: "Batch kept arriving incomplete (4 tries)" | ❌ root cause: we treated HISTORY_END `[9:13]` ("expected packets") as a hard gate. OpenStrap/edge documents that on WHOOP 4 it does NOT match the records actually sent (gap varies run to run) and keeps it advisory (`burstCountGateEnforced = false`, test "a short gen4 burst is still ACKed with the verbatim token"). Now advisory + logged. Meaning of the field: 🔴 unknown, pin it from a sync log |
| _TBD_ | First full sync log from **my** band (Settings > Band > Sync log > Export) | |

## 1. GATT layout

| Name | UUID | Props | Tag |
|---|---|---|---|
| Custom service | `61080000-…` **or** `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` | n/a | 🔴 your notes + [CM] say `…0000`, [OS] says `…0001`. **sniff.py prints the real one** |
| CMD_TO_STRAP | `61080002-8d6d-82b8-614a-1c8cb0f8dcc6` | write (with response) | 🟢 [BW][OS] |
| CMD_FROM_STRAP | `61080003-…` | notify: command responses | 🟢 [BW][OS] |
| EVENTS_FROM_STRAP | `61080004-…` | notify: events | 🟢 [BW][OS] ([CM] calls it data; outvoted) |
| DATA_FROM_STRAP | `61080005-…` | notify: realtime + history | 🟢 [BW][OS] |
| MEMFAULT | `61080007-…` | notify: crash logs | 🟡 [BW][OS] |
| Std Heart Rate Measurement | `0x2A37` | notify | 🟢 sends data only after HR broadcast is on (§4) |

The band uses a **random BLE address**, so the tools identify it by name / service UUID prefix `6108`, not by address.

## 2. Frame format ✅ VERIFIED

```
 frame byte:  0      1   2      3      4 ...................... n-5   n-4 ... n-1
            ┌────┬─────────┬──────┬────────────────────────────┬──────────────┐
            │ AA │ len (LE)│ CRC8 │ inner (zero-padded to ×4)  │ CRC32 (LE)   │
            └────┴─────────┴──────┴────────────────────────────┴──────────────┘
 inner byte:                        0      1      2      3…
                                   type   seq    opcode body…      (commands & responses)
                                   type   ver    …                 (data records)
```

- `len` = `len(inner) + 4` (everything after the header, including the CRC32).
- **CRC-8:** poly `0x07`, init `0`, no reflection, no final XOR (CRC-8/SMBUS), over the 2 length bytes.
- **CRC-32:** standard zlib/IEEE (`zlib.crc32(inner)`), over the padded inner, stored little-endian.
- **Padding:** inner is zero-padded to a multiple of 4. 🟢 [OS], and every [BW] sample has this property.
- **Reassembly:** frames can span several notifications, or share one. Reassemble by **length**, not by
  searching for `0xAA` (which can appear inside data). Zero bytes between frames are padding. [OS]
- `seq` is a rolling counter. The band doesn't check it [BW], but responses echo it (§5).

**Conflict resolved:** [BW] lists CRC-32 params "init 0x0, xorout 0xF43F44AC" (found with a CRC brute-forcer), and
[CM] mixes init 0xFFFFFFFF with that xorout. Plain zlib CRC-32 over the inner bytes matches every sample, so those
parameter sets are brute-forcing artifacts.

## 3. Packet types (`inner[0]`)

| Hex | Name | Direction / characteristic | Tag |
|---|---|---|---|
| 0x23 | COMMAND | phone → band (CMD_TO) | ✅ |
| 0x24 | COMMAND_RESPONSE | CMD_FROM | 🟡 |
| 0x28 | REALTIME_DATA (HR + RR) | DATA | 🟢 |
| 0x2B | REALTIME_RAW: 100 Hz motion (inner length 1,920) or optical (1,924), while 0x3F is on. See §8b | DATA | 🟡 [NOOP] captures |
| 0x2F | HISTORICAL_DATA (1 Hz record) | DATA | 🟢 |
| 0x30 | EVENT | EVENTS | 🟢 |
| 0x31 | METADATA (history markers) | DATA | 🟢 |
| 0x32 | CONSOLE_LOGS | Readable firmware status lines, for example `TIGHTNESS V1: ... loose flag = 1`. Seen on the owner's band: inner `[4:8]` unix time, `[10:12]` size, `[12]` = 1, then 50 text bytes that continue in the next packet (lines are cut mid-word), then 0 | 🟡 |
| 0x33 / 0x34 | REALTIME_IMU / HISTORICAL_IMU | DATA | 🟡 |

## 4. Commands (`inner[2]` when type = 0x23)

Builders are in `protocol/frames.py`. **Allowlist** in `protocol/constants.py`: anything not listed can't be built.

### Read-only (sent automatically by sniff.py)

| Hex | Name [OS] | Payload | Tag |
|---|---|---|---|
| 0x07 | REPORT_VERSION_INFO | (none) | 🟡 response layout 🔴 unknown |
| 0x0B | GET_CLOCK | `00` | 🟡 |
| 0x1A | GET_BATTERY_LEVEL | (none) | 🟡 |
| 0x22 | GET_DATA_RANGE | `00` | 🟡 |
| 0x23 | GET_HELLO_HARVARD | `00` | 🟡 first packet of the official app's start-up sequence |
| 0x01, 0x43, 0x4C, 0x54, 0x62, 0x91 | other GET_* queries | | 🟡 allowed, not used yet |

### Stateful (sent only with an explicit flag)

| Hex | Name | Payload | Tag |
|---|---|---|---|
| 0x03 | TOGGLE_REALTIME_HR | `01` on / `00` off | ✅ builder matches [BW] capture |
| 0x0E | SET_GENERIC_HR_PROFILE ("HR broadcast") | `01` / `00` | ✅ builder matches [BW] captures. ⚠️ persistent setting, [OS] lists it as dangerous. We ask first and turn it back off |
| 0x0A | SET_CLOCK | u32 secs LE · u16 subsec (1/32768 s) LE · `00 00` (exactly 8 bytes) | 🟡 [OS]: a wrong length is ACKed but ignored |
| 0x16 | SEND_HISTORICAL_DATA | `00` | 🟢 |
| 0x17 | HISTORICAL_DATA_RESULT (ack) | `01` + 8-byte token (§7) | 🟢 layout [BW]+[OS], token contents 🔴 see §7 |
| 0x14 | ABORT_HISTORICAL | | 🟡 |
| 0x3F | SEND_R10_R11_REALTIME (100 Hz motion + optical stream, type 0x2B) | `01` on / `00` off | 🟡 [NOOP]: seen in WHOOP 4 device captures, 2.1 packets/s → 0 when off. The state **stays on across reconnects** and floods Bluetooth (about 4 kB/s). Pulse turns it off on every connect, then on while the band is worn and moving, to count steps (docs/METRICS.md §15) |

### Refused (not on the allowlist)
`0x0F` forget bonds · `0x19` force trim (**erases data**) · `0x1D` reboot · `0x20` power cycle · `0x21` set read pointer ·
`0x24–0x26` firmware update · `0x8A` · `0x94` · `0x95` · `0x99` · `0x9A` · gen5 `0x77`/`0x78`, plus **every undocumented opcode**.

## 5. Command response (type 0x24) 🟡 [OS]

| Offset | Meaning |
|---|---|
| `[2]` | opcode being answered |
| `[3]` | seq of our request (echo) |
| `[4]` | status: 0 failed · 1 ok · 2 deferred · 3 not implemented |
| `[5:]` | body |

| Response to | Body decoding |
|---|---|
| GET_BATTERY_LEVEL | u16 LE at `[5:7]` ÷ 10 = percent (gen4 uses deci-percent) |
| GET_CLOCK | u32 LE at `[5:9]` = unix seconds (a garbage value means the clock isn't set) |
| GET_DATA_RANGE | `[14:18]` write page · `[18:22]` trim page · `[22:26]` wrap count · `[26:30]` capacity · `[30:34]` used · `[34:38]` free · `[38:42]` oldest record time · `[62:66]` newest record time |
| REPORT_VERSION_INFO | 🔴 unknown. sniff.py prints hex + ASCII. **Also try standard Device Information char `2a26` (Firmware Revision)**, which sniff.py reads automatically |

## 6. Realtime packet (type 0x28) 🟢 [OS] layout, consistent with [BW] sample

[BW] sample inner: `28 02 | ad896566 | f065 | 42 | 01 | 6706 0000 0000 0000 | 01 | 01`

| Offset | Sample | Meaning | Tag |
|---|---|---|---|
| `[2:6]` | `ad896566` | u32 unix secs = 1717930413 = 2024-06-09 10:53 UTC | 🟢 |
| `[6:8]` | `f065` | sub-seconds | 🔴 units unknown |
| `[8]` | `42` | HR = 66 bpm (0 = no reading) | 🟢 |
| `[9]` | `01` | RR count (max 4) | 🟢 |
| `[10+2i]` | `6706` | RR i16 LE in **ms** [OS] = 1639 ms | 🔴 1639 ms means a 37 bpm beat, odd at 66 bpm. Could be a skipped beat. **Test:** capture 0x28 and 0x2A37 together, then `decode_helper hr` |
| `[18]` | `01` | wearing flag | 🟡 |

## 7. Historical sync 🟢

1. Connect, subscribe to every notify characteristic.
2. (Optional) SET_CLOCK. [OS] says a fresh band's clock is unset, which gives bad timestamps. Check GET_CLOCK first.
3. SEND_HISTORICAL_DATA (0x16).
4. The band streams 0x2F records, then a METADATA packet:

   | Offset | Meaning | [BW] sample value |
   |---|---|---|
   | `[2]` | meta type: 1 start · **2 end of batch** · 3 complete | `02` |
   | `[3:7]` | u32 timestamp | `f65c7066` = 2024-06-17 15:57 UTC |
   | `[7:9]` | sub-seconds | `8040` |
   | `[9:13]` | u32 records in this batch | `43000000` = 67 |
   | `[13:21]` | **8-byte ack token**: u32 trim page + u32 wrap count | `2e470100 04000000` |

5. **Save the batch to disk, then** ack with `0x17`, payload `01` + token. If you don't ack, the band resends the
   same batch forever [OS]. If you ack before saving and then crash, that data may be gone.
6. Repeat until meta type 3 (complete).

🔴 **Token conflict:** [OS] echoes all 8 token bytes (`2e470100 04000000`). [BW]'s captured ack showed
`2e470100 00000000`. We follow [OS] (more recent, more thorough). If the band ignores our ack, this is the first
thing to check.

The band reportedly stores **~2 weeks** of ~1 Hz data.

## 8. Historical record (type 0x2F) 🟡 [OS]

`inner[1]` is the **record version** here, not seq. [BW]'s samples are version `0x0c` (12). [OS] decodes 12 and 24 directly.

| Offset | Meaning |
|---|---|
| `[1]` | record version |
| `[3:7]` | u32 record counter |
| `[7:11]` | u32 unix timestamp |
| `[11:13]` | sub-seconds |
| `[17]` | **HR bpm** (0 = off wrist) |
| `[29]` | green PPG ADC |
| `[36:48]` | 3 × float32 accelerometer (g). Gravity vector: magnitude should be about 1 when still |
| `[64]`, `[66]`, `[70]` | red, IR, ambient ADC (raw counts, **not** SpO₂ % or °C) |

🔴 **Do history records contain RR intervals?** Unknown, and it's **the most important open question**: no RR in
history means overnight HRV only works while the phone is connected. The parser tries the R10 layout
(count at `[18]`, i16 ms from `[19]`) and reports it as `rr_ms_unverified`. Confirm with `decode_helper`.

## 8b. Realtime raw motion (type 0x2B) 🟡 [NOOP]

Sent about once a second while 0x3F is on, alternating with an optical packet. The motion variant has inner length
1,920 (payload 1,917, declared length 1,924): `[11:15]` u32 unix seconds · `[15:17]` sub-seconds · `[17]` heart rate ·
`[18]` RR count, i16 RR from `[19]` · `[85:285]`, `[285:485]`, `[485:685]` accelerometer x, y, z as 100 × i16 LE each
(100 Hz) · `[688:888]`, `[888:1088]`, `[1088:1288]` gyroscope x, y, z. Scale 1/4096 g per count (NOOP: matched a
gravity sphere fit; also OpenStrap's convention) and 2000/32768 °/s for the gyroscope. The optical variant has inner
length 1,924. NOOP documents both for firmware 41.17.6.0; the owner's band reports 41.11.7.0, so the first real step
test confirms or refutes it (the sync log prints the median size of the readings: about 1 g if the scale is right).

## 9. Events (type 0x30) 🟡 [OS]

`[2:4]` u16 event id · `[4:8]` u32 timestamp · `[8:10]` sub-seconds · `[10:12]` u16 body length · `[12:]` body.
Notable IDs: 3 battery · 7/8 charging on/off · 9/10 wrist on/off · 13 RTC lost · 14 double tap · 33/34 realtime HR on/off.
Battery body: `[1:5]` u32 deci-percent · `[5:9]` u32 millivolts · `[9]` charging.

## 10. Low-confidence source ⚠️

[CM] whoop-reader's 96-byte table (HR at bytes 1–2, SpO₂ % at 5, skin temp °C at 6) contradicts [BW] and [OS]: those
offsets fall inside the frame header. Its README is also internally inconsistent. **We don't use it.**
(Security lesson: an authoritative-looking README is a claim, not evidence. Check it against real data.)

## 11. Firmware risk ⚠️

[OS] says some newer firmware withholds data without a WHOOP-signed membership token, and advises keeping the band
**away from the official WHOOP app** so it can't auto-update. I could not independently confirm which versions are affected.

| Field | Value |
|---|---|
| My band firmware | _TBD: run sniff.py_ |
| Advertised name | _TBD_ |
| Real service UUID | _TBD_ |
| Battery % at first connect | _TBD_ |
