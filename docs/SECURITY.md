# Security review (Phase 10)

Reviewed on 2026-11-13, by reading the code and scanning the repository. **Not** a penetration
test: nothing here has run on a real iPhone, against the real band, or on a deployed server.
Items marked ⚠ are open.

## What needs protecting

| Asset | Where it lives | Worst case if it leaks |
|---|---|---|
| Raw heart-rate and motion data | iPhone only (SwiftData) | Reveals sleep times, daily routine, health hints |
| Daily summaries, sleeps, workouts | iPhone, and your Supabase project if you turn cloud on | Same, less detailed |
| Cloud session (access + refresh token) | iOS Keychain | Someone reads / overwrites your summaries |
| Anthropic API key, Strava client secret | Supabase secrets (server only) | Someone spends your API credit / abuses your Strava app |
| Strava tokens | Server-only database table | Someone uploads activities to your Strava |
| The band itself | Your wrist | A wrong command could erase its stored data |

## What is in place

### Band
- **Command allowlist.** The app and the Python toolkit can only build 17 known-safe commands.
  Erase, reboot, power-cycle and firmware commands are not on the list, so no code path can send
  them (`Whoop.buildCommand` throws; tested in both languages).
- **Checksums on everything received.** Frames with a bad CRC are counted and dropped, never used.
- **Save first, acknowledge second.** A history batch is acknowledged to the band only after it
  is on disk, so a crash can't lose data the band has already freed (tested).
- **No WHOOP cloud.** The app has no code that contacts WHOOP's servers.

### Phone
- **No third-party libraries** in the app: only Apple frameworks and this repo's own code.
- **Keychain** for the cloud session, readable only on this device after first unlock.
  The password is sent once to sign in and never stored.
- **No logging of health data**: the app has no `print` / log statements (checked by scan).
- **HTTPS only**: the cloud URL must start with `https://`; the app has no plain-http address.
- **Apple Health is write-only**, and simulated data is never written (rule + test).
- **The debug packet log** is memory-only, capped at 400 lines, hidden behind 7 taps.

### Cloud (your own Supabase project)
- **Row Level Security on every table**; `user_id` is set by the database, not by the app.
- **Claude is read-only at the database level**: OAuth tokens (which carry `client_id`) fail the
  write policies, whatever the function code does.
- **The MCP and coach functions act as the caller** (the caller's token), not with the
  service-role key. The service role is used only for the server-only tables.
- **Sign-in follows Claude's connector rules** (OAuth 2.1 via Supabase Auth, 401 + resource
  metadata, token only in the header, never in the URL).
- **Sign-ups are meant to be off**, with one account created by you (supabase/README.md step 2).
- **Coach limits**: 40 questions per user per day, 20 messages and 4,000 characters per message.
  It has no tools, so it cannot act on anything; it only reads 14 days of your summaries.
- **Errors are generic** to callers; details go to the function logs only (tested for MCP).
- **Strava**: write-only scope (`activity:write`), one-time `state` values with a 10-minute
  life (CSRF protection), nothing Strava returns is stored except its tokens.

### Repository
- **Scan result**: no keys, tokens or passwords in tracked files. `.gitignore` covers `.env*`,
  key files, and band captures (which contain real heart-rate data).
- **CI** runs with `contents: read` only. The TestFlight key exists only as a GitHub secret and
  is deleted from the runner after use.

## Open findings

| # | Finding | Risk | Suggested fix |
|---|---|---|---|
| 1 | ⚠ Nothing was tested on real hardware or a deployed server | Unknown bugs | Test each part once the band, an Apple account and a Supabase project exist |
| 2 | ⚠ `mcp` and `strava` are deployed with the platform token check off (needed for the 401 flow and Strava's redirect) | A coding mistake there would expose the function | After deploying, confirm by hand: no token -> 401; another user's token -> only their rows |
| 3 | ⚠ Dynamic client registration lets any app *ask* for access | Phishing: a fake app asks you to approve it | The consent page shows the app name and where it sends you back. Only approve right after adding the connector yourself. Remove unknown apps in the dashboard |
| 4 | ⚠ Strava tokens are not encrypted column by column | Readable by anyone with database admin access | Move them to Supabase Vault |
| 5 | ⚠ `consent/index.html` loads supabase-js from a CDN without a pinned version or integrity hash | A compromised CDN could steal the password typed there | Pin the exact version and add a Subresource Integrity hash, or host the script yourself |
| 6 | ⚠ Server dependencies are pinned loosely (`supabase-js@2`) | A bad release would be picked up on the next deploy | Pin exact versions before real use |
| 7 | ⚠ The local database uses iOS's default file protection | Readable after first unlock if the phone is compromised | Set file protection to "complete unless open"; consider a Face ID lock |
| 8 | ⚠ No schema migration plan for the phone database | An app update that changes models could fail to open old data | Add a versioned schema before the first real install |
| 9 | ⚠ Whether the band needs Bluetooth bonding is unknown | Someone nearby with the same tools might read an unbonded band | Check with the real band; this is a property of the band, not of the app |
| 10 | Git commits carry a personal email address | Visible if the repo is made public | Use GitHub's noreply address before publishing |
| 11 | Strava brand guidelines not reviewed | Terms issue if the app is shared | Review before sharing; irrelevant for personal use |

## Rules that came from other people's terms

- **WHOOP**: no use of its cloud or accounts; the name is not used as the app's name.
- **Strava** (API Agreement + API Policy, effective June 1, 2026): upload is allowed; data from
  its API may not be used with AI or served over MCP; cached data at most 7 days; an active
  subscription is required for developers. Pulse uploads only.
- **Anthropic**: the API key stays on the server; the coach states it is not medical advice.
