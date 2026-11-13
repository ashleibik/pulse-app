// The MCP server's logic, with no Deno or network code in it, so it runs under plain Node for
// tests (supabase/tests/mcp-core.test.mjs). index.ts adds HTTP, sign-in checks and the database.
//
// MCP = Model Context Protocol: the standard way Claude calls tools on a server. Messages are
// JSON-RPC 2.0. This server only offers read-only tools over the user's own Pulse summaries.
//
// Strava rule (API Policy, June 2026, sections 5.3 and 5.16(b)): nothing obtained from Strava may be
// given to an AI or served through an MCP server. Pulse never downloads anything from Strava,
// and these tools only read the three band-data tables, so there is nothing of Strava's here.

export interface DayRow {
  day: string;
  recovery_pct: number | null;
  recovery_word: string | null;
  day_strain: number;
  sleep_minutes: number | null;
  sleep_need_minutes: number;
  resting_hr: number | null;
  hrv_rmssd: number | null;
  baseline_resting_hr: number | null;
  baseline_hrv: number | null;
  explanation: string;
  source: string;
}

export interface SleepRow {
  start_at: string;
  end_at: string;
  asleep_minutes: number;
  awake_minutes: number;
  disturbances: number;
  is_nap: boolean;
  source: string;
}

export interface WorkoutRow {
  start_at: string;
  end_at: string;
  kind: string;
  avg_hr: number;
  max_hr: number;
  strain: number;
  zone_seconds: number[];
  source: string;
}

/** Where the rows come from. index.ts implements this with the signed-in user's database access. */
export interface PulseData {
  /** Newest first. */
  days(limit: number): Promise<DayRow[]>;
  sleeps(sinceIso: string): Promise<SleepRow[]>;
  workouts(sinceIso: string): Promise<WorkoutRow[]>;
}

export const SERVER_INFO = { name: "pulse", title: "Pulse", version: "1.0.0" };
const SUPPORTED_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26"];

const INSTRUCTIONS =
  "Pulse holds the user's own fitness summaries from their wrist band: daily recovery (0-100%), " +
  "strain (0-21), sleep, resting heart rate and HRV, plus workouts. All tools are read-only. " +
  "Recovery compares last night's HRV, resting heart rate and sleep with the user's own 14-day " +
  "normal; 50% means exactly normal. If a result says the data is simulated, tell the user that " +
  "clearly. This is general wellness information, not medical advice.";

const number = (description: string, minimum: number, maximum: number, fallback: number) => ({
  type: "integer",
  description: `${description} (${minimum}-${maximum}, default ${fallback})`,
  minimum,
  maximum,
});

