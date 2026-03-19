import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { Dispatcher } from "../dispatcher.js";
import { STUCK_RETRY_CONFIG, calculateStuckBackoffMs } from "../../lib/config.js";
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
    tmux_session: null,
    ...overrides,
  };
}

function makeStuckRun(minsAgo: number, id: string = "run-1"): Run {
  const ts = new Date(Date.now() - minsAgo * 60 * 1000).toISOString();
  return makeRun({ id, status: "stuck", created_at: ts, completed_at: ts });
}

function makeStore(runsForSeed: Run[] = []): ForemanStore {
  return {
    getActiveRuns: vi.fn().mockReturnValue([]),
    getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    getRunsForSeed: vi.fn().mockReturnValue(runsForSeed),
    createRun: vi.fn().mockReturnValue({ id: "new-run" }),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
  } as unknown as ForemanStore;
}

function makeSeeds(issues: Issue[]): ITaskClient {
  return {
    ready: vi.fn().mockResolvedValue(issues),
    show: vi.fn().mockResolvedValue({}),
    update: vi.fn().mockResolvedValue(undefined),
    close: vi.fn().mockResolvedValue(undefined),
    list: vi.fn().mockResolvedValue([]),
  };
}

// ── calculateStuckBackoffMs unit tests ────────────────────────────────────

describe("calculateStuckBackoffMs", () => {
  it("returns 0 for stuckCount <= 0", () => {
    expect(calculateStuckBackoffMs(0)).toBe(0);
    expect(calculateStuckBackoffMs(-1)).toBe(0);
  });

  it("returns initialDelayMs for stuckCount=1", () => {
    expect(calculateStuckBackoffMs(1)).toBe(STUCK_RETRY_CONFIG.initialDelayMs);
  });

  it("doubles the delay for each additional stuck run", () => {
    const initial = STUCK_RETRY_CONFIG.initialDelayMs;
    const mult = STUCK_RETRY_CONFIG.backoffMultiplier;
    expect(calculateStuckBackoffMs(2)).toBe(initial * mult);
    expect(calculateStuckBackoffMs(3)).toBe(initial * mult * mult);
  });

  it("caps at maxDelayMs", () => {
    // A very high count should return maxDelayMs
    expect(calculateStuckBackoffMs(1000)).toBe(STUCK_RETRY_CONFIG.maxDelayMs);
  });
});

// ── Dispatcher stuck-backoff integration tests ────────────────────────────

