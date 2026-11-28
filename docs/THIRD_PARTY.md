# Third-party code in Pulse

Pulse ports some logic from two open projects. The ported Swift lives in
`ios/PulseCore/Sources/PulseCore/ThirdParty/`, and each file names its source at the top.

## What this means for sharing Pulse

- **OpenStrap code is MIT.** It can be used in any project, as long as the notice below stays with it.
- **NOOP code is noncommercial only.** The files in `ThirdParty/NOOP/` are under the PolyForm Noncommercial License 1.0.0. While
  they are in Pulse, Pulse can't be sold or used commercially. Deleting them, and replacing their uses in `WorkoutDetector.swift`,
  `DailyCalories.swift`, `Wellbeing.swift`, `NightAnalysis.swift`, `SleepPerformance.swift` and `VO2Max.swift`, removes that limit.
- **Nothing here comes from OpenStrap's AGPL code.** OpenStrap moved to AGPL-3.0 after the commit below, so only that commit or
  earlier may be used as a source. Don't update these ports from a newer OpenStrap version without checking its license first.

## OpenStrap analytics

- Project: <https://github.com/OpenStrap/analytics>
- Commit: `e59d63ccc39713a6deb2facfd1c8288a5203398a`, the last one under the MIT license (see the project's `NOTICE`)

| Pulse file | OpenStrap file | What it does in Pulse |
|---|---|---|
| `OpenStrap/OpenStrapSpectrum.swift` | `lib/src/onehz/util.dart` | Lomb-Scargle spectrum |
| `OpenStrap/OpenStrapRespiration.swift` | `lib/src/onehz/respiration/resp_rate.dart` | Breathing rate |
| `OpenStrap/OpenStrapZones.swift` | `lib/src/onehz/workout/hr_zones.dart` | Heart-rate zones |
| `OpenStrap/OpenStrapCalories.swift` | `lib/src/onehz/workout/calories.dart` | Active calories |
| `OpenStrap/OpenStrapPedometer.swift` | `lib/src/onehz/motion/steps.dart` (Tier A: `StepParams`, `pedometer`, `calcSteps`, `livePedometer`) | Steps on the band's 100 Hz stream, minute by minute |

```text
MIT License

Copyright (c) 2026 OpenStrap

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## NOOP

- Project: <https://github.com/ryanbr/noop>
- Commit: `2a1de7609843b095505274ad6fc811757210be80`
- License: PolyForm Noncommercial License 1.0.0, <https://polyformproject.org/licenses/noncommercial/1.0.0>
- Required Notice: Copyright 2026 NoopApp

| Pulse file | NOOP file | What it does in Pulse |
|---|---|---|
| `NOOP/NoopWorkoutType.swift` | `Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutTypeClassifier.swift` | Tells strength, walking, running and cycling apart |
| `NOOP/NoopDaytimeStress.swift` | `Packages/StrandAnalytics/Sources/StrandAnalytics/DaytimeStress.swift`, `Strand/Screens/StressView.swift` | Daytime stress score and levels |
| `NOOP/NoopCalories.swift` | `Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutDetector.swift` (`enum Calories`) | Whole-day calories |
| `NOOP/NoopSleepStager.swift` | `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStagerV2.swift` | Deep, REM and light sleep |
| `NOOP/NoopFitness.swift` | `Packages/StrandAnalytics/Sources/StrandAnalytics/FitnessAgeEngine.swift`, `docs/FITNESS_AGE.md` | VO₂ max (Nes 2011 model, activity index, 4-of-7-nights gate) |
| `NOOP/NoopRestorative.swift` | `Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift` (`enum Rest`, restorative sub-score) | Restorative sleep level |
| `NOOP/NoopWorkoutDetector.swift` | `Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutDetector.swift` (`detect` and its helpers), `StrainScorer.swift` (Edwards zones) | Finding workouts from heart rate and movement |
| `NOOP/NoopStreak.swift` | `Packages/StrandAnalytics/Sources/StrandAnalytics/StreakCalculator.swift` (`streaks`), `Baselines.swift` (`isoEpochDay`) | Days in a row (which days count is Pulse's, docs/METRICS.md §17) |
| `NOOP/NoopNightBridge.swift` | `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStageTotals.swift` (`bridgedNightGroups`, `isOvernightOnset`) | A night broken by getting up is one sleep (which sleeps may join is Pulse's, docs/METRICS.md §4 step 8) |

## Pulse's own rules

Neither project records walks and runs from a WHOOP 4.0's own step count. Pulse's rule in `WorkoutDetector.swift` is its own:
10 minutes or more of minutes with 60 counted steps or more, pauses of up to 2 minutes, and a run from a median of 140 a minute
(docs/METRICS.md §10). When to stream the 100 Hz motion (`MotionStreamPolicy.swift`) and the walking cost in `DailyCalories.swift`
(ACSM's equations) are Pulse's own too.
