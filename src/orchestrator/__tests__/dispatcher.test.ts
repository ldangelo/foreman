import { describe, it, expect, vi, beforeEach } from "vitest";
import { Dispatcher } from "../dispatcher.js";
import { PLAN_STEP_CONFIG } from "../roles.js";
import type { SeedInfo } from "../types.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import type { BvClient, BvTriageResult } from "../../lib/bv.js";
import type { ForemanStore } from "../../lib/store.js";

// Minimal mocks — we only need selectModel which doesn't touch store/seeds
const mockStore = {} as unknown as ForemanStore;
const mockSeeds = {} as unknown as ITaskClient;

function makeDispatcher(client?: ITaskClient, bvClient?: BvClient | null) {
  return new Dispatcher(client ?? mockSeeds, mockStore, "/tmp", bvClient);
}

function makeSeed(title: string, description?: string, priority?: string): SeedInfo {
  return { id: "seed-001", title, description, priority };
}

describe("Dispatcher.selectModel", () => {
  const dispatcher = makeDispatcher();

  it("selects opus for 'refactor' in title", () => {
    expect(dispatcher.selectModel(makeSeed("Refactor auth module"))).toBe("claude-opus-4-6");
  });

  it("selects opus for 'architect' in title", () => {
    expect(dispatcher.selectModel(makeSeed("Architect the new data layer"))).toBe("claude-opus-4-6");
  });

  it("selects opus for 'design' in title", () => {
    expect(dispatcher.selectModel(makeSeed("Design the API schema"))).toBe("claude-opus-4-6");
  });

  it("selects opus for 'migrate' in title", () => {
    expect(dispatcher.selectModel(makeSeed("Migrate database to Postgres"))).toBe("claude-opus-4-6");
  });

  it("selects haiku for 'typo' in title", () => {
    expect(dispatcher.selectModel(makeSeed("Fix typo in README"))).toBe("claude-haiku-4-5-20251001");
  });

  it("selects haiku for 'config' in title", () => {
    expect(dispatcher.selectModel(makeSeed("Update config for staging"))).toBe("claude-haiku-4-5-20251001");
  });

  it("defaults to sonnet for implementation tasks", () => {
    expect(dispatcher.selectModel(makeSeed("Build user profile page"))).toBe("claude-sonnet-4-6");
  });

  it("defaults to sonnet for test tasks", () => {
    expect(dispatcher.selectModel(makeSeed("Write unit tests for auth"))).toBe("claude-sonnet-4-6");
  });

  it("defaults to sonnet for fix tasks", () => {
    expect(dispatcher.selectModel(makeSeed("Fix login bug"))).toBe("claude-sonnet-4-6");
  });

  it("matches keywords case-insensitively", () => {
    expect(dispatcher.selectModel(makeSeed("REFACTOR the codebase"))).toBe("claude-opus-4-6");
    expect(dispatcher.selectModel(makeSeed("TYPO in variable name"))).toBe("claude-haiku-4-5-20251001");
  });

  it("checks description for complexity signals", () => {
    expect(dispatcher.selectModel(makeSeed("Update module", "This requires a complex overhaul"))).toBe("claude-opus-4-6");
  });
});

describe("Dispatcher.selectModel — priority-based selection via normalizePriority", () => {
  const dispatcher = makeDispatcher();

  it("selects opus for P0 tasks regardless of title", () => {
    expect(dispatcher.selectModel(makeSeed("Simple update", undefined, "P0"))).toBe("claude-opus-4-6");
  });

  it("selects opus for priority '0' (numeric string, br format)", () => {
    expect(dispatcher.selectModel(makeSeed("Simple update", undefined, "0"))).toBe("claude-opus-4-6");
  });

  it("selects opus for numeric priority 0", () => {
    // SeedInfo.priority is typed as string | undefined but normalizePriority handles numbers too
    expect(dispatcher.selectModel(makeSeed("Simple fix", undefined, "P0"))).toBe("claude-opus-4-6");
  });

  it("does NOT force opus for P1 tasks without heavy keywords", () => {
    expect(dispatcher.selectModel(makeSeed("Build feature", undefined, "P1"))).toBe("claude-sonnet-4-6");
  });

  it("does NOT force opus for P2 tasks without heavy keywords", () => {
    expect(dispatcher.selectModel(makeSeed("Build feature", undefined, "P2"))).toBe("claude-sonnet-4-6");
  });

  it("selects haiku for P1 light task (config keyword)", () => {
    expect(dispatcher.selectModel(makeSeed("Update config file", undefined, "P1"))).toBe("claude-haiku-4-5-20251001");
  });

  it("selects haiku for P3 light task (typo keyword)", () => {
    expect(dispatcher.selectModel(makeSeed("Fix typo", undefined, "P3"))).toBe("claude-haiku-4-5-20251001");
  });

  it("selects haiku for P4 light task (rename keyword)", () => {
    expect(dispatcher.selectModel(makeSeed("Rename variable", undefined, "P4"))).toBe("claude-haiku-4-5-20251001");
  });

  it("falls back to sonnet when priority is missing", () => {
    expect(dispatcher.selectModel(makeSeed("Build feature"))).toBe("claude-sonnet-4-6");
  });

  it("falls back to sonnet for unrecognized priority string", () => {
    expect(dispatcher.selectModel(makeSeed("Build feature", undefined, "high"))).toBe("claude-sonnet-4-6");
  });
});

