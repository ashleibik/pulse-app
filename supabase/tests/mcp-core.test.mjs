// Tests for the MCP server's logic. Runs under plain Node (no Deno, no database):
//
//   node --experimental-strip-types --test supabase/tests/
//
// The database is replaced by a small fake that returns fixed rows.

import assert from "node:assert/strict";
import { test } from "node:test";
import { callTool, handleRpc, intArg, TOOLS } from "../functions/mcp/core.ts";

const day = (d, recovery, source = "history") => ({
  day: d, recovery_pct: recovery, recovery_word: recovery >= 67 ? "Ready" : recovery >= 34 ? "Steady" : "Rest",
  day_strain: 10, sleep_minutes: 420, sleep_need_minutes: 480, resting_hr: 54, hrv_rmssd: 60,
  baseline_resting_hr: 55, baseline_hrv: 61, explanation: "", source,
});

function fakeData(days) {
  const calls = [];
  return {
    calls,
    async days(limit) { calls.push(["days", limit]); return days.slice(0, limit); },
    async sleeps(since) { calls.push(["sleeps", since]); return []; },
    async workouts(since) { calls.push(["workouts", since]); return []; },
  };
}

const rpc = (method, params, id = 1) => ({ jsonrpc: "2.0", id, method, params });

test("initialize answers with a supported protocol version and offers only tools", async () => {
  const reply = await handleRpc(rpc("initialize", { protocolVersion: "2025-06-18" }), fakeData([]));
  assert.equal(reply.result.protocolVersion, "2025-06-18");
  assert.deepEqual(reply.result.capabilities, { tools: {} });
  assert.equal(reply.result.serverInfo.name, "pulse");

  const unknown = await handleRpc(rpc("initialize", { protocolVersion: "1999-01-01" }), fakeData([]));
  assert.equal(unknown.result.protocolVersion, "2025-06-18"); // falls back to one it knows
});

test("every tool is declared read-only and refuses unknown arguments", async () => {
  const reply = await handleRpc(rpc("tools/list"), fakeData([]));
  assert.equal(reply.result.tools.length, 4);
  for (const tool of TOOLS) {
    assert.equal(tool.annotations.readOnlyHint, true, tool.name);
    assert.equal(tool.inputSchema.additionalProperties, false, tool.name);
  }
});

test("notifications get no reply, unknown methods get an error", async () => {
  assert.equal(await handleRpc({ jsonrpc: "2.0", method: "notifications/initialized" }, fakeData([])), null);
  const reply = await handleRpc(rpc("resources/list"), fakeData([]));
  assert.equal(reply.error.code, -32601);
  const invalid = await handleRpc({ hello: "world" }, fakeData([]));
  assert.equal(invalid.error.code, -32600);
});

test("arguments are clamped, so a caller cannot ask for unlimited rows", async () => {
  assert.equal(intArg({ days: 100000 }, "days", 1, 60, 7), 60);
  assert.equal(intArg({ days: -5 }, "days", 1, 60, 7), 1);
  assert.equal(intArg({ days: "all" }, "days", 1, 60, 7), 7);
  assert.equal(intArg(null, "days", 1, 60, 7), 7);

  const data = fakeData([]);
  await callTool("get_recent_days", { days: 99999 }, data);
  assert.deepEqual(data.calls[0], ["days", 60]);
});

test("simulated data is announced as simulated", async () => {
  const real = await callTool("get_recent_days", {}, fakeData([day("2026-11-13", 70)]));
  assert.match(real.note, /Measured by the user's band/);
  const demo = await callTool("get_recent_days", {}, fakeData([day("2026-11-13", 70, "simulated")]));
  assert.match(demo.note, /SIMULATED DEMO DATA/);
});

test("trends compare the last N days with the N before", async () => {
  const days = [80, 70, 60, 40, 30, 20].map((r, i) => day(`2026-11-${String(13 - i).padStart(2, "0")}`, r));
  const result = await callTool("get_trends", { period_days: 3 }, fakeData(days));
  assert.equal(result.current.recovery_pct, 70);
  assert.equal(result.previous.recovery_pct, 30);
  assert.equal(result.current.days_with_data, 3);
});

test("a tool call returns JSON text, and failures do not leak internals", async () => {
  const ok = await handleRpc(rpc("tools/call", { name: "get_recent_days", arguments: { days: 1 } }), fakeData([day("2026-11-13", 37)]));
  const payload = JSON.parse(ok.result.content[0].text);
  assert.equal(payload.days[0].recovery_pct, 37);

  const broken = { async days() { throw new Error("password=hunter2 connection refused"); }, async sleeps() { return []; }, async workouts() { return []; } };
  const failed = await handleRpc(rpc("tools/call", { name: "get_recent_days" }), broken);
  assert.equal(failed.result.isError, true);
  assert.doesNotMatch(JSON.stringify(failed), /hunter2/);

  const unknown = await handleRpc(rpc("tools/call", { name: "delete_everything" }), fakeData([]));
  assert.equal(unknown.error.code, -32602);
});
