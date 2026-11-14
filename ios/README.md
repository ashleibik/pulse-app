# Pulse: iOS app

```
ios/
  project.yml          XcodeGen spec -> generates Pulse.xcodeproj (not committed)
  design/DESIGN.md     the design system "Mono" (colors, type, spacing, motion). Spec first, then code
  PulseCore/           Swift package, Foundation only, builds + tests on Windows/Linux/macOS
    Sources/PulseCore/
      Models/          MinuteSample, SleepSession, Workout, DailySummary, BinaryCoding
      FakeData/        SeededRandom, FakeDataGenerator (30 realistic days)
      Text/            PulseFormat (durations, plain-language explanations)
      Metrics/         Stats, HRV, SleepDetector, Load (strain/recovery), MetricsEngine, DemoData,
                       WorkoutDetector (finds workouts in raw band data; our own heuristic)
                       -> spec: docs/METRICS.md, must match re-toolkit/metrics on shared/test-vectors
      Insights/        everything the screens need that's more than formatting, tested on Windows:
                       RecoveryExplainer (factor points), StrainGuidance (targets + advice),
                       SleepTimeline (restful/light/awake), HeartRateZones, SleepNeedBreakdown,
                       TrendInsights (period comparisons + plain-language insights),
                       HealthExport (what may be written to Apple Health: never simulated data)
      Cloud/           CloudRows (the only data that may leave the phone), StravaExport (TCX file)
      Protocol/        Swift port of re-toolkit/protocol (Whoop namespace): CRCs, frames, reassembler,
                       allowlisted command builders, packet decoder, 0x2A37 parser
                       -> must match re-toolkit/protocol on shared/test-vectors/protocol_v1.json
                       HistorySync (download state machine: never acks before save), SimulatedBand
                       (a fake band that speaks the protocol), MinuteBuilder (1 Hz records -> minutes),
                       BandSession (hello + clock check + history download as one tested state machine)
    Tests/PulseCoreTests/
  Pulse/               the SwiftUI app (needs Xcode)
    App/               PulseApp, RootView (tabs), Design (DS tokens = DESIGN.md in code)
    Data/              SwiftData models, PulseStore (+ BandImporter), DemoDataLoader
    Band/              BandLink (CoreBluetooth + simulated band), BandManager (pairing and syncing)
    Health/            HealthExporter (writes sleep, resting HR and workouts to Apple Health)
    Cloud/             CloudClient (URLSession + Keychain), CloudManager (upload, Strava, coach)
    Features/          Today, Recovery (detail), Sleep, Activity (+ workout detail), Trends,
                       Settings (profile, band, recalculate), Pairing (+ hidden band log),
                       Welcome (first launch), Shared components
    Resources/         Assets.xcassets
  scripts/             swift-env.ps1, test-core.ps1 (Windows helpers)
```

**Rule:** anything that can be plain Swift goes in PulseCore, so it gets tested on every machine.
The `Pulse/` app layer stays thin: screens, storage, and Apple frameworks only.

## On Windows (now)

One-time setup (already done on this PC): Swift toolchain + Visual Studio 2022 Build Tools.
```powershell
winget install --id Swift.Toolchain -e
winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--passive --wait --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
```
Run the tests:
```powershell
.\ios\scripts\test-core.ps1
```

The SwiftUI app **can't** be built on Windows. It's written against iOS 17 APIs and builds on a Mac.

## See the app without a Mac

| Option | What you get | How |
|---|---|---|
| **Cloud Mac (GitHub Actions)** | The REAL app compiled with Xcode, plus iPhone simulator screenshots of every screen | Push app changes (or *Actions → iOS build & screenshots → Run workflow*), then `gh run download --name screenshots` |
| **Web preview** | A clickable look-alike in the browser, filled with numbers from the real PulseCore engine | `.\ios\scripts\build-preview.ps1`, then open `docs/preview/pulse-preview.html` |

