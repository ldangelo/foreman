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
});
