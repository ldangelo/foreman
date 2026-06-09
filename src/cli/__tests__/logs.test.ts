import { describe, expect, it } from "vitest";
import { extractPhaseEvents, extractRecentToolEvents } from "../commands/logs.js";

describe("logs command helpers", () => {
  it("extracts relevant phase events from err logs", () => {
    const events = extractPhaseEvents([
      JSON.stringify({ timestamp: "2026-06-09T01:00:00.000Z", message: "[FIX] Completed (3 turns, $0.01)" }),
      JSON.stringify({ timestamp: "2026-06-09T01:00:01.000Z", message: "[DEVELOPER] Skipping — retryOnly phase not activated by retryWith" }),
      JSON.stringify({ timestamp: "2026-06-09T01:00:02.000Z", message: "ordinary info" }),
    ].join("\n"));

    expect(events.map((event) => event.message)).toEqual([
      "[FIX] Completed (3 turns, $0.01)",
      "[DEVELOPER] Skipping — retryOnly phase not activated by retryWith",
    ]);
  });

  it("extracts recent tool execution events from raw JSON logs", () => {
    const events = extractRecentToolEvents([
      JSON.stringify({ type: "tool_execution_start", toolName: "bash", args: { command: "npm test" } }),
      JSON.stringify({ type: "tool_execution_end", toolName: "bash" }),
      JSON.stringify({ type: "message_update" }),
      JSON.stringify({ type: "tool_execution_start", toolName: "read", args: { path: "src/cli/index.ts" } }),
    ].join("\n"), 2);

    expect(events).toEqual([
      { kind: "end", tool: "bash" },
      { kind: "start", tool: "read", detail: "src/cli/index.ts" },
    ]);
  });
});
