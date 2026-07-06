import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { renderActiveAgents, renderStatusCounts, sleepOrDetach } from "../commands/status.js";

describe("status render helpers", () => {
  let originalHome: string | undefined;
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-status-render-"));
    tempDirs.push(dir);
    return dir;
  }

  beforeEach(() => {
    originalHome = process.env.HOME;
    vi.spyOn(console, "log").mockImplementation(() => undefined);
  });

  afterEach(() => {
    if (originalHome === undefined) delete process.env.HOME;
    else process.env.HOME = originalHome;
    for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
    vi.restoreAllMocks();
  });

  it("renders failed/stuck counts and null-success-rate guidance", () => {
    const store = {
      getRecentOutcomeCounts: () => ({ failed: 2, stuck: 1 }),
      getSuccessRate: () => ({ rate: null }),
    } as any;

    renderStatusCounts(store, "proj-1");

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Failed:");
    expect(rendered).toContain("Stuck:");
    expect(rendered).toContain("need 3+ runs");
  });

  it("renders active agents with last tool activity, retry info, and cost summary", async () => {
    const home = makeTempDir();
    process.env.HOME = home;
    const logsDir = join(home, ".foreman", "logs");
    mkdirSync(logsDir, { recursive: true });
    writeFileSync(join(logsDir, "run-1.out"), JSON.stringify({ type: "tool_call", name: "bash", input: { command: "npm test" } }) + "\n");

    const run = {
      id: "run-1",
      task_id: "task-1",
      status: "running",
      project_id: "proj-1",
      agent_type: "developer",
      session_key: null,
      worktree_path: null,
      started_at: new Date().toISOString(),
      completed_at: null,
      created_at: new Date().toISOString(),
      progress: null,
    };
    const previousRun = {
      id: "run-0",
      task_id: "task-1",
      status: "failed",
      project_id: "proj-1",
      agent_type: "developer",
      session_key: null,
      worktree_path: null,
      started_at: new Date().toISOString(),
      completed_at: null,
      created_at: new Date().toISOString(),
      progress: null,
    };
    const store = {
      getActiveRuns: () => [run],
      getRunProgress: () => ({ currentPhase: "developer", toolCalls: 3, toolBreakdown: { Bash: 3 }, filesChanged: [], costUsd: 1.25, turns: 2, tokensIn: 10, tokensOut: 20, lastToolCall: "Bash", lastActivity: new Date().toISOString() }),
      getRunsForTask: () => [run, previousRun],
      getMetrics: () => ({ totalCost: 4.5, totalTokens: 1500 }),
    } as any;

    await renderActiveAgents(store, "proj-1");

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("task-1");
    expect(rendered).toContain("Last tool");
    expect(rendered).toContain("bash(npm test)");
    expect(rendered).toContain("Costs");
    expect(rendered).toContain("$4.50");
    expect(rendered).toContain("1.5k");
  });

  it("renders the no-active-agents empty state", async () => {
    const store = {
      getActiveRuns: () => [],
    } as any;

    await renderActiveAgents(store, "proj-1");

    expect(vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("(no agents running)");
  });

  it("sleepOrDetach resolves when detach fires before the timer", async () => {
    let release!: () => void;
    const detach = {
      wait: () => new Promise<void>((resolve) => {
        release = resolve;
      }),
    };

    const promise = sleepOrDetach(10_000, detach);
    release();
    await expect(promise).resolves.toBeUndefined();
  });
});
