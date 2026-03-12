import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Run, RunProgress } from "../../lib/store.js";
import {
  elapsed,
  shortModel,
  shortPath,
  renderAgentCard,
  renderWatchDisplay,
  poll,
  type WatchState,
} from "../watch-ui.js";

// ── Fixtures ──────────────────────────────────────────────────────────────

function makeRun(overrides?: Partial<Run>): Run {
  return {
    id: "run-001",
    project_id: "proj-1",
    seed_id: "foreman-1a",
    agent_type: "claude-sonnet-4-6",
    session_key: null,
    worktree_path: null,
    status: "running",
    started_at: new Date(Date.now() - 90_000).toISOString(), // 90s ago
    completed_at: null,
    created_at: new Date(Date.now() - 100_000).toISOString(),
    progress: null,
    ...overrides,
  };
}

function makeProgress(overrides?: Partial<RunProgress>): RunProgress {
  return {
    toolCalls: 10,
    toolBreakdown: { Bash: 5, Read: 3, Edit: 2 },
    filesChanged: ["src/foo.ts", "src/bar.ts"],
    turns: 4,
    costUsd: 0.0123,
    tokensIn: 1000,
    tokensOut: 500,
    lastToolCall: "Bash",
    lastActivity: new Date().toISOString(),
    ...overrides,
  };
}

function makeMockStore(
  runs: Record<string, Run>,
  progresses: Record<string, RunProgress | null> = {},
) {
  return {
    getRun: vi.fn((id: string) => runs[id] ?? null),
    getRunProgress: vi.fn((id: string) => progresses[id] ?? null),
  };
}

// ── elapsed() ─────────────────────────────────────────────────────────────

describe("elapsed", () => {
  it("returns '—' for null input", () => {
    expect(elapsed(null)).toBe("—");
  });

  it("returns seconds for durations under 1 minute", () => {
    const since = new Date(Date.now() - 45_000).toISOString();
    expect(elapsed(since)).toBe("45s");
  });

  it("returns minutes and seconds for durations under 1 hour", () => {
    const since = new Date(Date.now() - 90_000).toISOString();
    expect(elapsed(since)).toBe("1m 30s");
  });

  it("returns hours and minutes for durations over 1 hour", () => {
    const since = new Date(Date.now() - 3_900_000).toISOString(); // 65 minutes
    expect(elapsed(since)).toBe("1h 5m");
  });
});

// ── shortModel() ──────────────────────────────────────────────────────────

describe("shortModel", () => {
  it("strips 'claude-' prefix", () => {
    expect(shortModel("claude-sonnet-4-6")).toBe("sonnet-4-6");
  });

  it("strips '-20251001' suffix", () => {
    expect(shortModel("claude-haiku-4-5-20251001")).toBe("haiku-4-5");
  });

  it("handles model without 'claude-' prefix", () => {
    expect(shortModel("gpt-4")).toBe("gpt-4");
  });
});

// ── shortPath() ────────────────────────────────────────────────────────────

describe("shortPath", () => {
  it("returns the filename from an absolute path", () => {
    expect(shortPath("/home/user/src/foo.ts")).toBe("foo.ts");
  });

  it("returns the filename from a relative path", () => {
    expect(shortPath("src/cli/watch-ui.ts")).toBe("watch-ui.ts");
  });

  it("returns the original string if no slash is present", () => {
    expect(shortPath("watch-ui.ts")).toBe("watch-ui.ts");
  });
});

// ── renderAgentCard() ─────────────────────────────────────────────────────

