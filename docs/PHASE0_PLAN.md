# Phase 0: Plan

## 1. Protocol: known vs unknown (short version)

Full detail with sources: [re-toolkit/docs/PROTOCOL.md](../re-toolkit/docs/PROTOCOL.md).

**Solid (we can build on it now)**
- Frame format `AA | len | CRC8(len) | type | seq | cmd | payload | CRC32`. ✅ **We verified both CRCs against 9 real sample packets.**
- UUIDs for the custom service and the command characteristic.
- HR broadcast on/off frames, which unlock the standard 0x2A37 heart rate + RR (this is what `whoop_live.py` already uses).
- Packet types (command, realtime, historical, event, metadata) and most command opcodes. Two sources agree.
- History sync flow: request → batches → **save, then ack the token** → repeat.

**Partially known**
- Historical 1 Hz record: HR, timestamp, accelerometer offsets are reported. SpO2/temp/ambient are raw ADC values, not real units.
- Realtime 0x28 packet: HR byte looks right, RR encoding doesn't add up yet.

**Unknown (Phase 1 work, with your band)**
- Whether **RR intervals** exist in the stored history. This decides how good overnight HRV can be.
- Battery response format, set-clock payload, events payload.
- Which notify characteristic carries which packet type (sources conflict on 0004 vs 0005).
- **Your band's firmware version**, and whether it still hands out data.

## 2. Architecture: what I'd change

Your architecture is good. I'd keep it, with these changes:

### A. 🚨 Blocker: you're on Windows, and iOS apps need Xcode (macOS)
You can't build or install a SwiftUI app from Windows. Options:

| Option | Cost | Notes |
|---|---|---|
| **1. Get Mac access, keep SwiftUI** (school Mac lab, borrowed Mac, used M1 Mac mini, or rented cloud Mac) | $0 to ~$400 | Best result: native CoreBluetooth background + state restoration, HealthKit, Swift Charts. Matches the plan as written. |
| **2. Switch to Expo / React Native + EAS cloud builds** | $0 builds (free tier), but needs the $99/yr Apple Developer Program to install on your phone | You've used Expo before. No Mac needed. Downsides: overnight background BLE and HealthKit go through third-party libraries, which are rougher, and the result is "less iOS-native" for a portfolio. |

Either way: **a free Apple ID install expires every 7 days**. The $99/yr Apple Developer Program fixes that and gives TestFlight.

**Phase 1 (Python toolkit) runs fine on Windows** (bleak supports Windows BLE), so this doesn't block the next step.

### B. Don't stream all night. Let the band record, then sync history.
The band stores ~2 weeks of 1 Hz data on its own. So instead of holding a live BLE stream all night (battery drain,
iOS can kill it), the app:
- does a **history sync** when it reconnects (opening the app, and background reconnects via state restoration),
- uses **live streaming only** for the Live HR screen and active workouts.

This is simpler, more reliable, and easier on the battery. The bluetooth-central background mode and state restoration stay; they're used for reconnect + sync.

### C. Raw data stays on the phone. Only summaries go to Supabase.
1 Hz × 24 h = 86,400 samples/day. Putting that in Postgres is slow, costly, and a privacy risk.
- **On the phone:** raw samples (chunked, see the data model).
- **To Supabase:** daily summaries, sleep sessions, workouts, optional 1-minute HR averages.

That's enough for the MCP tools. It's also **data minimization**, a core security principle: anything you don't upload can't leak.

### D. Storage: chunk raw samples
SwiftData gets slow with millions of tiny rows (2 weeks = 1.2M HR samples). Store raw data as **one row per minute**
holding packed arrays (`Data` blobs). That's 1,440 rows/day instead of 86,400.

### E. Safety rails on the band
The toolkit and the app only send an **allowlist** of read-only commands. Erase, reboot, firmware update and similar
commands are hard-blocked in code (list in PROTOCOL.md §4). One wrong frame could wipe the band's stored data.

### F. Naming and metrics
- Don't put "WHOOP" in the app's name or icon (trademark). Working name: **"Pulse"**, or pick your own.
- WHOOP's Recovery/Strain formulas are proprietary. We'll build **our own transparent versions** from published
  research and explain them in the app:
  - **Strain (0–21):** Banister/Edwards TRIMP from HR zones, log-scaled.
  - **Recovery (0–100%):** z-scores of overnight RMSSD and resting HR vs your 7–14 day baseline, plus sleep sufficiency.
  - **Sleep:** sleep/wake detection from motion + HR (Cole-Kripke style actigraphy). I'll be honest that
    **sleep stages (REM/deep) from HR + motion are low accuracy**. We'll show "Restful vs Light/Awake" rather than pretend.