export const TOOLS = [
  {
    name: "get_recent_days",
    title: "Recent days",
    description:
      "Daily summaries, newest first: recovery %, recovery word (Ready / Steady / Rest), strain, " +
      "sleep minutes vs need, resting heart rate, HRV, the user's baselines, and a one-line explanation.",
    inputSchema: {
      type: "object",
      properties: { days: number("How many days back", 1, 60, 7) },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  {
    name: "get_sleep",
    title: "Sleep sessions",
    description:
      "Sleep sessions (nights and naps), newest first: start, end, minutes asleep, minutes awake, " +
      "number of wake-ups. Pulse does not measure sleep stages (REM / deep).",
    inputSchema: {
      type: "object",
      properties: { nights: number("How many days back", 1, 60, 7) },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  {
    name: "get_workouts",
    title: "Workouts",
    description:
      "Workouts, newest first: kind, start, end, average and max heart rate, strain (0-21), and " +
      "seconds in heart-rate zones 1-5. Workouts found automatically have kind 'other'.",
    inputSchema: {
      type: "object",
      properties: { days: number("How many days back", 1, 90, 14) },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  {
    name: "get_trends",
    title: "Trends",
    description:
      "Averages for the last N days compared with the N days before: recovery, strain, sleep, " +
      "resting heart rate and HRV. Use this for 'how is my week going' questions.",
    inputSchema: {
      type: "object",
      properties: { period_days: number("Length of each period", 3, 30, 7) },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
];

// ---------- helpers ----------

/** Reads an integer argument, clamped to its allowed range. Anything else gives the default. */
export function intArg(args: unknown, key: string, min: number, max: number, fallback: number): number {
  const value = (args as Record<string, unknown> | null | undefined)?.[key];
  if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
  return Math.min(max, Math.max(min, Math.round(value)));
}

function isoDaysAgo(days: number, now: Date): string {
  return new Date(now.getTime() - days * 86_400_000).toISOString();
}

function average(values: (number | null)[]): number | null {
  const known = values.filter((v): v is number => typeof v === "number");
  if (known.length === 0) return null;
  return Math.round((known.reduce((a, b) => a + b, 0) / known.length) * 10) / 10;
}

/** Says so loudly when any row is demo data, so Claude never presents it as real. */
function note(rows: { source: string }[]): string {
  const simulated = rows.some((r) => r.source === "simulated");
  return simulated
    ? "SIMULATED DEMO DATA: these numbers were generated by the app, not measured. Tell the user."
    : "Measured by the user's band. General wellness information, not medical advice.";
}

export async function callTool(name: string, args: unknown, data: PulseData, now = new Date()): Promise<unknown> {
  switch (name) {
    case "get_recent_days": {
      const days = await data.days(intArg(args, "days", 1, 60, 7));
      return { note: note(days), days };
    }
    case "get_sleep": {
      const sleeps = await data.sleeps(isoDaysAgo(intArg(args, "nights", 1, 60, 7), now));
      return { note: note(sleeps), sleeps };
    }
    case "get_workouts": {
      const workouts = await data.workouts(isoDaysAgo(intArg(args, "days", 1, 90, 14), now));
      return { note: note(workouts), workouts };
    }
    case "get_trends": {
      const period = intArg(args, "period_days", 3, 30, 7);
      const rows = await data.days(period * 2);
      const current = rows.slice(0, period);
      const previous = rows.slice(period, period * 2);
      const summarize = (set: DayRow[]) => ({
        days_with_data: set.length,
        recovery_pct: average(set.map((d) => d.recovery_pct)),
        day_strain: average(set.map((d) => d.day_strain)),
        sleep_minutes: average(set.map((d) => d.sleep_minutes)),
        resting_hr: average(set.map((d) => d.resting_hr)),
        hrv_rmssd: average(set.map((d) => d.hrv_rmssd)),
      });
      return { note: note(rows), period_days: period, current: summarize(current), previous: summarize(previous) };
    }
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
}

// ---------- JSON-RPC ----------

interface RpcRequest {
  jsonrpc?: string;
  id?: string | number | null;
  method?: string;
  params?: Record<string, unknown>;
}

const rpcError = (id: RpcRequest["id"], code: number, message: string) => ({
  jsonrpc: "2.0",
  id: id ?? null,
  error: { code, message },
});

/**
 * Handles one JSON-RPC message. Returns the reply, or `null` for notifications (which get none).
 * Never throws: every problem becomes a JSON-RPC error or a tool error, without internal details.
 */
export async function handleRpc(message: unknown, data: PulseData): Promise<object | null> {
  const request = message as RpcRequest;
  if (!request || typeof request !== "object" || request.jsonrpc !== "2.0" || typeof request.method !== "string") {
    return rpcError(null, -32600, "Invalid request");
  }
  const { id, method, params } = request;
  const isNotification = id === undefined;

  switch (method) {
    case "initialize": {
      const asked = typeof params?.protocolVersion === "string" ? params.protocolVersion : "";
      return {
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: SUPPORTED_VERSIONS.includes(asked) ? asked : SUPPORTED_VERSIONS[1],
          capabilities: { tools: {} },
          serverInfo: SERVER_INFO,
          instructions: INSTRUCTIONS,
        },
      };
    }
    case "ping":
      return { jsonrpc: "2.0", id, result: {} };
    case "tools/list":
      return { jsonrpc: "2.0", id, result: { tools: TOOLS } };
    case "tools/call": {
      const name = typeof params?.name === "string" ? params.name : "";
      if (!TOOLS.some((tool) => tool.name === name)) return rpcError(id, -32602, `Unknown tool: ${name}`);
      try {
        const result = await callTool(name, params?.arguments, data);
        return { jsonrpc: "2.0", id, result: { content: [{ type: "text", text: JSON.stringify(result) }] } };
      } catch (_error) {
        // The real error is logged by index.ts. The model only learns that it failed.
        return {
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: "Pulse could not read the data. Try again later." }], isError: true },
        };
      }
    }
    default:
      if (isNotification) return null; // e.g. notifications/initialized
      return rpcError(id, -32601, `Method not found: ${method}`);
  }
}
