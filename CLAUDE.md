# Pulse

Personal, local-first iPhone app that reads the owner's own WHOOP 4.0 band over Bluetooth and turns
it into recovery, strain and sleep. No WHOOP cloud or account. General wellness, not medical advice.

The owner develops on Windows, has no Mac, and installs by sideloading (moving to SideStore).

## Hard rules

- **Never send FORCE_TRIM** (0x19, erases the band) or any other destructive command. Only the
  allowlisted builders in `PulseCore/Protocol` may produce commands.
- **Never commit `logs/`.** Sync logs hold raw heart-rate data. Same for `re-toolkit/captures/`.
- **No fake data** in the app: no demo months, placeholder numbers or invented values. Show `--` or
  an empty state instead. Fake data lives only in PulseCore's test support.
- **Follow [ios/design/DESIGN.md](ios/design/DESIGN.md)**: change the spec first, then the code. Screens use
  `DS.*` tokens and never hard-code colors, sizes or animations. Estimates are labelled as estimates.
- **Keep the bundle ID `dev.pulse.app`** (widget: `dev.pulse.app.widget`, App Group
  `group.dev.pulse.app`). Changing it loses the installed app's data.
- **Do not write steps or active energy to Apple Health.** The owner's Apple Watch owns those.
  Daily calories stay inside the app.
- **The build is always `Pulse.ipa` in the repo root.** Each new build overwrites it. No extra copies such as
  `Pulse-<commit>.ipa`. `*.ipa` and `sideloadlydaemon.log` stay in `.gitignore`.

## Decisions

- **Sleep in Apple Health is asleep + awake only (2026-11-18).** Stage estimates stay inside Pulse. The setting
  "Write sleep stages to Apple Health (estimated)" is off by default; the owner turns it on only after the stages
  are validated. REM is never written.
- **A sleep must be confirmed and finished before it is shown (2026-11-18).** The owner sat at a computer from 21:30
  to 00:30 and got a false 3h06 sleep. A night appears only once they are up again, and the owner can edit or remove
  any sleep. Spec: `docs/METRICS.md` §4.
- **Sleep is a learned probability per minute (2026-11-18).** `SleepModel` combines movement, heart rate against the owner's
  awake level, clean beats, HRV and time of day, and learns from their nights and edits. Breathing and skin temperature are
  left out until the data supports them. Keep the replay of the real night in `RealNightReplayTests` passing.

## Third-party code

Logic ported from OpenStrap and NOOP lives in `ios/PulseCore/Sources/PulseCore/ThirdParty/` and is listed in `docs/THIRD_PARTY.md`.
Port OpenStrap only from commit `e59d63c` or earlier: that code is MIT, and later versions are AGPL-3.0. NOOP code is noncommercial only.

## Later

- **Find out why a 1-year sync varies from 3.4 to 9.6 s, and speed it up (target under 2 s).** A sync with a year of data takes 3.2 s in an optimized build on the
  PC (30 days: 0.27 s). One idea: recompute only the last night instead of the whole latest week.

## Do not break (working on the real band)

Band connection and kept reconnect, band clock set, history drain (a batch is acked only after it
is saved), the data cutoff (`BandDataCutoff`: the band was bought used, older records belong to the
previous owner and are dropped), and the low-battery pause (below 5%, "Sync anyway" overrides once).

## Layout

| Path | What |
|---|---|
| `ios/PulseCore/` | Pure Swift logic (protocol, metrics, insights). Builds and tests on Windows |
| `ios/Pulse/` | SwiftUI app, iOS 17+. Screens, SwiftData, CoreBluetooth, HealthKit. Keep it thin |
| `ios/PulseWidget/`, `ios/Shared/` | Widget, and the snapshot it shares with the app |
| `ios/project.yml` | XcodeGen spec (the `.xcodeproj` is generated, never committed) |
| `re-toolkit/` | Python protocol reference and tests |
| `shared/test-vectors/` | Inputs and outputs that Python and Swift must both reproduce |
| `supabase/` | Optional cloud (summaries only) |
| `docs/METRICS.md` | Every formula, with sources |

Anything that can be plain Swift goes in PulseCore so it is tested on every machine.

## Testing

- `.\ios\scripts\test-core.ps1` runs the PulseCore tests on Windows.
- The app layer cannot compile on Windows. `swiftc -frontend -parse <file>` catches syntax errors only.
  The real compile is `.github/workflows/ios.yml` on a pushed commit without `[skip ci]`
  (macOS minutes cost 10x on a private repo, so routine commits use `[skip ci]`).
- `cd re-toolkit; .\.venv\Scripts\python -m pytest -q` runs the Python tests.
- Say plainly what was only unit-tested and what has never run on the phone.