### G. MCP auth (Phase 8)
Claude's custom connectors expect remote MCP servers to use OAuth. I'll verify the current requirements when we
get there instead of guessing now.

### Updated data flow
```
WHOOP band ──BLE──► WhoopProtocol (decode, CRC check, allowlist)
   │ history sync on reconnect / live stream on demand
   ▼
SwiftData (raw minute chunks + summaries, offline first)
   ▼
Metrics engine (pure Swift, unit tested, matches re-toolkit Python)
   ▼
SwiftUI screens ──► HealthKit (summaries, workouts)
   │               └► Strava (workouts, via Supabase fn holding the secret)
   ▼
Supabase (summaries only, RLS) ──► MCP edge function ──► Claude app
```

## 3. Data model

### On the phone (SwiftData)
```
Band            id, name, firmwareVersion, lastSeenAt, lastHistorySyncAt, batteryPercent, isCharging
RawMinute       minuteStart (unique), source[history|live],
                hr: Data (60×UInt8, 0 = no reading), rr: Data (UInt16 ms list),
                motion: Data (60×Float16 accel magnitude), worn: Data (bitmask)
SleepSession    id, start, end, inBedMinutes, asleepMinutes, efficiency, disturbances,
                restingHR, rmssd, respiratoryRate?, isNap, algorithmVersion
Workout         id, start, end, kind, source[auto|manual], avgHR, maxHR, strain,
                zoneSeconds[5], kcalEstimate, healthKitID?, stravaID?, uploadState
DailySummary    date (unique), recoveryPct, recoveryZone[green|yellow|red],
                dayStrain, sleepHours, sleepNeedHours, restingHR, rmssd,
                baselineRMSSD, baselineRHR, explanation (why it changed), algorithmVersion
UserProfile     birthYear, sex?, weightKg?, maxHROverride?, sleepGoalHours, units
SyncState       lastCloudSyncAt, pendingIDs, lastHealthKitExportDate
DebugPacket     timestamp, characteristic, hex, decodedType   (ring buffer, last ~5k, debug only)
```
`algorithmVersion` lets us recompute old days when a formula improves, without mixing results.

### In Supabase (Postgres, RLS on `user_id = auth.uid()`)
```
daily_summary   user_id, date, recovery_pct, day_strain, sleep_hours, resting_hr, rmssd, …
sleep_session   user_id, id, start, end, efficiency, resting_hr, rmssd, …
workout         user_id, id, start, end, kind, avg_hr, max_hr, strain, zone_seconds, …
hr_minute       user_id, minute, avg_hr, min_hr, max_hr        (optional, for trends)
strava_token    user_id, encrypted access/refresh token        (no client access, service role only)
mcp_client      user_id, hashed credentials / OAuth grants     (no client access)
```

## 4. Screens (text wireframes)

Tab bar: **Today · Sleep · Activity · Trends**. Settings opens from the avatar on Today.

### Today (answers "How ready am I?" in 2 seconds)
```
┌─────────────────────────────────────┐
│ Thu, Nov 12          ● Synced 7:42 ⚙│
│                                     │
│          ╭───────────╮              │
│        ╭─┤    82%    ├─╮  RECOVERY  │
│        │ │   READY   │ │  (green)   │
│        ╰─┴───────────┴─╯            │
│  "HRV above your baseline, slept 7h40│
│   — good day to push."         (i)  │
│                                     │
│ ┌──────────┐┌──────────┐┌──────────┐│
│ │ STRAIN   ││ SLEEP    ││ RHR      ││
│ │  8.4     ││ 7h 40m   ││ 52 bpm   ││
│ │ ▁▂▅▃     ││ 94% need ││ ↓2       ││
│ └──────────┘└──────────┘└──────────┘│
│ Live HR  ♥ 64 bpm      [Start ▶]    │
│ Today's workouts: Run 5.2 km  12.1  │
├─────────────────────────────────────┤
│  Today   Sleep   Activity   Trends  │
└─────────────────────────────────────┘
```
Tapping any number opens the **Metric explainer** sheet.

