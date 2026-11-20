# Pulse

A personal, local-first fitness app for iPhone that reads **my own** WHOOP 4.0 band over
Bluetooth and turns its heart-rate and motion data into three answers: how recovered am I, how
hard have I pushed, how well did I sleep.

It does not use WHOOP's cloud, servers, or accounts. Personal learning project, not affiliated
with or endorsed by WHOOP, Inc. General wellness only, not medical advice.

## What works, and how sure we are

| Part | State | Checked by |
|---|---|---|
| Band protocol (frames, checksums, commands, history sync) | Built | 58 Python tests + Swift parity tests on shared vectors |
| Metrics (sleep, HRV, strain, recovery, workout detection) | Built | 90 Swift tests, same numbers as the Python reference |
| iPhone app, every screen, light and dark | Built | Compiled and screenshotted on a cloud Mac on every push |
| Pairing + history sync | Built | End to end with a **simulated band**. **Never run on a real band** |
| Cloud: Claude connector, coach, Strava | Written | MCP logic tested. **Never deployed** |
| TestFlight build | Written | **Never run** (needs an Apple Developer account) |

Nothing has run on a physical iPhone or against the physical band yet. Details and open
protocol questions: [re-toolkit/docs/PROTOCOL.md](re-toolkit/docs/PROTOCOL.md).

## Repository

| Folder | What lives there |
|---|---|
| `re-toolkit/` | Python reverse-engineering toolkit: protocol source of truth, sniffer, tests |
| `ios/PulseCore/` | Pure Swift logic (protocol, metrics, insights). Builds and tests on Windows, Linux, macOS |
| `ios/Pulse/` | The SwiftUI app (iOS 17+): screens, storage, Bluetooth, cloud client |
| `ios/design/` | The "Mono" design system: black, white and grays only |
| `supabase/` | Optional cloud: database rules, MCP server for Claude, coach, Strava upload |
| `shared/test-vectors/` | Inputs + expected outputs that both the Python and the Swift code must reproduce |
| `docs/` | Plan, metric formulas with sources, security review, web preview |

## Try it

| I want to... | Do this |
|---|---|
| See the app without a Mac | Push a change under `ios/`, then `gh run download --name screenshots` ([ios/README.md](ios/README.md)) |
| Click through a look-alike | `.\ios\scripts\build-preview.ps1`, open `docs/preview/pulse-preview.html` |
| Run the Swift tests on Windows | `.\ios\scripts\test-core.ps1` |
| Run the Python tests | `cd re-toolkit; .\.venv\Scripts\python -m pytest -q` |
| Run the server tests | `node --experimental-strip-types --test supabase/tests/mcp-core.test.mjs` |
| Talk to the real band from the PC | [re-toolkit/docs/CAPTURE_GUIDE.md](re-toolkit/docs/CAPTURE_GUIDE.md) |
| Install on your own iPhone, free | "Install on your iPhone" in [ios/README.md](ios/README.md) (sideload with your Apple ID, re-install every 7 days) |
| Set up Claude, the coach or Strava | [supabase/README.md](supabase/README.md) |

## How it fits together

```
WHOOP band --Bluetooth--> BandSession (decode, checksums, command allowlist)
                              |  history is saved first, acknowledged second
                              v
                    SwiftData on the phone (raw minutes + summaries)
                              v
                    MetricsEngine + WorkoutDetector (pure Swift, tested)
                              v
        SwiftUI screens
                              |
                              v  summaries only, if you turn it on
        your Supabase project --> MCP server --> Claude        (read only)
                              --> coach function --> Claude API (key stays on the server)
                              --> Strava upload               (upload only)
```

## Security and privacy in one minute

- **Your band, your phone.** Only an allowlist of safe commands can be sent to the band; erase,
  reboot and firmware commands cannot even be built.
- **Raw data never leaves the phone.** The optional cloud gets summaries only.
- **No secrets in the app or in git.** API keys live as server secrets; the app keeps its
  session in the iOS Keychain.
- **Demo data is labelled everywhere** and is never sent to Strava.
- **Strava data never reaches an AI** (Strava's terms forbid it): Pulse only uploads to Strava.

Full review with open findings: [docs/SECURITY.md](docs/SECURITY.md).

## More

[docs/PHASE0_PLAN.md](docs/PHASE0_PLAN.md) (the original plan) ·
[docs/METRICS.md](docs/METRICS.md) (every formula, with sources) ·
[ios/design/DESIGN.md](ios/design/DESIGN.md) (design system) ·
[ios/README.md](ios/README.md) (app structure)