describe("Dispatcher.dispatch — stuck backoff", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("dispatches a seed with no prior stuck runs normally", async () => {
    const seed = makeIssue("bd-001");
    const store = makeStore([]); // no stuck runs
    const seeds = makeSeeds([seed]);
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.dispatched.map((d) => d.seedId)).toContain("bd-001");
    expect(result.skipped).toHaveLength(0);
  });

  it("skips a seed in backoff after 1 recent stuck run", async () => {
    const seed = makeIssue("bd-001");
    // Stuck 30 seconds ago → required backoff = initialDelayMs (60s default) → still in backoff
    // (30s elapsed < 60s required → in backoff)
    const stuckRun = makeRun({
      id: "run-1",
      status: "stuck",
      created_at: new Date(Date.now() - 30_000).toISOString(),
      completed_at: new Date(Date.now() - 30_000).toISOString(),
    });
    const store = makeStore([stuckRun]);
    const seeds = makeSeeds([seed]);
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.dispatched).toHaveLength(0);
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0].seedId).toBe("bd-001");
    expect(result.skipped[0].reason).toMatch(/backoff/i);
  });

  it("dispatches a seed once backoff period has elapsed after 1 stuck run", async () => {
    const seed = makeIssue("bd-001");
    // Stuck 2 hours ago → required backoff = 60s → elapsed (7200s) > 60s → should dispatch
    const stuckRun = makeStuckRun(120 /* minutes ago */);
    const store = makeStore([stuckRun]);
    const seeds = makeSeeds([seed]);
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.dispatched.map((d) => d.seedId)).toContain("bd-001");
    expect(result.skipped).toHaveLength(0);
  });

  it("applies longer backoff after 2 recent stuck runs", async () => {
    const seed = makeIssue("bd-001");
    // 2 stuck runs, most recent 90 seconds ago
    // Required backoff = initialDelayMs * 2^1 = 120s (default)
    // Elapsed = 90s → still in backoff
    const now = Date.now();
    const run1 = makeRun({
      id: "run-1",
      status: "stuck",
      created_at: new Date(now - 5 * 60 * 1000).toISOString(),
      completed_at: new Date(now - 5 * 60 * 1000).toISOString(),
    });
    const run2 = makeRun({
      id: "run-2",
      status: "stuck",
      created_at: new Date(now - 90 * 1000).toISOString(),
      completed_at: new Date(now - 90 * 1000).toISOString(),
    });
    // getRunsForSeed returns DESC (most recent first)
    const store = makeStore([run2, run1]);
    const seeds = makeSeeds([seed]);
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.dispatched).toHaveLength(0);
    expect(result.skipped[0].reason).toMatch(/backoff/i);
  });

  it("blocks a seed at max retries regardless of elapsed time", async () => {
    const seed = makeIssue("bd-001");
    // maxRetries stuck runs (default: 3), all very old so backoff would have elapsed
    const stuckRuns = [
      makeStuckRun(300, "run-3"), // most recent
      makeStuckRun(400, "run-2"),
      makeStuckRun(500, "run-1"),
    ];
    const store = makeStore(stuckRuns);
    const seeds = makeSeeds([seed]);
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.dispatched).toHaveLength(0);
    expect(result.skipped[0].reason).toMatch(/max stuck retries/i);
  });

  it("does not count stuck runs outside the time window", async () => {
    const seed = makeIssue("bd-001");
    // Stuck 25 hours ago — outside the 24h window → should not count
    const windowHours = STUCK_RETRY_CONFIG.windowMs / (60 * 60 * 1000);
    const oldRun = makeStuckRun((windowHours + 1) * 60 /* minutes */);
    const store = makeStore([oldRun]);
    const seeds = makeSeeds([seed]);
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.dispatched.map((d) => d.seedId)).toContain("bd-001");
    expect(result.skipped).toHaveLength(0);
  });

  it("includes retry count and remaining time in skip reason", async () => {
    const seed = makeIssue("bd-001");
    // 1 stuck run 30 seconds ago, backoff = 60s, 30s remaining
    const stuckRun = makeRun({
      id: "run-1",
      status: "stuck",
      created_at: new Date(Date.now() - 30_000).toISOString(),
      completed_at: new Date(Date.now() - 30_000).toISOString(),
    });
    const store = makeStore([stuckRun]);
    const seeds = makeSeeds([seed]);
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.skipped[0].reason).toMatch(/\d+s/); // includes seconds remaining
    expect(result.skipped[0].reason).toMatch(/1\//);   // includes attempt count
  });

  it("only applies backoff to seeds with stuck runs — other seeds dispatch normally", async () => {
    const stuckSeed = makeIssue("bd-001");
    const cleanSeed = makeIssue("bd-002");

    // bd-001 has a recent stuck run (30s ago, well within 60s backoff); bd-002 has none
    const stuckRun = makeRun({
      id: "run-1",
      status: "stuck",
      created_at: new Date(Date.now() - 30_000).toISOString(),
      completed_at: new Date(Date.now() - 30_000).toISOString(),
    });
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockImplementation((seedId: string) => {
        return seedId === "bd-001" ? [stuckRun] : [];
      }),
    } as unknown as ForemanStore;

    const seeds = makeSeeds([stuckSeed, cleanSeed]);
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.dispatched.map((d) => d.seedId)).toContain("bd-002");
    expect(result.dispatched.map((d) => d.seedId)).not.toContain("bd-001");
    expect(result.skipped.map((s) => s.seedId)).toContain("bd-001");
  });
});
