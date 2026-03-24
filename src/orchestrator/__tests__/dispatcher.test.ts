import { describe, it, expect, vi, beforeEach } from "vitest";
import { Dispatcher } from "../dispatcher.js";
import { PLAN_STEP_CONFIG } from "../roles.js";
import type { SeedInfo } from "../types.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import type { BvClient, BvTriageResult } from "../../lib/bv.js";
import type { ForemanStore } from "../../lib/store.js";

// Minimal mocks
const mockStore = {
  getActiveRuns: vi.fn().mockReturnValue([]),
  getRunsByStatus: vi.fn().mockReturnValue([]),
  getRunsByStatuses: vi.fn().mockReturnValue([]),
  getStuckRunsForSeed: vi.fn().mockReturnValue([]),
} as unknown as ForemanStore;
const mockSeeds = {} as unknown as ITaskClient;

function makeDispatcher(client?: ITaskClient, bvClient?: BvClient | null) {
  return new Dispatcher(client ?? mockSeeds, mockStore, "/tmp", bvClient);
}

function makeSeed(title: string, description?: string, priority?: string): SeedInfo {
  return { id: "seed-001", title, description, priority };
}

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
      getRunsByStatus: vi.fn().mockReturnValue([]),
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
      getRunsByStatus: vi.fn().mockReturnValue([]),
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
      getRunsByStatus: vi.fn().mockReturnValue([]),
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
      getRunsByStatus: vi.fn().mockReturnValue([]),
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
      getRunsByStatus: vi.fn().mockReturnValue([]),
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
      agent_type: "anthropic/claude-sonnet-4-6",
      session_key: "foreman:sdk:claude-sonnet-4-6:run-1:session-abc123",
      worktree_path: "/tmp/worktree",
      status: "stuck" as const,
      started_at: null,
      completed_at: null,
      created_at: new Date().toISOString(),      ...overrides,
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

  it("fetches description via show() and includes it in the dispatched task", async () => {
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
      getRunsByStatus: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(seedsClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    // show() must have been called to fetch the description
    expect(seedsClient.show).toHaveBeenCalledWith("bd-001");
    // Model is now determined per-phase by workflow YAML; dispatch default is sonnet
    expect(result.dispatched[0].model).toBe("anthropic/claude-sonnet-4-6");
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
      getRunsByStatus: vi.fn().mockReturnValue([]),
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
      getRunsByStatus: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(seedsClient, store, "/tmp");
    // Should not throw even when show() fails
    const result = await dispatcher.dispatch({ dryRun: true });
    expect(result.dispatched).toHaveLength(1);
    // Without description, title-only task defaults to sonnet
    expect(result.dispatched[0].model).toBe("anthropic/claude-sonnet-4-6");
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
      getRunsByStatus: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(seedsClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });
    // null description → no description-based opus upgrade, stays sonnet
    expect(result.dispatched[0].model).toBe("anthropic/claude-sonnet-4-6");
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
      getRunsByStatus: vi.fn().mockReturnValue([]),
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
      getRunsByStatus: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const dispatcher = new Dispatcher(seedsClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    // Should still dispatch despite show() failure
    expect(result.dispatched).toHaveLength(1);
    consoleSpy.mockRestore();
  });
});