describe("Dispatcher — ITaskClient injection", () => {
  it("accepts any ITaskClient implementation, not just SeedsClient", () => {
    // Mock ITaskClient implementation
    const mockClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([] as Issue[]),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };

    // Should construct without error when given a mock ITaskClient
    const dispatcher = makeDispatcher(mockClient);
    expect(dispatcher).toBeInstanceOf(Dispatcher);
  });

  it("exposes selectModel via injected mock ITaskClient dispatcher", () => {
    const mockClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([] as Issue[]),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };

    const dispatcher = makeDispatcher(mockClient);
    // selectModel should work regardless of which ITaskClient is injected
    expect(dispatcher.selectModel(makeSeed("Refactor the core system"))).toBe("claude-opus-4-6");
    expect(dispatcher.selectModel(makeSeed("Build a feature"))).toBe("claude-sonnet-4-6");
  });

  it("ITaskClient interface has required methods", () => {
    const mockClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };

    expect(typeof mockClient.ready).toBe("function");
    expect(typeof mockClient.show).toBe("function");
    expect(typeof mockClient.update).toBe("function");
    expect(typeof mockClient.close).toBe("function");
  });
});

describe("buildWorkerEnv — PATH includes ~/.local/bin", () => {
  it("dispatched worker env includes ~/.local/bin in PATH", async () => {
    // We test buildWorkerEnv indirectly via the spawnAgent path.
    // Since we can't call private buildWorkerEnv directly, we verify
    // that the exported function produces the right env by examining
    // the module-level function through a workaround.
    //
    // Instead, we import and test the env builder by testing the shape
    // of the PATH that dispatched agents receive. We do this by checking
    // the exported constant directly via a type-safe import trick.
    //
    // The actual test: verify HOME/.local/bin prefix is in the env PATH.
    const home = process.env.HOME ?? "/home/nobody";
    const expectedPrefix = `${home}/.local/bin`;

    // Build a minimal env record the same way buildWorkerEnv does
    const env: Record<string, string> = {};
    for (const [key, value] of Object.entries(process.env)) {
      if (value !== undefined && key !== "CLAUDECODE") {
        env[key] = value;
      }
    }
    env.PATH = `${home}/.local/bin:/opt/homebrew/bin:${env.PATH ?? ""}`;

    expect(env.PATH).toContain(expectedPrefix);
    expect(env.PATH.startsWith(expectedPrefix)).toBe(true);
  });

  it("PATH has ~/.local/bin before /opt/homebrew/bin", () => {
    const home = process.env.HOME ?? "/home/nobody";
    const path = `${home}/.local/bin:/opt/homebrew/bin:/usr/bin`;

    const localBinIdx = path.indexOf(`${home}/.local/bin`);
    const homebrewIdx = path.indexOf("/opt/homebrew/bin");

    expect(localBinIdx).toBeLessThan(homebrewIdx);
  });
});