describe("renderAgentCard", () => {
  it("includes seed_id in output", () => {
    const run = makeRun({ seed_id: "foreman-42a" });
    const output = renderAgentCard(run, null);
    expect(output).toContain("foreman-42a");
  });

  it("shows RUNNING status for running run", () => {
    const run = makeRun({ status: "running" });
    const output = renderAgentCard(run, null);
    expect(output).toContain("RUNNING");
  });

  it("shows COMPLETED status for completed run", () => {
    const run = makeRun({ status: "completed" });
    const output = renderAgentCard(run, null);
    expect(output).toContain("COMPLETED");
  });

  it("shows model info", () => {
    const run = makeRun({ agent_type: "claude-sonnet-4-6" });
    const output = renderAgentCard(run, null);
    expect(output).toContain("sonnet-4-6");
  });

  it("shows 'Initializing...' for running run with no progress", () => {
    const run = makeRun({ status: "running" });
    const output = renderAgentCard(run, null);
    expect(output).toContain("Initializing");
  });

  it("does NOT show 'Initializing...' for pending run", () => {
    const run = makeRun({ status: "pending" });
    const output = renderAgentCard(run, null);
    expect(output).not.toContain("Initializing");
  });

  it("shows cost when progress is provided", () => {
    const run = makeRun({ status: "completed" });
    const progress = makeProgress({ costUsd: 0.0456 });
    const output = renderAgentCard(run, progress);
    expect(output).toContain("$0.0456");
  });

  it("shows turns when progress is provided", () => {
    const run = makeRun({ status: "running" });
    const progress = makeProgress({ turns: 7 });
    const output = renderAgentCard(run, progress);
    expect(output).toContain("7");
  });

  it("shows tool call count when progress is provided", () => {
    const run = makeRun({ status: "running" });
    const progress = makeProgress({ toolCalls: 15 });
    const output = renderAgentCard(run, progress);
    expect(output).toContain("15");
  });

  it("shows last tool call when progress is provided", () => {
    const run = makeRun({ status: "running" });
    const progress = makeProgress({ lastToolCall: "Edit" });
    const output = renderAgentCard(run, progress);
    expect(output).toContain("last: Edit");
  });

  it("shows files changed count", () => {
    const run = makeRun({ status: "completed" });
    const progress = makeProgress({ filesChanged: ["a.ts", "b.ts", "c.ts"] });
    const output = renderAgentCard(run, progress);
    expect(output).toContain("3");
  });

  it("shows individual filenames (up to 5)", () => {
    const run = makeRun({ status: "completed" });
    const progress = makeProgress({ filesChanged: ["foo.ts", "bar.ts"] });
    const output = renderAgentCard(run, progress);
    expect(output).toContain("foo.ts");
    expect(output).toContain("bar.ts");
  });

  it("shows '+N more' when files exceed 5", () => {
    const run = makeRun({ status: "completed" });
    const progress = makeProgress({
      filesChanged: ["a.ts", "b.ts", "c.ts", "d.ts", "e.ts", "f.ts", "g.ts"],
    });
    const output = renderAgentCard(run, progress);
    expect(output).toContain("+2 more");
  });

  it("shows log hint for failed run", () => {
    const run = makeRun({ id: "run-xyz", status: "failed" });
    const progress = makeProgress({ toolCalls: 5 });
    const output = renderAgentCard(run, progress);
    expect(output).toContain("~/.foreman/logs/run-xyz.log");
  });

  it("shows no log hint for completed run", () => {
    const run = makeRun({ id: "run-xyz", status: "completed" });
    const progress = makeProgress();
    const output = renderAgentCard(run, progress);
    expect(output).not.toContain(".log");
  });

  it("renders tool breakdown entries", () => {
    const run = makeRun({ status: "running" });
    const progress = makeProgress({
      toolBreakdown: { Bash: 10, Read: 5, Edit: 3 },
      toolCalls: 18,
    });
    const output = renderAgentCard(run, progress);
    expect(output).toContain("Bash");
    expect(output).toContain("Read");
    expect(output).toContain("Edit");
  });
});

// ── poll() ────────────────────────────────────────────────────────────────

describe("poll", () => {
  it("returns empty runs array when no IDs match", () => {
    const store = makeMockStore({});
    const state = poll(store as any, ["nonexistent"]);
    expect(state.runs).toHaveLength(0);
    expect(state.allDone).toBe(true);
  });

  it("aggregates cost, tools, and files from progress", () => {
    const run1 = makeRun({ id: "r1", status: "completed" });
    const run2 = makeRun({ id: "r2", status: "completed" });
    const prog1 = makeProgress({ costUsd: 0.01, toolCalls: 10, filesChanged: ["a.ts"] });
    const prog2 = makeProgress({ costUsd: 0.02, toolCalls: 5, filesChanged: ["b.ts", "c.ts"] });

    const store = makeMockStore({ r1: run1, r2: run2 }, { r1: prog1, r2: prog2 });
    const state = poll(store as any, ["r1", "r2"]);

    expect(state.totalCost).toBeCloseTo(0.03, 5);
    expect(state.totalTools).toBe(15);
    expect(state.totalFiles).toBe(3);
  });

  it("sets allDone=false when any run is pending", () => {
    const run = makeRun({ id: "r1", status: "pending" });
    const store = makeMockStore({ r1: run });
    const state = poll(store as any, ["r1"]);
    expect(state.allDone).toBe(false);
  });

  it("sets allDone=false when any run is running", () => {
    const run = makeRun({ id: "r1", status: "running" });
    const store = makeMockStore({ r1: run });
    const state = poll(store as any, ["r1"]);
    expect(state.allDone).toBe(false);
  });

  it("sets allDone=true when all runs are completed", () => {
    const run1 = makeRun({ id: "r1", status: "completed" });
    const run2 = makeRun({ id: "r2", status: "failed" });
    const store = makeMockStore({ r1: run1, r2: run2 });
    const state = poll(store as any, ["r1", "r2"]);
    expect(state.allDone).toBe(true);
  });

  it("counts completedCount correctly", () => {
    const run1 = makeRun({ id: "r1", status: "completed" });
    const run2 = makeRun({ id: "r2", status: "completed" });
    const run3 = makeRun({ id: "r3", status: "failed" });
    const store = makeMockStore({ r1: run1, r2: run2, r3: run3 });
    const state = poll(store as any, ["r1", "r2", "r3"]);
    expect(state.completedCount).toBe(2);
    expect(state.failedCount).toBe(1);
    expect(state.stuckCount).toBe(0);
  });

  it("counts failedCount including test-failed", () => {
    const run1 = makeRun({ id: "r1", status: "failed" });
    const run2 = makeRun({ id: "r2", status: "test-failed" });
    const store = makeMockStore({ r1: run1, r2: run2 });
    const state = poll(store as any, ["r1", "r2"]);
    expect(state.failedCount).toBe(2);
  });

  it("counts stuckCount correctly", () => {
    const run1 = makeRun({ id: "r1", status: "stuck" });
    const run2 = makeRun({ id: "r2", status: "completed" });
    const store = makeMockStore({ r1: run1, r2: run2 });
    const state = poll(store as any, ["r1", "r2"]);
    expect(state.stuckCount).toBe(1);
  });

  it("skips runs that are not found in store", () => {
    const run1 = makeRun({ id: "r1", status: "completed" });
    const store = makeMockStore({ r1: run1 });
    const state = poll(store as any, ["r1", "missing-id"]);
    expect(state.runs).toHaveLength(1);
    expect(state.runs[0].run.id).toBe("r1");
  });

  it("handles runs with no progress (null)", () => {
    const run = makeRun({ id: "r1", status: "running" });
    const store = makeMockStore({ r1: run }, { r1: null });
    const state = poll(store as any, ["r1"]);
    expect(state.runs[0].progress).toBeNull();
    expect(state.totalCost).toBe(0);
    expect(state.totalTools).toBe(0);
    expect(state.totalFiles).toBe(0);
  });
});

