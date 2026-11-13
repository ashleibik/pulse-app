// Pulse -> Strava (Phase 7): connect a Strava account and upload workouts to it.
//
// Why a server function: Strava's OAuth needs a client secret, and a secret must never be inside
// the app. It lives only here, as the Supabase secrets STRAVA_CLIENT_ID / STRAVA_CLIENT_SECRET.
// The user's Strava tokens are stored in a table nobody but this function can read.
//
// What Strava's terms allow (API Agreement + API Policy, effective June 1, 2026; read 2026-11-13):
//   * Uploading activities: allowed (Agreement 7.1). This function ONLY uploads.
//   * Using data from Strava's API with AI, or serving it through an MCP server: prohibited
//     (Policy 5.3, 5.16(b)). So this function requests the write-only scope `activity:write`,
//     never reads activities, and stores nothing Strava returns except the tokens it needs.
//   * The developer (you) needs an active Strava subscription to use the API (Standard tier).
//
// ⚠ Not run against Strava yet (no API application exists). The endpoints below are Strava's
//   long-standing ones; check them at https://developers.strava.com before the first real use.
//
// Routes:
//   POST {action: "start"}       signed-in user -> { url } to open in the app's sign-in sheet
//   GET  ?code=..&state=..       Strava redirects here; tokens are saved; the app is reopened
//   POST {action: "status"}      -> { connected }
//   POST {action: "upload", tcx, name, external_id}  -> { ok }
//   POST {action: "disconnect"}  revokes Pulse at Strava and deletes the tokens

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CLIENT_ID = Deno.env.get("STRAVA_CLIENT_ID") ?? "";
const CLIENT_SECRET = Deno.env.get("STRAVA_CLIENT_SECRET") ?? "";

const CALLBACK_URL = `${SUPABASE_URL}/functions/v1/strava`;
const APP_RETURN_URL = "pulse://strava"; // the app's sign-in sheet listens for this scheme
const STATE_LIFETIME_MS = 10 * 60 * 1000;
const MAX_TCX_BYTES = 2 * 1024 * 1024;

const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const backToApp = (status: string) =>
  new Response(null, { status: 302, headers: { Location: `${APP_RETURN_URL}?status=${status}` } });

/** Server-only database access, for the token and state tables that no user may read. */
const admin = () => createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

/** Returns the signed-in user's id, or null. */
async function userFrom(request: Request): Promise<string | null> {
  const token = (request.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { data } = await client.auth.getUser(token);
  return data?.user?.id ?? null;
}

async function tokenRequest(params: Record<string, string>) {
  const response = await fetch("https://www.strava.com/oauth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: CLIENT_ID, client_secret: CLIENT_SECRET, ...params }),
  });
  if (!response.ok) throw new Error(`Strava token endpoint answered ${response.status}`);
  return await response.json() as { access_token: string; refresh_token: string; expires_at: number };
}

async function saveTokens(db: SupabaseClient, userID: string, t: { access_token: string; refresh_token: string; expires_at: number }) {
  const { error } = await db.from("strava_token").upsert({
    user_id: userID,
    access_token: t.access_token,
    refresh_token: t.refresh_token,
    expires_at: new Date(t.expires_at * 1000).toISOString(),
    updated_at: new Date().toISOString(),
  });
  if (error) throw error;
}

/** A valid access token for this user, refreshed if it is about to expire. Null = not connected. */
async function accessToken(db: SupabaseClient, userID: string): Promise<string | null> {
  const { data } = await db.from("strava_token").select("access_token,refresh_token,expires_at").eq("user_id", userID).maybeSingle();
  if (!data) return null;
  if (new Date(data.expires_at).getTime() - Date.now() > 5 * 60 * 1000) return data.access_token;
  const fresh = await tokenRequest({ grant_type: "refresh_token", refresh_token: data.refresh_token });
  await saveTokens(db, userID, fresh);
  return fresh.access_token;
}