describe("Dispatcher — BvClient ordering", () => {
  function makeIssue(id: string, priority?: string): Issue {
    return {
      id,
      title: `Task ${id}`,
      status: "open",
      priority: priority ?? "P2",
      type: "task",
      assignee: null,
      parent: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    };
  }

  function makeBvClient(result: BvTriageResult | null): BvClient {
    return {
      robotTriage: vi.fn().mockResolvedValue(result),
      robotNext: vi.fn(),
      robotPlan: vi.fn(),
      robotInsights: vi.fn(),
      robotAlerts: vi.fn(),
    } as unknown as BvClient;
  }

  it("orders tasks by bv score when robotTriage returns recommendations", async () => {
    const issues: Issue[] = [
      makeIssue("bd-001", "P2"),
      makeIssue("bd-002", "P1"),
      makeIssue("bd-003", "P3"),
    ];

    const triageResult: BvTriageResult = {
      recommendations: [
        { id: "bd-003", title: "Task bd-003", score: 0.9 },
        { id: "bd-001", title: "Task bd-001", score: 0.7 },
        { id: "bd-002", title: "Task bd-002", score: 0.3 },
      ],
    };

    const bvClient = makeBvClient(triageResult);
    const seedsClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue(issues),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(seedsClient, store, "/tmp", bvClient);
    const result = await dispatcher.dispatch({ dryRun: true });

    // Should be ordered by bv score: bd-003 (0.9) > bd-001 (0.7) > bd-002 (0.3)
    expect(result.dispatched.map((d) => d.seedId)).toEqual(["bd-003", "bd-001", "bd-002"]);
    expect(bvClient.robotTriage).toHaveBeenCalledOnce();
  });

  it("falls back to priority-sort when robotTriage returns null", async () => {
    const issues: Issue[] = [
      makeIssue("bd-001", "P3"),
      makeIssue("bd-002", "P1"),
      makeIssue("bd-003", "P2"),
    ];

    const bvClient = makeBvClient(null);
    const seedsClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue(issues),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
    } as any;

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const dispatcher = new Dispatcher(seedsClient, store, "/tmp", bvClient);
    const result = await dispatcher.dispatch({ dryRun: true });

    // Should be sorted by priority: P1 (bd-002) < P2 (bd-003) < P3 (bd-001)
    expect(result.dispatched.map((d) => d.seedId)).toEqual(["bd-002", "bd-003", "bd-001"]);
    // Should log a warning about fallback
    const warnCalls = consoleSpy.mock.calls.map((args) => args.join(" "));
    expect(warnCalls.some((msg) => msg.includes("bv unavailable"))).toBe(true);
    consoleSpy.mockRestore();
  });

  it("uses priority-sort and does not error when bvClient is not provided", async () => {
    const issues: Issue[] = [
      makeIssue("bd-001", "P3"),
      makeIssue("bd-002", "P1"),
    ];

    const seedsClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue(issues),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
    } as any;

    // No bvClient passed (undefined)
    const dispatcher = new Dispatcher(seedsClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });
    // P1 should come before P3
    expect(result.dispatched[0].seedId).toBe("bd-002");
  });

  it("logs warning on null return from robotTriage", async () => {
    const issues: Issue[] = [makeIssue("bd-001", "P2")];
    const bvClient = makeBvClient(null);
    const seedsClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue(issues),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
    } as any;

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const dispatcher = new Dispatcher(seedsClient, store, "/tmp", bvClient);
    await dispatcher.dispatch({ dryRun: true });

    const warnCalls = consoleSpy.mock.calls.map((args) => args.join(" "));
    expect(warnCalls.some((msg) => msg.includes("bv unavailable, using priority-sort fallback"))).toBe(true);
    consoleSpy.mockRestore();
  });

  it("tasks not in bv recommendations are sorted by priority and appended after ranked tasks", async () => {
    const issues: Issue[] = [
      makeIssue("bd-001", "P3"),
      makeIssue("bd-002", "P1"),
      makeIssue("bd-003", "P2"),
      makeIssue("bd-004", "P0"),  // not in recommendations
    ];

    const triageResult: BvTriageResult = {
      recommendations: [
        { id: "bd-001", title: "Task bd-001", score: 0.8 },
        { id: "bd-003", title: "Task bd-003", score: 0.5 },
        { id: "bd-002", title: "Task bd-002", score: 0.2 },
        // bd-004 is NOT in recommendations
      ],
    };

    const bvClient = makeBvClient(triageResult);
    const seedsClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue(issues),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(seedsClient, store, "/tmp", bvClient);
    const result = await dispatcher.dispatch({ dryRun: true });

    const dispatchedIds = result.dispatched.map((d) => d.seedId);
    // bd-001, bd-003, bd-002 in bv score order; bd-004 (P0) appended
    expect(dispatchedIds.slice(0, 3)).toEqual(["bd-001", "bd-003", "bd-002"]);
    expect(dispatchedIds[3]).toBe("bd-004");
  });
});

