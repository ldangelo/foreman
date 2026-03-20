import { describe, it, expect, vi, beforeEach } from "vitest";
import { Dispatcher } from "../dispatcher.js";
import type { SeedInfo, ModelSelection } from "../types.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import type { ForemanStore } from "../../lib/store.js";

// Mock git module to prevent real git operations in pipeline path
vi.mock("../../lib/git.js", () => ({
  createWorktree: vi.fn().mockResolvedValue({
    worktreePath: "/tmp/.foreman-worktrees/mock-seed",
    branchName: "foreman/mock-seed",
  }),
}));

// Mock fs/promises writeFile to prevent real filesystem writes in pipeline path
vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    writeFile: vi.fn().mockResolvedValue(undefined),
  };
});

// ── Helpers ─────────────────────────────────────────────────────────────

const mockSeeds = {} as unknown as ITaskClient;
const mockStore = {} as unknown as ForemanStore;

function makeDispatcher(client?: ITaskClient, store?: ForemanStore) {
  return new Dispatcher(client ?? mockSeeds, store ?? mockStore, "/tmp");
}

function makeSeed(overrides?: Partial<SeedInfo>): SeedInfo {
  return {
    id: "seed-001",
    title: "Test task",
    description: "A test description",
    priority: "P2",
    type: "task",
    ...overrides,
  };
}

function makeIssue(id: string, type: string, priority?: string): Issue {
  return {
    id,
    title: `Task ${id}`,
    status: "open",
    priority: priority ?? "P2",
    type,
    assignee: null,
    parent: null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };
}

// ── routeByType unit tests ──────────────────────────────────────────────

describe("Dispatcher.routeByType", () => {
  const dispatcher = makeDispatcher();

  it("returns 'ensemble' for type 'bug'", () => {
    expect((dispatcher as any).routeByType(makeSeed({ type: "bug" }))).toBe("ensemble");
  });

  it("returns 'ensemble' for type 'feature'", () => {
    expect((dispatcher as any).routeByType(makeSeed({ type: "feature" }))).toBe("ensemble");
  });

  it("returns 'ensemble' for type 'epic'", () => {
    expect((dispatcher as any).routeByType(makeSeed({ type: "epic" }))).toBe("ensemble");
  });

  it("returns 'pipeline' for type 'task'", () => {
    expect((dispatcher as any).routeByType(makeSeed({ type: "task" }))).toBe("pipeline");
  });

  it("returns 'pipeline' for type 'chore'", () => {
    expect((dispatcher as any).routeByType(makeSeed({ type: "chore" }))).toBe("pipeline");
  });

  it("returns 'pipeline' for undefined type", () => {
    expect((dispatcher as any).routeByType(makeSeed({ type: undefined }))).toBe("pipeline");
  });

  it("returns 'pipeline' for type 'docs'", () => {
    expect((dispatcher as any).routeByType(makeSeed({ type: "docs" }))).toBe("pipeline");
  });

  it("returns 'pipeline' for type 'question'", () => {
    expect((dispatcher as any).routeByType(makeSeed({ type: "question" }))).toBe("pipeline");
  });
});

// ── dispatch() integration: routing to ensemble vs pipeline ─────────────