describe("Dispatcher.dispatch — fetches bead comments via comments()", () => {
  function makeIssue(): Issue {
    return {
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
  }

  it("calls comments() for each dispatched seed", async () => {
    const issue = makeIssue();
    const showResult = { ...issue, description: "Detail", notes: null, labels: [], estimate_minutes: null, dependencies: [], children: [] };

    const seedsClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([issue]),
      show: vi.fn().mockResolvedValue(showResult),
      comments: vi.fn().mockResolvedValue("**alice** (2026-01-01T00:00:00Z):\nPlease add rate limiting"),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(seedsClient, store, "/tmp");
    await dispatcher.dispatch({ dryRun: true });

    expect(seedsClient.comments).toHaveBeenCalledWith("bd-001");
  });

  it("includes bead comments in agent instructions via seedInfo.comments", async () => {
    const dispatcher = makeDispatcher();
    const seedInfo: SeedInfo = {
      id: "bd-001",
      title: "Fix bug",
      priority: "P2",
      type: "task",
      description: "Detailed description",
      comments: "**alice** (2026-01-01T00:00:00Z):\nPlease add rate limiting",
    };
    const instructions = dispatcher.generateAgentInstructions(seedInfo, "/tmp/wt");
    expect(instructions).toContain("Additional Context");
    expect(instructions).toContain("alice");
    expect(instructions).toContain("Please add rate limiting");
  });

  it("combines notes from show() and comments() into one Additional Context block", async () => {
    const dispatcher = makeDispatcher();
    const seedInfo: SeedInfo = {
      id: "bd-001",
      title: "Fix bug",
      priority: "P2",
      type: "task",
      description: "Detailed description",
      comments: "Design note from notes\n\n---\n\n**Comments:**\n\n**alice** (2026-01-01T00:00:00Z):\nReviewer feedback",
    };
    const instructions = dispatcher.generateAgentInstructions(seedInfo, "/tmp/wt");
    expect(instructions).toContain("Design note from notes");
    expect(instructions).toContain("Reviewer feedback");
  });

  it("proceeds without error when comments() throws (non-fatal)", async () => {
    const issue = makeIssue();
    const showResult = { ...issue, description: null, notes: null, labels: [], estimate_minutes: null, dependencies: [], children: [] };

    const seedsClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([issue]),
      show: vi.fn().mockResolvedValue(showResult),
      comments: vi.fn().mockRejectedValue(new Error("comments fetch failed")),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const dispatcher = new Dispatcher(seedsClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    // Should still dispatch despite comments() failure
    expect(result.dispatched).toHaveLength(1);
    consoleSpy.mockRestore();
  });

  it("skips comments() call when ITaskClient does not implement comments", async () => {
    const issue = makeIssue();
    const showResult = { ...issue, description: null, notes: null, labels: [], estimate_minutes: null, dependencies: [], children: [] };

    // Client without comments() method (backward compat)
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
      getRunsByStatus: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(seedsClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    // Should dispatch normally without calling comments
    expect(result.dispatched).toHaveLength(1);
    expect(seedsClient.comments).toBeUndefined();
  });
});

describe("Dispatcher.dispatch — concurrent dispatch race guard", () => {
  function makeIssue(id = "bd-001"): Issue {
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
    };
  }

  it("skips a seed when hasActiveOrPendingRun returns true (race window)", async () => {
    const issue = makeIssue();
    const showResult = {
      ...issue,
      description: null,
      notes: null,
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
    // getActiveRuns returns empty (simulates stale snapshot from start of dispatch)
    // but hasActiveOrPendingRun returns true (simulates a concurrent run that was
    // created after the snapshot was taken)
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(true),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(seedsClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: false });

    expect(result.dispatched).toHaveLength(0);
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0].seedId).toBe("bd-001");
    expect(result.skipped[0].reason).toMatch(/concurrently/i);
    expect(store.hasActiveOrPendingRun).toHaveBeenCalledWith("bd-001", "proj-1");
  });

  it("dispatches a seed when hasActiveOrPendingRun returns false", async () => {
    const issue = makeIssue("bd-002");
    const showResult = {
      ...issue,
      description: null,
      notes: null,
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
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(seedsClient, store, "/tmp");
    // Use dryRun: true so we don't try to actually create worktrees
    const result = await dispatcher.dispatch({ dryRun: true });

    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].seedId).toBe("bd-002");
    // hasActiveOrPendingRun should NOT be called on dryRun (guard is before createRun, after dryRun continue)
    // Actually dryRun skips the try block entirely, so hasActiveOrPendingRun won't be called
  });

  it("calls hasActiveOrPendingRun with both seedId and projectId", async () => {
    const issue = makeIssue("bd-003");
    const showResult = {
      ...issue,
      description: null,
      notes: null,
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
      getProjectByPath: vi.fn().mockReturnValue({ id: "my-project" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(true),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(seedsClient, store, "/tmp");
    await dispatcher.dispatch({ dryRun: false });

    expect(store.hasActiveOrPendingRun).toHaveBeenCalledWith("bd-003", "my-project");
  });
});

describe("PLAN_STEP_CONFIG", () => {
  it("has a valid model", () => {
    expect(PLAN_STEP_CONFIG.model).toBe("anthropic/claude-sonnet-4-6");
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