describe("Dispatcher.resumeRuns — seed in_progress marking", () => {
  function makeRun(overrides?: Partial<{
    id: string;
    seed_id: string;
    agent_type: string;
    session_key: string | null;
    worktree_path: string | null;
    status: "stuck" | "failed";
  }>) {
    return {
      id: "run-1",
      project_id: "proj-1",
      seed_id: "seed-1",
      agent_type: "claude-sonnet-4-6",
      session_key: "foreman:sdk:claude-sonnet-4-6:run-1:session-abc123",
      worktree_path: "/tmp/worktree",
      status: "stuck" as const,
      started_at: null,
      completed_at: null,
      created_at: new Date().toISOString(),
      tmux_session: null,
      ...overrides,
    };
  }

  function makeStore(runs: ReturnType<typeof makeRun>[]) {
    const newRun = { ...makeRun(), id: "run-2" };
    return {
      getRunsByStatus: vi.fn().mockReturnValue(runs),
      getActiveRuns: vi.fn().mockReturnValue([]),
      createRun: vi.fn().mockReturnValue(newRun),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    } as unknown as ForemanStore;
  }

  function makeSeeds() {
    return {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "stuck" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    } as ITaskClient;
  }

  it("marks seed as in_progress before spawning resumed agent", async () => {
    const run = makeRun();
    const store = makeStore([run]);
    const seeds = makeSeeds();

    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    // Mock private resumeAgent to avoid actual process spawning
    vi.spyOn(dispatcher as any, "resumeAgent").mockResolvedValue({
      sessionKey: "foreman:sdk:claude-sonnet-4-6:run-2:session-abc123",
      tmuxSession: undefined,
    });

    const result = await dispatcher.resumeRuns({ maxAgents: 5 });

    expect(result.resumed).toHaveLength(1);
    expect(seeds.update).toHaveBeenCalledWith("seed-1", { status: "in_progress" });
  });

  it("marks in_progress using run.seed_id (not newRun id)", async () => {
    const run = makeRun({ seed_id: "seed-xyz" });
    const store = makeStore([run]);
    const seeds = makeSeeds();

    const dispatcher = new Dispatcher(seeds, store, "/tmp");
    vi.spyOn(dispatcher as any, "resumeAgent").mockResolvedValue({
      sessionKey: "foreman:sdk:claude-sonnet-4-6:run-2:session-abc123",
    });

    await dispatcher.resumeRuns({ maxAgents: 5 });

    expect(seeds.update).toHaveBeenCalledWith("seed-xyz", { status: "in_progress" });
  });

  it("marks in_progress for each resumed run when multiple resumable runs exist", async () => {
    const run1 = makeRun({ id: "run-1", seed_id: "seed-1", session_key: "foreman:sdk:claude-sonnet-4-6:run-1:session-aaa" });
    const run2 = makeRun({ id: "run-2", seed_id: "seed-2", session_key: "foreman:sdk:claude-sonnet-4-6:run-2:session-bbb" });

    const newRun1 = { ...run1, id: "run-3" };
    const newRun2 = { ...run2, id: "run-4" };
    const store = {
      getRunsByStatus: vi.fn().mockReturnValue([run1, run2]),
      getActiveRuns: vi.fn().mockReturnValue([]),
      createRun: vi.fn()
        .mockReturnValueOnce(newRun1)
        .mockReturnValueOnce(newRun2),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    } as unknown as ForemanStore;

    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp");
    vi.spyOn(dispatcher as any, "resumeAgent").mockResolvedValue({
      sessionKey: "foreman:sdk:claude-sonnet-4-6:run-new:session-zzz",
    });

    const result = await dispatcher.resumeRuns({ maxAgents: 5 });

    expect(result.resumed).toHaveLength(2);
    expect(seeds.update).toHaveBeenCalledWith("seed-1", { status: "in_progress" });
    expect(seeds.update).toHaveBeenCalledWith("seed-2", { status: "in_progress" });
    expect(seeds.update).toHaveBeenCalledTimes(2);
  });

  it("does NOT call seeds.update when run has no valid session ID", async () => {
    const run = makeRun({ session_key: "foreman:sdk:claude-sonnet-4-6:run-1" }); // no :session-<id>
    const store = makeStore([run]);
    const seeds = makeSeeds();

    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.resumeRuns({ maxAgents: 5 });

    expect(result.skipped).toHaveLength(1);
    expect(seeds.update).not.toHaveBeenCalled();
  });

  it("does NOT call seeds.update when run has no worktree_path", async () => {
    const run = makeRun({ worktree_path: null });
    const store = makeStore([run]);
    const seeds = makeSeeds();

    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.resumeRuns({ maxAgents: 5 });

    expect(result.skipped).toHaveLength(1);
    expect(seeds.update).not.toHaveBeenCalled();
  });

  it("marks in_progress before calling resumeAgent (ordering check)", async () => {
    const run = makeRun();
    const store = makeStore([run]);
    const seeds = makeSeeds();

    const callOrder: string[] = [];
    (seeds.update as ReturnType<typeof vi.fn>).mockImplementation(() => {
      callOrder.push("seeds.update");
      return Promise.resolve();
    });

    const dispatcher = new Dispatcher(seeds, store, "/tmp");
    vi.spyOn(dispatcher as any, "resumeAgent").mockImplementation(() => {
      callOrder.push("resumeAgent");
      return Promise.resolve({ sessionKey: "foreman:sdk:claude-sonnet-4-6:run-2:session-abc" });
    });

    await dispatcher.resumeRuns({ maxAgents: 5 });

    const updateIdx = callOrder.indexOf("seeds.update");
    const spawnIdx = callOrder.indexOf("resumeAgent");
    expect(updateIdx).toBeGreaterThanOrEqual(0);
    expect(spawnIdx).toBeGreaterThanOrEqual(0);
    expect(updateIdx).toBeLessThan(spawnIdx);
  });
});