Deno.serve(async (request) => {
  if (!CLIENT_ID || !CLIENT_SECRET) {
    return reply({ error: "not_configured", message: "Strava isn't set up on the server yet." }, 503);
  }
  const db = admin();

  // ---- Strava sends the user back here after they approve (or refuse) ----
  if (request.method === "GET") {
    const url = new URL(request.url);
    const state = url.searchParams.get("state") ?? "";
    const code = url.searchParams.get("code") ?? "";
    if (url.searchParams.get("error") || !state || !code) return backToApp("cancelled");

    // The state proves this redirect belongs to a sign-in that one of OUR users started.
    const { data: pending } = await db.from("strava_oauth_state").select("user_id,created_at").eq("state", state).maybeSingle();
    await db.from("strava_oauth_state").delete().eq("state", state); // one use only
    if (!pending || Date.now() - new Date(pending.created_at).getTime() > STATE_LIFETIME_MS) return backToApp("expired");

    // Without the write scope, uploads would fail later: say so now.
    if (!(url.searchParams.get("scope") ?? "").includes("activity:write")) return backToApp("no_permission");
    try {
      const tokens = await tokenRequest({ grant_type: "authorization_code", code });
      await saveTokens(db, pending.user_id, tokens);
      return backToApp("connected");
    } catch (error) {
      console.error("strava callback", error);
      return backToApp("failed");
    }
  }

  if (request.method !== "POST") return reply({ error: "method_not_allowed" }, 405);

  // ---- Everything else needs a signed-in Pulse user ----
  const userID = await userFrom(request);
  if (!userID) return reply({ error: "unauthorized" }, 401);
  let body: { action?: string; tcx?: string; name?: string; external_id?: string };
  try {
    body = await request.json();
  } catch {
    return reply({ error: "invalid_json" }, 400);
  }

  try {
    switch (body.action) {
      case "start": {
        const state = crypto.randomUUID() + crypto.randomUUID();
        const { error } = await db.from("strava_oauth_state").insert({ state, user_id: userID });
        if (error) throw error;
        const url = new URL("https://www.strava.com/oauth/mobile/authorize");
        url.search = new URLSearchParams({
          client_id: CLIENT_ID,
          redirect_uri: CALLBACK_URL,
          response_type: "code",
          approval_prompt: "auto",
          scope: "activity:write", // write-only: Pulse never asks to read your Strava data
          state,
        }).toString();
        return reply({ url: url.toString() });
      }

      case "status":
        return reply({ connected: (await accessToken(db, userID)) !== null });

      case "upload": {
        const { tcx, name, external_id } = body;
        if (typeof tcx !== "string" || !tcx.startsWith("<?xml") || tcx.length > MAX_TCX_BYTES) {
          return reply({ error: "invalid_file" }, 400);
        }
        if (typeof external_id !== "string" || !/^pulse-[0-9a-f-]{36}$/.test(external_id)) {
          return reply({ error: "invalid_external_id" }, 400);
        }
        const token = await accessToken(db, userID);
        if (!token) return reply({ error: "not_connected" }, 409);

        const form = new FormData();
        form.append("file", new Blob([tcx], { type: "application/xml" }), `${external_id}.tcx`);
        form.append("data_type", "tcx");
        form.append("external_id", external_id);
        form.append("name", typeof name === "string" ? name.slice(0, 100) : "Workout");
        form.append("description", "Recorded with Pulse.");
        const response = await fetch("https://www.strava.com/api/v3/uploads", {
          method: "POST",
          headers: { Authorization: `Bearer ${token}` },
          body: form,
        });
        if (response.status === 401) return reply({ error: "not_connected" }, 409);
        if (response.status === 429) return reply({ error: "rate_limited", message: "Strava's limit was reached. Try later." }, 429);
        const result = await response.json().catch(() => ({})) as { error?: string };
        // Strava answers "duplicate of activity ..." when this external_id was uploaded before.
        // For us that means "already there": a success.
        const duplicate = typeof result.error === "string" && result.error.includes("duplicate");
        if (!response.ok && !duplicate) {
          console.error("strava upload", response.status, result.error);
          return reply({ error: "upload_failed", message: "Strava did not accept the workout." }, 502);
        }
        // Nothing Strava returned is stored or passed on (7-day cache rule, no-AI rule).
        return reply({ ok: true, duplicate });
      }

      case "disconnect": {
        const token = await accessToken(db, userID).catch(() => null);
        if (token) {
          await fetch("https://www.strava.com/oauth/deauthorize", {
            method: "POST",
            headers: { Authorization: `Bearer ${token}` },
          }).catch(() => undefined);
        }
        await db.from("strava_token").delete().eq("user_id", userID);
        return reply({ ok: true });
      }

      default:
        return reply({ error: "unknown_action" }, 400);
    }
  } catch (error) {
    console.error("strava failure", error);
    return reply({ error: "server_error" }, 500);
  }
});
