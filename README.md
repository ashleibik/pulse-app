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

Status: **Phase 0 (plan)**. See [docs/PHASE0_PLAN.md](docs/PHASE0_PLAN.md) and
[re-toolkit/docs/PROTOCOL.md](re-toolkit/docs/PROTOCOL.md).
