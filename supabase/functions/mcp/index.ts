// Pulse MCP server (Phase 8): lets Claude read YOUR Pulse summaries, after you sign in.
//
// Transport: MCP "Streamable HTTP" (one POST per JSON-RPC message, JSON replies).
// Sign-in:   OAuth 2.1, provided by this project's Supabase Auth ("OAuth Server" feature).
//            Claude's connector requirements were read on 2026-11-13 from
//            https://claude.com/docs/connectors/building/authentication :
//              - an unauthenticated request must get a 401 whose WWW-Authenticate header points
//                at the protected-resource metadata (RFC 9728);
//              - that metadata names the authorization server (Supabase Auth);
//              - tokens are never accepted from the URL.
//
// Security:
//   * Deployed with verify_jwt = false (see supabase/config.toml) ONLY so that this code can
//     answer with the 401 + header Claude needs. Every request is still verified below.
//   * The database is queried WITH THE CALLER'S OWN TOKEN, so Row Level Security decides what
//     they can see. This function never uses the service-role key.
//   * Read-only: the tools only run SELECTs, and the database refuses writes from OAuth tokens.

import { createClient } from "npm:@supabase/supabase-js@2";
import { type DayRow, handleRpc, type PulseData, type SleepRow, type WorkoutRow } from "./core.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

/** The public URL of this server, exactly as the user types it into Claude. */
const MCP_URL = `${SUPABASE_URL}/functions/v1/mcp`;
const METADATA_URL = `${MCP_URL}/.well-known/oauth-protected-resource`;
const MAX_BODY_BYTES = 64 * 1024;

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...headers },
  });

/** "Please sign in": the 401 that starts Claude's OAuth flow. */
const unauthorized = () =>
  json({ error: "unauthorized" }, 401, {
    "WWW-Authenticate": `Bearer resource_metadata="${METADATA_URL}"`,
  });

Deno.serve(async (request) => {
  const url = new URL(request.url);

  // RFC 9728 metadata: tells Claude which authorization server to use.
  if (request.method === "GET" && url.pathname.endsWith("/.well-known/oauth-protected-resource")) {
    return json({
      resource: MCP_URL,
      authorization_servers: [`${SUPABASE_URL}/auth/v1`],
      bearer_methods_supported: ["header"],
    });
  }

  if (request.method !== "POST") {
    // No server-to-client stream (GET) and no sessions to end (DELETE) in this small server.
    return json({ error: "method_not_allowed" }, 405, { Allow: "POST" });
  }

  // 1. Who is calling? The token must come in the Authorization header, never in the URL.
  const header = request.headers.get("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  if (!token) return unauthorized();

  // A database client that acts AS THE CALLER. Row Level Security applies to everything it does.
  const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: user, error: authError } = await supabase.auth.getUser(token);
  if (authError || !user?.user) return unauthorized();

  // 2. Read the message (with a size limit, so nobody can post megabytes at us).
  const raw = await request.text();
  if (raw.length > MAX_BODY_BYTES) return json({ error: "payload_too_large" }, 413);
  let message: unknown;
  try {
    message = JSON.parse(raw);
  } catch {
    return json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }, 400);
  }

  // 3. The data the tools may read: three tables, the caller's rows only (RLS), newest first.
  const data: PulseData = {
    async days(limit) {
      const { data, error } = await supabase.from("daily_summary")
        .select("day,recovery_pct,recovery_word,day_strain,sleep_minutes,sleep_need_minutes,resting_hr,hrv_rmssd,baseline_resting_hr,baseline_hrv,explanation,source")
        .order("day", { ascending: false }).limit(limit);
      if (error) throw error;
      return (data ?? []) as DayRow[];
    },
    async sleeps(sinceIso) {
      const { data, error } = await supabase.from("sleep_session")
        .select("start_at,end_at,asleep_minutes,awake_minutes,disturbances,is_nap,source")
        .gte("end_at", sinceIso).order("end_at", { ascending: false }).limit(200);
      if (error) throw error;
      return (data ?? []) as SleepRow[];
    },
    async workouts(sinceIso) {
      const { data, error } = await supabase.from("workout")
        .select("start_at,end_at,kind,avg_hr,max_hr,strain,zone_seconds,source")
        .gte("start_at", sinceIso).order("start_at", { ascending: false }).limit(200);
      if (error) throw error;
      return (data ?? []) as WorkoutRow[];
    },
  };

  // 4. Answer. A batch (array) gets an array back; notifications get no body.
  try {
    if (Array.isArray(message)) {
      const replies = (await Promise.all(message.slice(0, 20).map((m) => handleRpc(m, data)))).filter(Boolean);
      return replies.length > 0 ? json(replies) : new Response(null, { status: 202 });
    }
    const reply = await handleRpc(message, data);
    return reply ? json(reply) : new Response(null, { status: 202 });
  } catch (error) {
    console.error("mcp failure", error); // stays in the function logs, never sent to the caller
    return json({ jsonrpc: "2.0", id: null, error: { code: -32603, message: "Internal error" } }, 500);
  }
});