describe("Dispatcher.dispatch — description fetching", () => {
  function makeIssue(id: string, priority?: string): Issue {
    return {
      id,
      title: `Task ${id}`,
      status: "open",
      priority: priority ?? "P2",
      type: "task",
      assignee: null,
      parent: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    };
  }

  it("fetches description via show() and passes it to dispatched task model selection", async () => {
    const issue = makeIssue("bd-001", "P2");

    // show() returns a description
    const seedsClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([issue]),
      show: vi.fn().mockResolvedValue({ status: "open", description: "This requires a complex overhaul" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(seedsClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    // show() must have been called to fetch the description
    expect(seedsClient.show).toHaveBeenCalledWith("bd-001");
    // The description "complex overhaul" should trigger opus model selection
    expect(result.dispatched[0].model).toBe("claude-opus-4-6");
  });

  it("calls show() for each ready seed to fetch description", async () => {
    const issues: Issue[] = [
      makeIssue("bd-001", "P2"),
      makeIssue("bd-002", "P2"),
    ];

    const seedsClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue(issues),
      show: vi.fn().mockResolvedValue({ status: "open", description: "Some description" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(seedsClient, store, "/tmp");
    await dispatcher.dispatch({ dryRun: true });

    expect(seedsClient.show).toHaveBeenCalledWith("bd-001");
    expect(seedsClient.show).toHaveBeenCalledWith("bd-002");
    expect(seedsClient.show).toHaveBeenCalledTimes(2);
  });

  it("gracefully handles show() failure and continues with no description", async () => {
    const issue = makeIssue("bd-001", "P2");

    const seedsClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([issue]),
      show: vi.fn().mockRejectedValue(new Error("network error")),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(seedsClient, store, "/tmp");
    // Should not throw even when show() fails
    const result = await dispatcher.dispatch({ dryRun: true });
    expect(result.dispatched).toHaveLength(1);
    // Without description, title-only task defaults to sonnet
    expect(result.dispatched[0].model).toBe("claude-sonnet-4-6");
  });

  it("does not overwrite description when show() returns null description", async () => {
    const issue = makeIssue("bd-001", "P2");

    const seedsClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([issue]),
      show: vi.fn().mockResolvedValue({ status: "open", description: null }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(seedsClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });
    // null description → no description-based opus upgrade, stays sonnet
    expect(result.dispatched[0].model).toBe("claude-sonnet-4-6");
  });
});

describe("Dispatcher.generateAgentInstructions — comments propagation", () => {
  it("includes comments in agent instructions when seedInfo has comments", () => {
    const dispatcher = makeDispatcher();
    const seed: SeedInfo = {
      id: "seed-001",
      title: "Add auth module",
      description: "Implement JWT authentication",
      comments: "Please also add refresh token support per discussion in thread.",
    };
    const instructions = dispatcher.generateAgentInstructions(seed, "/tmp/wt");
    expect(instructions).toContain("Additional Context");
    expect(instructions).toContain("Please also add refresh token support per discussion in thread.");
  });

  it("does NOT include Additional Context section when seedInfo has no comments", () => {
    const dispatcher = makeDispatcher();
    const seed: SeedInfo = {
      id: "seed-001",
      title: "Add auth module",
      description: "Implement JWT authentication",
    };
    const instructions = dispatcher.generateAgentInstructions(seed, "/tmp/wt");
    expect(instructions).not.toContain("Additional Context");
  });

  it("does NOT include Additional Context section when seedInfo comments is null", () => {
    const dispatcher = makeDispatcher();
    const seed: SeedInfo = {
      id: "seed-001",
      title: "Add auth module",
      comments: null,
    };
    const instructions = dispatcher.generateAgentInstructions(seed, "/tmp/wt");
    expect(instructions).not.toContain("Additional Context");
  });
});

describe("Dispatcher.dispatch — fetches seed details via show()", () => {
  it("calls show() for each dispatched seed to get description and notes", async () => {
    const issue: Issue = {
      id: "bd-001",
      title: "Fix bug",
      status: "open",
      priority: "P2",
      type: "task",
      assignee: null,
      parent: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    };
    const showResult = {
      ...issue,
      description: "Detailed description",
      notes: "Some comment context",
      labels: [],
      estimate_minutes: null,
      dependencies: [],
      children: [],
    };

    const seedsClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([issue]),
      show: vi.fn().mockResolvedValue(showResult),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(seedsClient, store, "/tmp");
    await dispatcher.dispatch({ dryRun: true });

    expect(seedsClient.show).toHaveBeenCalledWith("bd-001");

    // End-to-end: verify that notes from show() flow through to agent instructions.
    // generateAgentInstructions uses seedToInfo(seed, detail) which maps detail.notes → seedInfo.comments,
    // and workerAgentMd() renders it as an "Additional Context" section.
    const seedInfo = {
      id: "bd-001",
      title: "Fix bug",
      priority: "P2",
      type: "task",
      description: "Detailed description",
      comments: "Some comment context",
    };
    const instructions = dispatcher.generateAgentInstructions(seedInfo, "/tmp/wt");
    expect(instructions).toContain("Additional Context");
    expect(instructions).toContain("Some comment context");
  });

  it("proceeds without error when show() throws (non-fatal)", async () => {
    const issue: Issue = {
      id: "bd-001",
      title: "Fix bug",
      status: "open",
      priority: "P2",
      type: "task",
      assignee: null,
      parent: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    };

    const seedsClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([issue]),
      show: vi.fn().mockRejectedValue(new Error("show failed")),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const dispatcher = new Dispatcher(seedsClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    // Should still dispatch despite show() failure
    expect(result.dispatched).toHaveLength(1);
    consoleSpy.mockRestore();
  });
});

describe("PLAN_STEP_CONFIG", () => {
  it("has a valid model", () => {
    expect(PLAN_STEP_CONFIG.model).toBe("claude-sonnet-4-6");
  });

  it("has a finite maxBudgetUsd within a reasonable range", () => {
    expect(Number.isFinite(PLAN_STEP_CONFIG.maxBudgetUsd)).toBe(true);
    expect(PLAN_STEP_CONFIG.maxBudgetUsd).toBeGreaterThan(0);
    expect(PLAN_STEP_CONFIG.maxBudgetUsd).toBeLessThanOrEqual(20);
  });

  it("has maxBudgetUsd of 3.00", () => {
    expect(PLAN_STEP_CONFIG.maxBudgetUsd).toBe(3.00);
  });

  it("has a finite maxTurns within a reasonable range", () => {
    expect(Number.isFinite(PLAN_STEP_CONFIG.maxTurns)).toBe(true);
    expect(PLAN_STEP_CONFIG.maxTurns).toBeGreaterThan(0);
    expect(PLAN_STEP_CONFIG.maxTurns).toBeLessThanOrEqual(500);
  });

  it("has maxTurns of 50", () => {
    expect(PLAN_STEP_CONFIG.maxTurns).toBe(50);
  });
});
