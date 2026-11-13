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
      Metrics/         Stats, HRV, SleepDetector, Load (strain/recovery), MetricsEngine, DemoData
                       -> spec: docs/METRICS.md, must match re-toolkit/metrics on shared/test-vectors
      Insights/        everything the screens need that's more than formatting, tested on Windows:
                       RecoveryExplainer (factor points), StrainGuidance (targets + advice),
                       SleepTimeline (restful/light/awake), HeartRateZones, SleepNeedBreakdown,
                       TrendInsights (period comparisons + plain-language insights)
      Protocol/        Swift port of re-toolkit/protocol (Whoop namespace): CRCs, frames, reassembler,
                       allowlisted command builders, packet decoder, 0x2A37 parser
                       -> must match re-toolkit/protocol on shared/test-vectors/protocol_v1.json
                       HistorySync (download state machine: never acks before save), SimulatedBand
                       (a fake band that speaks the protocol), MinuteBuilder (1 Hz records -> minutes)
    Tests/PulseCoreTests/
  Pulse/               the SwiftUI app (needs Xcode)
    App/               PulseApp, RootView (tabs), Design (DS tokens = DESIGN.md in code)
    Data/              SwiftData models, PulseStore, DemoDataLoader
    Features/          Today, Recovery (detail), Sleep, Activity (+ workout detail), Trends,
                       Settings (profile + recalculate), Welcome (first launch), Shared components
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
