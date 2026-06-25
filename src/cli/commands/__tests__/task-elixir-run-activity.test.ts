import { describe, expect, it, vi } from "vitest";
import { runActivityFromElixirRun } from "../task.js";

describe("task Elixir run activity mapping", () => {
  it("maps Elixir run projection fields without legacy store data", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-01-01T00:20:00.000Z"));

    const activity = runActivityFromElixirRun({
      run_id: "run-1",
      status: "running",
      current_phase: "qa",
      last_activity: "2026-01-01T00:00:00.000Z",
      tool_calls: 3,
      cost_usd: 0.25,
      turns: 7,
      started_at: "2025-12-31T23:55:00.000Z",
    });

    expect(activity).toMatchObject({
      runId: "run-1",
      status: "running",
      currentPhase: "qa",
      lastActivity: "2026-01-01T00:00:00.000Z",
      isStuck: true,
      isStale: true,
      toolCalls: 3,
      costUsd: 0.25,
      turns: 7,
      startedAt: "2025-12-31T23:55:00.000Z",
      completedAt: null,
    });

    vi.useRealTimers();
  });
});
