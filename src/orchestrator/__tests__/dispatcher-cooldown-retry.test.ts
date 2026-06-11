/**
 * Tests for dispatcher cooldown retry behavior (checkCooldownState).
 *
 * When a phase fails with a retryable error (e.g. rate limit) and retryAfterCooldown
 * is enabled, the task is placed in "cooldown" status with a cooldown_until timestamp.
 * The dispatcher should skip tasks that are in cooldown state until the cooldown
 * period expires.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { Dispatcher } from "../dispatcher.js";
import { COOLDOWN_RETRY_CONFIG } from "../../lib/config.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import type { ForemanStore, Run } from "../../lib/store.js";

// ── Helpers ────────────────────────────────────────────────────────────────

function makeIssue(id: string, overrides?: Partial<Issue>): Issue {
  return {
    id,
    title: `Task ${id}`,
    status: "open",
    priority: "P2",
    type: "task",
    assignee: null,
    parent: null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    ...overrides,
  };
}

let currentReadyIssues: Issue[] = [];

function nativeTaskFromIssue(issue: Issue, status: string = "ready") {
  return {
    id: issue.id,
    title: issue.title,
    description: issue.description ?? null,
    type: issue.type,
    priority: Number(String(issue.priority ?? "2").replace(/^P/, "")) || 2,
    status,
    run_id: null,
    branch: null,
    external_id: null,
    labels: issue.labels ?? [],
    parent: issue.parent ?? null,
    created_at: issue.created_at,
    updated_at: issue.updated_at,
    approved_at: new Date().toISOString(),
    closed_at: null,
  };
}

function makeRun(overrides?: Partial<Run>): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "seed-1",
    agent_type: "claude-sonnet-4-6",
    session_key: null,
    worktree_path: "/tmp/worktree",
    status: "stuck",
    started_at: null,
    completed_at: new Date().toISOString(),
    created_at: new Date().toISOString(),
    progress: null,
    ...overrides,
  };
}

function makeCooldownRun(cooldownUntil: string, seedId: string = "seed-1"): Run {
  return makeRun({
    id: "run-cooldown",
    status: "cooldown",
    seed_id: seedId,
    cooldown_until: cooldownUntil,
  });
}

function makeStore(runsForSeed: Run[] = [], taskStatus: string = "ready"): ForemanStore {
  return {
    getActiveRuns: vi.fn().mockReturnValue([]),
    getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    getRunsForSeed: vi.fn((seedId: string) => runsForSeed.filter((run) => run.seed_id === seedId)),
    getRunsByStatus: vi.fn().mockReturnValue([]),
    createRun: vi.fn().mockReturnValue({ id: "new-run" }),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    hasNativeTasks: vi.fn().mockReturnValue(true),
    getReadyTasks: vi.fn(() => currentReadyIssues.map((issue) => nativeTaskFromIssue(issue, taskStatus))),
    getTaskByExternalId: vi.fn().mockReturnValue(null),
    getTaskById: vi.fn((id: string) => currentReadyIssues.map((issue) => nativeTaskFromIssue(issue, taskStatus)).find((task) => task.id === id) ?? null),
    claimTask: vi.fn().mockReturnValue(true),
    updateTaskStatus: vi.fn(),
  } as unknown as ForemanStore;
}

function makeSeeds(issues: Issue[]): ITaskClient {
  currentReadyIssues = issues;
  return {
    ready: vi.fn().mockResolvedValue(issues),
    show: vi.fn().mockResolvedValue({}),
    update: vi.fn().mockResolvedValue(undefined),
    close: vi.fn().mockResolvedValue(undefined),
    list: vi.fn().mockResolvedValue([]),
  };
}

// ── COOLDOWN_RETRY_CONFIG unit tests ───────────────────────────────────────

describe("COOLDOWN_RETRY_CONFIG", () => {
  it("has a sensible default cooldown duration", () => {
    expect(COOLDOWN_RETRY_CONFIG.defaultCooldownSeconds).toBe(300); // 5 minutes
  });

  it("default cooldown is at least 60 seconds", () => {
    expect(COOLDOWN_RETRY_CONFIG.defaultCooldownSeconds).toBeGreaterThanOrEqual(60);
  });
});

// ── Dispatcher dispatch — cooldown state tests ─────────────────────────────

describe("Dispatcher.dispatch — cooldown state", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("dispatches a seed normally when not in cooldown state", async () => {
    const seed = makeIssue("bd-001");
    const store = makeStore([]); // no cooldown runs
    const seeds = makeSeeds([seed]);
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.dispatched.map((d) => d.seedId)).toContain("bd-001");
    expect(result.skipped).toHaveLength(0);
  });

  it("skips a seed that is in cooldown state (cooldown not expired)", async () => {
    const seed = makeIssue("bd-001");
    // Cooldown expires in 5 minutes
    const futureCooldownUntil = new Date(Date.now() + 5 * 60 * 1000).toISOString();
    const cooldownRun = makeCooldownRun(futureCooldownUntil, "bd-001");
    const store = makeStore([cooldownRun], "cooldown");
    const seeds = makeSeeds([seed]);
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.dispatched.map((d) => d.seedId)).not.toContain("bd-001");
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0].reason).toContain("cooldown");
  });

  it("dispatches a seed when cooldown has expired", async () => {
    const seed = makeIssue("bd-001");
    // Cooldown expired 1 minute ago
    const pastCooldownUntil = new Date(Date.now() - 60 * 1000).toISOString();
    const cooldownRun = makeCooldownRun(pastCooldownUntil, "bd-001");
    const store = makeStore([cooldownRun], "cooldown");
    const seeds = makeSeeds([seed]);
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.dispatched.map((d) => d.seedId)).toContain("bd-001");
    expect(result.skipped).toHaveLength(0);
  });

  it("clears cooldown state when cooldown has expired", async () => {
    const seed = makeIssue("bd-001");
    // Cooldown expired 1 minute ago
    const pastCooldownUntil = new Date(Date.now() - 60 * 1000).toISOString();
    const cooldownRun = makeCooldownRun(pastCooldownUntil, "bd-001");
    const updateTaskStatus = vi.fn();
    const store = makeStore([cooldownRun], "cooldown");
    // Override to capture the updateTaskStatus call
    store.updateTaskStatus = updateTaskStatus;
    const seeds = makeSeeds([seed]);
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    // The dispatcher should have called updateTaskStatus to reset the task to ready
    expect(updateTaskStatus).toHaveBeenCalledWith("bd-001", "ready");
  });

  it("does not clear cooldown state when cooldown is still active", async () => {
    const seed = makeIssue("bd-001");
    // Cooldown expires in 5 minutes
    const futureCooldownUntil = new Date(Date.now() + 5 * 60 * 1000).toISOString();
    const cooldownRun = makeCooldownRun(futureCooldownUntil, "bd-001");
    const updateTaskStatus = vi.fn();
    const store = makeStore([cooldownRun], "cooldown");
    store.updateTaskStatus = updateTaskStatus;
    const seeds = makeSeeds([seed]);
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    // The dispatcher should NOT have called updateTaskStatus to reset the task
    expect(updateTaskStatus).not.toHaveBeenCalled();
  });

  it("reports remaining cooldown time in skip reason", async () => {
    const seed = makeIssue("bd-001");
    // Cooldown expires in 120 seconds
    const futureCooldownUntil = new Date(Date.now() + 120 * 1000).toISOString();
    const cooldownRun = makeCooldownRun(futureCooldownUntil, "bd-001");
    const store = makeStore([cooldownRun], "cooldown");
    const seeds = makeSeeds([seed]);
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.skipped[0].reason).toMatch(/retry in \d+s/);
    expect(result.skipped[0].reason).toContain("cooldown");
  });

  it("handles task without cooldown_until (clears cooldown state)", async () => {
    const seed = makeIssue("bd-001");
    // Run without cooldown_until but task is in cooldown state
    const runWithoutCooldown = makeRun({
      id: "run-no-cooldown",
      status: "stuck",
      seed_id: "bd-001",
      cooldown_until: undefined,
    });
    const updateTaskStatus = vi.fn();
    const store = makeStore([runWithoutCooldown], "cooldown");
    store.updateTaskStatus = updateTaskStatus;
    const seeds = makeSeeds([seed]);
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    // The dispatcher should clear the cooldown state since there's no cooldown_until
    expect(updateTaskStatus).toHaveBeenCalledWith("bd-001", "ready");
  });

  it("dispatches when task status is not cooldown (ready state)", async () => {
    const seed = makeIssue("bd-001");
    // Task is in ready state, not cooldown
    const cooldownRun = makeCooldownRun(
      new Date(Date.now() + 5 * 60 * 1000).toISOString(),
      "bd-001"
    );
    const store = makeStore([cooldownRun], "ready"); // task is ready, not cooldown
    const seeds = makeSeeds([seed]);
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    // Task should be dispatched because it's in ready state, not cooldown
    expect(result.dispatched.map((d) => d.seedId)).toContain("bd-001");
  });
});