describe("Dispatcher.dispatch — workflow routing", () => {
  function makeFullStore() {
    return {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
      createRun: vi.fn().mockReturnValue({ id: "run-1" }),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      getRun: vi.fn(),
    } as unknown as ForemanStore;
  }

  function makeFullSeeds(issues: Issue[]) {
    return {
      ready: vi.fn().mockResolvedValue(issues),
      show: vi.fn().mockResolvedValue({ status: "open", description: "desc" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    } as ITaskClient;
  }

  it("calls dispatchPlanStep (not spawnAgent) when seed type is 'bug'", async () => {
    const bugIssue = makeIssue("bd-bug-1", "bug");
    const store = makeFullStore();
    const seeds = makeFullSeeds([bugIssue]);

    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    // Mock dispatchPlanStep to avoid SDK calls
    const dispatchPlanStepSpy = vi.spyOn(dispatcher, "dispatchPlanStep").mockResolvedValue({
      seedId: "bd-bug-1",
      title: "Task bd-bug-1",
      runId: "run-1",
      sessionKey: "foreman:plan:run-1",
    });

    // Mock spawnAgent to track if it's called
    const spawnAgentSpy = vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({
      sessionKey: "foreman:sdk:claude-sonnet-4-6:run-1",
    });

    const result = await dispatcher.dispatch({ projectId: "proj-1" });

    expect(dispatchPlanStepSpy).toHaveBeenCalledOnce();
    expect(spawnAgentSpy).not.toHaveBeenCalled();
    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].seedId).toBe("bd-bug-1");
  });

  it("calls spawnAgent (not dispatchPlanStep) when seed type is 'task'", async () => {
    const taskIssue = makeIssue("bd-task-1", "task");
    const store = makeFullStore();
    const seeds = makeFullSeeds([taskIssue]);

    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    // Mock dispatchPlanStep to track if it's called
    const dispatchPlanStepSpy = vi.spyOn(dispatcher, "dispatchPlanStep").mockResolvedValue({
      seedId: "bd-task-1",
      title: "Task bd-task-1",
      runId: "run-1",
      sessionKey: "foreman:plan:run-1",
    });

    // Mock spawnAgent to avoid process spawning
    const spawnAgentSpy = vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({
      sessionKey: "foreman:sdk:claude-sonnet-4-6:run-1",
    });

    const result = await dispatcher.dispatch({ projectId: "proj-1" });

    expect(spawnAgentSpy).toHaveBeenCalledOnce();
    expect(dispatchPlanStepSpy).not.toHaveBeenCalled();
    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].seedId).toBe("bd-task-1");
  });

  it("routes 'feature' type to ensemble (dispatchPlanStep)", async () => {
    const featureIssue = makeIssue("bd-feat-1", "feature");
    const store = makeFullStore();
    const seeds = makeFullSeeds([featureIssue]);

    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const dispatchPlanStepSpy = vi.spyOn(dispatcher, "dispatchPlanStep").mockResolvedValue({
      seedId: "bd-feat-1",
      title: "Task bd-feat-1",
      runId: "run-1",
      sessionKey: "foreman:plan:run-1",
    });

    const spawnAgentSpy = vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({
      sessionKey: "foreman:sdk:claude-sonnet-4-6:run-1",
    });

    const result = await dispatcher.dispatch({ projectId: "proj-1" });

    expect(dispatchPlanStepSpy).toHaveBeenCalledOnce();
    expect(spawnAgentSpy).not.toHaveBeenCalled();
    expect(result.dispatched).toHaveLength(1);
  });

  it("routes 'epic' type to ensemble (dispatchPlanStep)", async () => {
    const epicIssue = makeIssue("bd-epic-1", "epic");
    const store = makeFullStore();
    const seeds = makeFullSeeds([epicIssue]);

    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const dispatchPlanStepSpy = vi.spyOn(dispatcher, "dispatchPlanStep").mockResolvedValue({
      seedId: "bd-epic-1",
      title: "Task bd-epic-1",
      runId: "run-1",
      sessionKey: "foreman:plan:run-1",
    });

    const spawnAgentSpy = vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({
      sessionKey: "foreman:sdk:claude-sonnet-4-6:run-1",
    });

    const result = await dispatcher.dispatch({ projectId: "proj-1" });

    expect(dispatchPlanStepSpy).toHaveBeenCalledOnce();
    expect(spawnAgentSpy).not.toHaveBeenCalled();
    expect(result.dispatched).toHaveLength(1);
  });

  it("skips seed and adds to skipped when ensemble dispatch fails", async () => {
    const bugIssue = makeIssue("bd-bug-2", "bug");
    const store = makeFullStore();
    const seeds = makeFullSeeds([bugIssue]);

    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    vi.spyOn(dispatcher, "dispatchPlanStep").mockRejectedValue(
      new Error("SDK connection failed"),
    );

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const result = await dispatcher.dispatch({ projectId: "proj-1" });
    consoleSpy.mockRestore();

    expect(result.dispatched).toHaveLength(0);
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0].reason).toContain("Ensemble dispatch failed");
    expect(result.skipped[0].reason).toContain("SDK connection failed");
  });

  it("routes mixed types correctly — bug to ensemble, task to pipeline", async () => {
    const bugIssue = makeIssue("bd-bug-3", "bug");
    const taskIssue = makeIssue("bd-task-3", "task");
    const store = makeFullStore();
    const seeds = makeFullSeeds([bugIssue, taskIssue]);

    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const dispatchPlanStepSpy = vi.spyOn(dispatcher, "dispatchPlanStep").mockResolvedValue({
      seedId: "bd-bug-3",
      title: "Task bd-bug-3",
      runId: "run-1",
      sessionKey: "foreman:plan:run-1",
    });

    const spawnAgentSpy = vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({
      sessionKey: "foreman:sdk:claude-sonnet-4-6:run-2",
    });

    const result = await dispatcher.dispatch({ projectId: "proj-1" });

    // Bug should go to ensemble (dispatchPlanStep), task should go to pipeline (spawnAgent)
    expect(dispatchPlanStepSpy).toHaveBeenCalledOnce();
    expect(spawnAgentSpy).toHaveBeenCalledOnce();
    expect(result.dispatched).toHaveLength(2);
  });

  it("dryRun does NOT invoke ensemble dispatch (skips routing entirely)", async () => {
    const bugIssue = makeIssue("bd-bug-4", "bug");
    const store = makeFullStore();
    const seeds = makeFullSeeds([bugIssue]);

    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const dispatchPlanStepSpy = vi.spyOn(dispatcher, "dispatchPlanStep").mockResolvedValue({
      seedId: "bd-bug-4",
      title: "Task bd-bug-4",
      runId: "run-1",
      sessionKey: "foreman:plan:run-1",
    });

    const result = await dispatcher.dispatch({ projectId: "proj-1", dryRun: true });

    // dryRun should short-circuit before reaching routing logic
    expect(dispatchPlanStepSpy).not.toHaveBeenCalled();
    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].runId).toBe("(dry-run)");
  });

  it("passes correct ensemble command and input to dispatchPlanStep", async () => {
    const bugIssue = makeIssue("bd-bug-5", "bug");
    const store = makeFullStore();
    const seeds = makeFullSeeds([bugIssue]);
    // Return a description from show() so it propagates
    (seeds.show as ReturnType<typeof vi.fn>).mockResolvedValue({
      status: "open",
      description: "Fix the login page crash",
    });

    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const dispatchPlanStepSpy = vi.spyOn(dispatcher, "dispatchPlanStep").mockResolvedValue({
      seedId: "bd-bug-5",
      title: "Task bd-bug-5",
      runId: "run-1",
      sessionKey: "foreman:plan:run-1",
    });

    await dispatcher.dispatch({ projectId: "proj-1" });

    expect(dispatchPlanStepSpy).toHaveBeenCalledOnce();
    const [projId, seed, command, input, outputDir] = dispatchPlanStepSpy.mock.calls[0];
    expect(projId).toBe("proj-1");
    expect(seed.id).toBe("bd-bug-5");
    expect(command).toBe("/ensemble:fix-issue");
    expect(input).toContain("bd-bug-5");
    expect(input).toContain("Task bd-bug-5");
    expect(outputDir).toContain(".foreman/ensemble/bd-bug-5");
  });
});