The workflow (`.github/workflows/ios.yml`) also runs the Python tests and the PulseCore tests on macOS.
Each run costs about 5 macOS minutes (counted 10x against a private repo's free minutes).

## The band (Phase 5b)

How a sync works, and which part is tested where:

```
band  --Bluetooth-->  BandLink        bytes in / out                 (app, CoreBluetooth)
                      BandSession     protocol: hello, clock, history (PulseCore, tested on Windows)
                      BandImporter    saves minutes, THEN the ack     (app, SwiftData)
                      MetricsEngine + WorkoutDetector, then the screens update
```

- **Try it without a band:** Settings > Pair your band > *Try a simulated band*. It replays the last
  two days through the exact same protocol code (this is what the CI screenshots show).
- **With the real band:** Settings > Pair your band > *Search for my band*. The demo month is
  deleted and replaced by the band's history.
- **Debug log:** Settings > tap the *Version* row 7 times.
- **Not tested with a real band yet.** Open questions are listed in `re-toolkit/docs/PROTOCOL.md`
  (service UUID, ack token, whether stored history contains RR intervals). Run the Python toolkit
  against the band first; it is the safer place to find surprises.
- **Not built yet:** background reconnect, live heart rate screen.

## Apple Health (Phase 6)

Settings > Apple Health > *Turn on*. Pulse asks for **write access only** and never reads from
Apple Health.

| Written | Not written, and why |
|---|---|
| Sleep: in bed, asleep, awake | Sleep stages (REM / deep): Pulse does not measure them |
| Resting heart rate, one per day | HRV: Apple Health stores SDNN, Pulse calculates RMSSD (different numbers) |
| Workouts: type, start, end | Calories: only a rough guess |

- **Demo and simulated data are never exported** (rule and test: `HealthExport` in PulseCore).
- Exporting twice does not duplicate: Pulse first deletes what it wrote before for the same time span.
- After every band sync the last 3 days are exported again. *Export all* sends the whole history.
- **Not tested on a real iPhone yet.** It needs the signed app with the HealthKit capability
  (`Pulse/Pulse.entitlements`); the unsigned CI builds can't exercise it.

## Install on your iPhone (free, no Mac)

For your own phone only. No $99 Apple Developer Program needed.

1. **Build the file:** GitHub > Actions > *Build IPA* > *Run workflow* (about 10 minutes), then
   `gh run download --name Pulse-ipa` in the repo folder. You get `Pulse.ipa`.
2. **Install a sideloading tool on Windows**, for example Sideloadly (sideloadly.io), plus
   iTunes from apple.com (not the Microsoft Store version), which it needs for the USB driver.
3. **iPhone:** connect it by USB and tap *Trust*. Then Settings > Privacy & Security >
   *Developer Mode* > on (the phone restarts).
4. **Sideloadly:** drop in `Pulse.ipa`, sign in with your Apple ID, press *Start*. You type the
   Apple ID password into Sideloadly yourself; it goes to Apple only.
5. **iPhone:** Settings > General > VPN & Device Management > your Apple ID > *Trust*.

Limits of a free Apple ID (Apple's rules, not Pulse's):
- The app **stops opening after 7 days**. Re-install it with step 4 (your data stays).
- At most 3 sideloaded apps at a time.
- **Apple Health export probably won't work**: the free signing likely drops the HealthKit
  permission. Not tested. Everything else (Bluetooth, the band, all screens) needs no special
  permission.

The paid Developer Program (`.github/workflows/testflight.yml`) removes the 7-day limit and
keeps HealthKit, if you ever want that.

## On a Mac (when you have one)

```bash
xcode-select --install            # if Xcode was never opened
brew install xcodegen
cd ios
xcodegen                          # creates Pulse.xcodeproj from project.yml
open Pulse.xcodeproj
```
1. Select the **Pulse** target → *Signing & Capabilities* → pick your Team (a free Apple ID works for 7-day installs).
2. Choose an iPhone simulator (or your phone) and press ⌘R.
3. First launch generates 30 days of demo data (about 2 s). The pill at the top says **Demo data**.
4. Run PulseCore tests in Xcode (⌘U on the PulseCore scheme) or `cd PulseCore && swift test`.

> The app layer is compiled by GitHub Actions on every push that touches `ios/`, so it should
> build on your Mac too. It has not been run on a real iPhone yet.
