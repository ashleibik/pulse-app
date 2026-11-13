# whoop-diy

A personal, local-first fitness app for iPhone that reads data from **my own** WHOOP 4.0 band over Bluetooth.
It does not use WHOOP's cloud, servers, or accounts.

Personal learning project. Not affiliated with or endorsed by WHOOP, Inc.

| Folder | What lives there |
|---|---|
| `re-toolkit/` | Python reverse-engineering toolkit (protocol source of truth, sniffers, tests) |
| `ios/` | SwiftUI app (iOS 17+) |
| `backend/` | Supabase: Postgres + RLS, edge functions (MCP server, Strava, coach) |
| `docs/` | Plans and design notes |

The app is called **Pulse**.

Status: **Phase 2 (app skeleton + fake data)**. See [docs/PHASE0_PLAN.md](docs/PHASE0_PLAN.md),
[ios/README.md](ios/README.md), [re-toolkit/README.md](re-toolkit/README.md) and
[re-toolkit/docs/PROTOCOL.md](re-toolkit/docs/PROTOCOL.md).