### Metric explainer (sheet)
```
┌─────────────────────────────────────┐
│ Recovery · 82%                    ✕ │
│ What it means                       │
│  How ready your body is for effort. │
│ Why it's 82% today                  │
│  ✓ HRV 68 ms (baseline 61)   +      │
│  ✓ Resting HR 52 (baseline 54) +    │
│  ~ Sleep 7h40 of 8h10 need   −      │
│ 14-day chart ▁▃▅▆▃▅▇                │
│ How we calculate it  >              │
└─────────────────────────────────────┘
```

### Sleep
```
┌─────────────────────────────────────┐
│ ◀ Last night ▶          11:48–7:28  │
│ 7h 40m asleep · 94% of need         │
│ ███▒▒████░███████▒▒█████  hypnogram │
│ (Restful / Light / Awake)           │
│ Efficiency 91% · Disturbances 6     │
│ HR ╲___/‾‾╲__  lowest 49            │
│ HRV (RMSSD) 68 ms                   │
│ Sleep need tonight: 8h 05m          │
└─────────────────────────────────────┘
```

### Activity (Strain + Workouts)
```
┌─────────────────────────────────────┐
│ Day Strain  12.1 / 21   ◔           │
│ HR zones today ▇▅▃▂▁ (Z1–Z5 mins)   │
│ ─ Workouts ───────────────────────  │
│ 🏃 Run   7:10–7:42  Strain 9.8  ↗ S  │
│ 🚴 Ride  Tue        Strain 13.2 ✓ S  │
│ [+ Log workout]   auto-detected: 1  │
└─────────────────────────────────────┘
```
Workout detail: HR chart with zone bands, avg/max, kcal, "Send to Strava", "Saved to Health ✓".

### Trends
```
┌─────────────────────────────────────┐
│ [7D] [30D] [90D]                    │
│ Recovery  ▃▅▇▅▃▆▇  avg 67%          │
│ HRV       ─/‾\_/‾  avg 63 ms        │
│ RHR       ‾‾\__/‾  avg 53           │
│ Sleep     ▅▆▄▇▅▆▆  avg 7h12         │
│ Strain    ▂▇▃▅▁▆▄  avg 10.4         │
│ Insight: "Recovery is lower after   │
│  nights under 7h."                  │
└─────────────────────────────────────┘
```

### Pairing / onboarding (first launch)
```
1. Welcome: what this app does, privacy promise (data stays on your phone)
2. Bluetooth permission (explain why first)
3. Searching…  ◌   "Double-tap your band"
   → "WHOOP 4C…  ▮▮▮▯ 76%"  [Connect]
4. Firmware check ✓ · Enable HR broadcast? [Allow]
5. First sync ▓▓▓▓░░ 62%  (pulls up to 14 days)
6. Profile: birth year, sleep goal → Done
```

### Settings
```
Band: Connected ● · Battery 76% · Firmware 41.x · Last sync 7:42 · [Sync now] [Forget]
Profile · Sleep goal · Units
Apple Health  [Connected ✓]
Strava        [Connect]
Cloud backup  [On] · Claude connector setup >
Privacy: Export my data · Delete all data
About / How metrics work
(hidden) Debug: tap version 7×
```

### Debug (hidden)
Live packet list (time · char · type · hex), filter by type, CRC ✓/✗, pause, export to share sheet, decoded view.

## 5. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | No Mac means no native iOS build | Decide now (see 2A). Phase 1 runs on Windows anyway |
| R2 | Band firmware withholds data | Check firmware first in Phase 1. Keep the band off the official app |
| R3 | No RR in stored history means weaker overnight HRV | Fall back to RR from live 0x2A37 when connected. Investigate in Phase 1 |
| R4 | iOS kills background BLE | History-sync design (2B) tolerates gaps |
| R5 | A bad command damages band data | Allowlist + blocklist in code (2E) |
| R6 | Health data leaks via git or cloud | .gitignore captures, summaries-only cloud, RLS, secrets server-side |

## 6. Decisions needed from you before Phase 2
1. **Mac or Expo?** (2A). Needed before Phase 2. Phase 1 can start either way.
2. Apple Developer Program ($99/yr): yes or not yet?
3. App name (instead of "Pulse")?
