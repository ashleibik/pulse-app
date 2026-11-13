# Pulse cloud (optional)

Pulse works fully offline. This folder adds three optional things, all running in **your own**
Supabase project:

| Feature | What it does | Function |
|---|---|---|
| Claude connector (Phase 8) | Claude can read your summaries, after you sign in | `functions/mcp` |
| Coach (Phase 9) | Chat about your data inside the app | `functions/coach` |
| Strava (Phase 7) | Upload workouts to Strava | `functions/strava` |

> **Status: written and unit-tested, never deployed.** No Supabase project exists for Pulse yet,
> so nothing here has run against real services. Expect small fixes on the first deploy.

## What is stored, and who can read it

- **Uploaded:** daily summaries, sleep sessions, workouts. **Never uploaded:** heartbeats and
  minute-by-minute data.
- **Row Level Security** on every table: a signed-in user sees only their own rows.
- **Claude is read-only.** Its token carries a `client_id`, and the database refuses writes from
  such tokens (`migrations/…_pulse_init.sql`).
- **Secrets stay on the server:** the Anthropic key and the Strava secret are Supabase secrets.
  Strava tokens sit in a table no user (and not Claude) can read. Nothing secret is in the app
  or in git.
- **Strava's rules** (API Policy, June 2026): data from Strava may not be given to an AI or
  served over MCP. Pulse only *uploads* to Strava and reads nothing back, so there is no Strava
  data anywhere in this project.

## Setup (about 20 minutes)

You need the [Supabase CLI](https://supabase.com/docs/guides/cli) and a free Supabase account.

1. **Create a project** at supabase.com (pick a region near you). Note its *Project URL* and
   *publishable key* (Settings > API Keys).
2. **Close the doors.** Authentication > Sign In / Providers: turn **off** "Allow new users to
   sign up". Then Authentication > Users > *Add user*: your email + a long password, with
   "Auto confirm user" ticked. That is the only account that will ever exist.
3. **Database and functions:**
   ```bash
   supabase link --project-ref YOUR-PROJECT-REF
   supabase db push                      # creates the tables + security rules
   supabase functions deploy             # deploys mcp, coach and strava
   ```
4. **In the app:** Settings > Cloud: paste the Project URL and publishable key, sign in, tap
   *Upload now*.

### Claude connector

5. Authentication > OAuth Server: **enable** it, allow **dynamic client registration**, and set
   the Authorization Path to `/` .
6. Put your Project URL and publishable key into `consent/index.html` (the `CONFIG` block), then
   host that one file on any static host (Cloudflare Pages, Netlify, GitHub Pages...).
   Set Authentication > URL Configuration > **Site URL** to where it is hosted.
7. In Claude: Settings > Connectors > *Add custom connector*, and paste
   `https://YOUR-PROJECT-REF.supabase.co/functions/v1/mcp` (the app shows it under Settings >
   Claude). Sign in on the page that opens and press *Allow*.

### Coach

8. Create a key at console.anthropic.com, then:
   ```bash
   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
   ```
   The coach uses `claude-opus-5-5` with server-side fallbacks enabled, and each user is limited
   to 40 questions a day (`DAILY_LIMIT` in `functions/coach/index.ts`).

### Strava

9. You need an **active Strava subscription** (required for API developers since June 2026).
   Create an API application at strava.com/settings/api with the *Authorization Callback Domain*
   `YOUR-PROJECT-REF.supabase.co`, then:
   ```bash
   supabase secrets set STRAVA_CLIENT_ID=12345 STRAVA_CLIENT_SECRET=...
   ```
10. In the app: Settings > Strava > *Connect Strava*. Open a workout and tap *Send to Strava*.

## Tests

```bash
node --experimental-strip-types --test supabase/tests/mcp-core.test.mjs
```
Covers the MCP logic: protocol answers, read-only tool list, argument limits, the
"simulated data" warning, and that errors never leak internals. The HTTP layer, sign-in and the
database rules are **not** covered by automated tests yet: check them by hand after deploying
(for example: a request without a token must get `401` with a `WWW-Authenticate` header).

## Known gaps

- Strava tokens are protected by database rules and Supabase's disk encryption, but are not
  encrypted column by column. Supabase Vault would be the next step.
- Strava's brand guidelines (button artwork) were not checked. Fine for a personal app; check
  them before sharing the app with anyone.
- Removing a connector's access is done in the Supabase dashboard (Authentication > OAuth Apps),
  not yet from the app.
