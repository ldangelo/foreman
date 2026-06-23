import { describe, expect, it } from "vitest";
import { tailRunLogs } from "../foreman-mcp-server.js";

const entries = [
  { type: "message_update", id: "1", timestamp: "2026-06-23T10:00:00Z", content: "typing..." },
  { type: "tool_execution_start", id: "2", timestamp: "2026-06-23T10:00:01Z", tool: "bash" },
  { type: "log", id: "3", timestamp: "2026-06-23T10:00:02Z", level: "info", message: "Build completed" },
  { type: "message_update", id: "4", timestamp: "2026-06-23T10:00:03Z", content: "still typing..." },
  { type: "error", id: "5", timestamp: "2026-06-23T10:00:04Z", level: "error", message: "Connection timeout" },
  { type: "tool_execution_end", id: "6", timestamp: "2026-06-23T10:00:05Z", tool: "bash" },
];

const rawLogEntries = [
  { stream: "stdout", timestamp: "2026-06-23T10:00:00Z", body: "Starting build..." },
  { stream: "message_update", timestamp: "2026-06-23T10:00:01Z", body: "Updating..." },
  { stream: "stdout", timestamp: "2026-06-23T10:00:02Z", body: "Build done" },
  { stream: "stderr", timestamp: "2026-06-23T10:00:03Z", body: "Warning: deprecated API" },
];

describe("tailRunLogs plain-view filtering", () => {
  it("filters message_update entries in plain view", () => {
    const result = tailRunLogs({ entries }, 50, "plain") as { entries: typeof entries };
    expect(result.entries.map((entry) => entry.type)).toEqual([
      "tool_execution_start",
      "log",
      "error",
      "tool_execution_end",
    ]);
  });

  it("keeps message_update entries in compact view", () => {
    const result = tailRunLogs({ entries }, 50, "compact") as { entries: typeof entries };
    expect(result.entries.some((entry) => entry.type === "message_update")).toBe(true);
  });

  it("applies limit after filtering", () => {
    const result = tailRunLogs({ entries }, 2, "plain") as { entries: typeof entries; total_entries: number };
    expect(result.total_entries).toBe(4);
    expect(result.entries.map((entry) => entry.id)).toEqual(["5", "6"]);
  });

  it("filters array input with plain view", () => {
    const result = tailRunLogs(rawLogEntries, 10, "plain") as typeof rawLogEntries;
    expect(result.some((entry) => entry.stream === "message_update")).toBe(false);
    expect(result.map((entry) => entry.stream)).toEqual(["stdout", "stdout", "stderr"]);
  });

  it("keeps message_update in array input with compact view", () => {
    const result = tailRunLogs(rawLogEntries, 10, "compact") as typeof rawLogEntries;
    expect(result.some((entry) => entry.stream === "message_update")).toBe(true);
  });

  it("filters by sub_type field in plain view", () => {
    const entriesWithSubtype = [
      { type: "event", sub_type: "message_update", id: "1" },
      { type: "event", sub_type: "tool_call", id: "2" },
    ];
    const result = tailRunLogs({ entries: entriesWithSubtype }, 10, "plain") as { entries: typeof entriesWithSubtype };
    expect(result.entries.map((e) => e.id)).toEqual(["2"]);
  });

  it("applies limit after filtering on array input", () => {
    const result = tailRunLogs(rawLogEntries, 2, "plain") as typeof rawLogEntries;
    // 3 non-noise entries, last 2 are returned
    expect(result.length).toBe(2);
    expect(result.map((entry) => entry.stream)).toEqual(["stdout", "stderr"]);
  });

  it("returns raw logs unchanged for 'raw' view", () => {
    const result = tailRunLogs(rawLogEntries, 10, "raw") as typeof rawLogEntries;
    expect(result).toEqual(rawLogEntries);
  });
});