// ── renderWatchDisplay() ──────────────────────────────────────────────────

describe("renderWatchDisplay", () => {
  function makeState(overrides?: Partial<WatchState>): WatchState {
    const run = makeRun({ id: "r1", status: "running" });
    return {
      runs: [{ run, progress: null }],
      allDone: false,
      totalCost: 0,
      totalTools: 0,
      totalFiles: 0,
      completedCount: 0,
      failedCount: 0,
      stuckCount: 0,
      ...overrides,
    };
  }

  it("shows 'No runs found.' when runs is empty", () => {
    const state = makeState({ runs: [] });
    const output = renderWatchDisplay(state);
    expect(output).toContain("No runs found.");
  });

  it("shows 'Foreman' header", () => {
    const state = makeState();
    const output = renderWatchDisplay(state);
    expect(output).toContain("Foreman");
  });

  it("shows Ctrl+C hint when not done and showDetachHint=true", () => {
    const state = makeState({ allDone: false });
    const output = renderWatchDisplay(state, true);
    expect(output).toContain("Ctrl+C to detach");
  });

  it("hides Ctrl+C hint when showDetachHint=false", () => {
    const state = makeState({ allDone: false });
    const output = renderWatchDisplay(state, false);
    expect(output).not.toContain("Ctrl+C to detach");
  });

  it("hides Ctrl+C hint when allDone=true", () => {
    const run = makeRun({ id: "r1", status: "completed" });
    const state = makeState({
      runs: [{ run, progress: null }],
      allDone: true,
      completedCount: 1,
    });
    const output = renderWatchDisplay(state, true);
    expect(output).not.toContain("Ctrl+C to detach");
  });

  it("shows summary bar with agent count", () => {
    const state = makeState();
    const output = renderWatchDisplay(state);
    expect(output).toContain("1 agents");
  });

  it("shows summary bar with tool count", () => {
    const state = makeState({ totalTools: 42 });
    const output = renderWatchDisplay(state);
    expect(output).toContain("42 tool calls");
  });

  it("shows summary bar with total cost", () => {
    const state = makeState({ totalCost: 0.1234 });
    const output = renderWatchDisplay(state);
    expect(output).toContain("$0.1234");
  });

  it("shows completion banner when allDone=true", () => {
    const run = makeRun({ id: "r1", status: "completed" });
    const state = makeState({
      runs: [{ run, progress: null }],
      allDone: true,
      completedCount: 1,
    });
    const output = renderWatchDisplay(state);
    expect(output).toContain("Done:");
    expect(output).toContain("1 completed");
  });

  it("shows failed count in completion banner", () => {
    const run = makeRun({ id: "r1", status: "failed" });
    const state = makeState({
      runs: [{ run, progress: null }],
      allDone: true,
      failedCount: 1,
    });
    const output = renderWatchDisplay(state);
    expect(output).toContain("1 failed");
  });

  it("shows stuck hint when stuckCount > 0", () => {
    const run = makeRun({ id: "r1", status: "stuck" });
    const state = makeState({
      runs: [{ run, progress: null }],
      allDone: true,
      stuckCount: 1,
    });
    const output = renderWatchDisplay(state);
    expect(output).toContain("rate-limited");
    expect(output).toContain("foreman run --resume");
  });

  it("does NOT show completion banner when not done", () => {
    const state = makeState({ allDone: false });
    const output = renderWatchDisplay(state);
    expect(output).not.toContain("Done:");
  });

  it("renders multiple agent cards", () => {
    const run1 = makeRun({ id: "r1", seed_id: "foreman-1a", status: "completed" });
    const run2 = makeRun({ id: "r2", seed_id: "foreman-2b", status: "running" });
    const state = makeState({
      runs: [
        { run: run1, progress: null },
        { run: run2, progress: null },
      ],
      allDone: false,
    });
    const output = renderWatchDisplay(state);
    expect(output).toContain("foreman-1a");
    expect(output).toContain("foreman-2b");
  });

  // ── Non-interactive mode (status command usage) ──────────────────────────

  it("does not show Ctrl+C hint in non-interactive mode (showDetachHint=false)", () => {
    const state = makeState({ allDone: false });
    const output = renderWatchDisplay(state, false);
    expect(output).not.toContain("Ctrl+C");
    expect(output).not.toContain("detach");
  });

  it("shows status icons for running agent in non-interactive mode", () => {
    const run = makeRun({ status: "running", seed_id: "foreman-aa" });
    const state = makeState({ runs: [{ run, progress: null }], allDone: false });
    const output = renderWatchDisplay(state, false);
    // running status uses ● icon
    expect(output).toContain("●");
    expect(output).toContain("RUNNING");
  });

  it("shows uppercase status text in non-interactive mode", () => {
    const run = makeRun({ status: "completed", seed_id: "foreman-bb" });
    const state = makeState({
      runs: [{ run, progress: null }],
      allDone: true,
      completedCount: 1,
    });
    const output = renderWatchDisplay(state, false);
    expect(output).toContain("COMPLETED");
  });

  it("shows detailed elapsed time (not just minutes) in non-interactive mode", () => {
    const run = makeRun({
      status: "running",
      started_at: new Date(Date.now() - 90_000).toISOString(), // 1m 30s ago
    });
    const state = makeState({ runs: [{ run, progress: null }], allDone: false });
    const output = renderWatchDisplay(state, false);
    // Should show "1m 30s" style elapsed time (not "1m" only)
    expect(output).toMatch(/\d+m \d+s/);
  });

  it("shows short model name in non-interactive mode", () => {
    const run = makeRun({ agent_type: "claude-sonnet-4-6", status: "running" });
    const state = makeState({ runs: [{ run, progress: null }], allDone: false });
    const output = renderWatchDisplay(state, false);
    // shortModel() strips "claude-" prefix
    expect(output).toContain("sonnet-4-6");
    expect(output).not.toContain("claude-sonnet-4-6");
  });

  it("shows tool breakdown in non-interactive mode when progress is available", () => {
    const run = makeRun({ status: "running" });
    const progress = makeProgress({
      toolBreakdown: { Bash: 10, Read: 5, Edit: 3 },
      toolCalls: 18,
    });
    const state = makeState({ runs: [{ run, progress }], allDone: false });
    const output = renderWatchDisplay(state, false);
    expect(output).toContain("Bash");
    expect(output).toContain("Read");
    expect(output).toContain("Edit");
  });

  it("shows file list in non-interactive mode when progress is available", () => {
    const run = makeRun({ status: "completed" });
    const progress = makeProgress({ filesChanged: ["src/foo.ts", "src/bar.ts"] });
    const state = makeState({
      runs: [{ run, progress }],
      allDone: true,
      completedCount: 1,
    });
    const output = renderWatchDisplay(state, false);
    expect(output).toContain("foo.ts");
    expect(output).toContain("bar.ts");
  });

  it("shows log hint for failed run in non-interactive mode", () => {
    const run = makeRun({ id: "run-fail-01", status: "failed" });
    const progress = makeProgress({ toolCalls: 5 });
    const state = makeState({
      runs: [{ run, progress }],
      allDone: true,
      failedCount: 1,
    });
    const output = renderWatchDisplay(state, false);
    expect(output).toContain("~/.foreman/logs/run-fail-01.log");
  });

  it("shows pending agent with status icon in non-interactive mode", () => {
    const run = makeRun({ status: "pending" });
    const state = makeState({ runs: [{ run, progress: null }], allDone: false });
    const output = renderWatchDisplay(state, false);
    // pending status uses ○ icon
    expect(output).toContain("○");
    expect(output).toContain("PENDING");
  });
});
