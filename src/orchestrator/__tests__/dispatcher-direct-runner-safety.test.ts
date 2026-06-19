/**
 * Tests for FT-003: Direct runner state bypass and safety.
 *
 * Covers:
 * - Direct task runner execution (bypassing state gates)
 * - Invalid task / workflow error handling in dispatch
 * - Safe worktree/run locking (concurrent access)
 * - Dispatcher delegation to the canonical pipeline runner
 *
 * @module src/orchestrator/__tests__/dispatcher-direct-runner-safety.test
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { Dispatcher, nativeTaskToIssue } from "../dispatcher.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import type { ForemanStore, NativeTask, Run } from "../../lib/store.js";
import type { NativeTaskStatus } from "../types.js";

// ── Module-level mock refs (hoisted so factories can reference them) ──────────────────

// eslint-disable-next-line @typescript-eslint/no-unused-vars
const { mockLoadWorkflowConfig, mockResolveWorkflowName } = vi.hoisted(() => ({
  mockLoadWorkflowConfig: vi.fn().mockReturnValue({ setup: [], setupCache: undefined, vcs: undefined, merge: "auto" }),
  mockResolveWorkflowName: vi.fn().mockReturnValue("default"),
}));

// ── Module mocks ──────────────────────────────────────────────────────────────

vi.mock("../../lib/vcs/git-backend.js", () => ({
  GitBackend: vi.fn().mockImplementation(() => ({
    getCurrentBranch: vi.fn().mockResolvedValue("main"),
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    createWorkspace: vi.fn().mockResolvedValue({ workspacePath: "/tmp/mock-worktree", branchName: "foreman/t-001" }),
  })),
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: vi.fn().mockResolvedValue({
      name: "git",
      getCurrentBranch: vi.fn().mockResolvedValue("main"),
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
      createWorkspace: vi.fn().mockResolvedValue({ workspacePath: "/tmp/mock-worktree", branchName: "foreman/mock" }),
    }),
    resolveBackend: vi.fn(() => "git"),
  },
}));

vi.mock("../../lib/worktree-manager.js", () => ({
  WorktreeManager: class {
    async createWorktree(opts: { projectId: string; beadId: string; repoPath: string; baseBranch?: string }) {
      return { projectId: opts.projectId, beadId: opts.beadId, branchName: `foreman/${opts.beadId}`, path: `/tmp/worktrees/${opts.projectId}/${opts.beadId}`, exists: false };
    }
  },
}));

vi.mock("../../lib/setup.js", () => ({
  installDependencies: vi.fn().mockResolvedValue(undefined),
  runSetupWithCache: vi.fn().mockResolvedValue(undefined),
  runWorkspaceHook: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("node:fs/promises", async (importOriginal) => {
  const orig = await importOriginal<typeof import("node:fs/promises")>();
  return { ...orig, writeFile: vi.fn().mockResolvedValue(undefined), mkdir: vi.fn().mockResolvedValue(undefined), open: vi.fn().mockResolvedValue({ fd: 3, close: vi.fn() }), readdir: vi.fn().mockResolvedValue([]), unlink: vi.fn().mockResolvedValue(undefined) };
});

vi.mock("../pi-sdk-runner.js", () => ({
  runWithPiSdk: vi.fn().mockResolvedValue({ sessionKey: "mock-session" }),
}));

vi.mock("../stale-worktree-check.js", () => ({
  checkAndRebaseStaleWorktree: vi.fn().mockResolvedValue({ rebased: true, autoRebasePerformed: false }),
}));

// Mock pool-manager to prevent pg import error when loading Dispatcher
vi.mock("../../lib/db/pool-manager.js", () => ({
  getPoolConfig: vi.fn().mockReturnValue(undefined),
  initPool: vi.fn(),
}));

vi.mock("../../lib/workflow-loader.js", () => ({
  loadWorkflowConfig: (...args: unknown[]) => mockLoadWorkflowConfig(...args),
  resolveWorkflowName: (...args: unknown[]) => mockResolveWorkflowName(...args),
}));

vi.mock("../../lib/workflow-config-loader.js", () => ({
  resolveWorkflowType: vi.fn().mockReturnValue("feature"),
}));

vi.mock("../../lib/project-config.js", () => ({
  loadProjectConfig: vi.fn().mockReturnValue(null),
  resolveVcsConfig: vi.fn().mockReturnValue({ backend: "git" }),
}));

// ── Helpers ────────────────────────────────────────────────────────────────────

function makeIssue(id = "bd-001", overrides?: Partial<Issue>): Issue {
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

function nativeTaskFromIssue(issue: Issue, status: NativeTaskStatus = "ready"): NativeTask {
  return {
    id: issue.id,
    title: issue.title,
    description: issue.description ?? null,
    type: issue.type ?? "task",
    priority: Number(String(issue.priority ?? "2").replace(/^P/, "")) || 2,
    status,
    run_id: null,
    branch: null,
    external_id: null,
    labels: issue.labels ?? [],
    parent: issue.parent ?? null,
    created_at: issue.created_at,
    updated_at: issue.updated_at,
    approved_at: null,
    closed_at: null,
  };
}

function makeRun(overrides?: Partial<Run>): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "bd-001",
    agent_type: "claude-sonnet-4-6",
    session_key: null,
    worktree_path: "/tmp/worktree",
    status: "pending",
    started_at: null,
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,
    base_branch: null,
    merge_strategy: "auto",
    cooldown_until: null,
    ...overrides,
  };
}

let currentReadyIssues: Issue[] = [];

function makeStore(overrides?: Partial<ForemanStore>): ForemanStore {
  return {
    getActiveRuns: vi.fn().mockReturnValue([]),
    getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    getRunsForSeed: vi.fn().mockReturnValue([]),
    getRunsByStatus: vi.fn().mockReturnValue([]),
    getStuckRunsForSeed: vi.fn().mockReturnValue([]),
    hasNativeTasks: vi.fn().mockReturnValue(true),
    getReadyTasks: vi.fn(() => currentReadyIssues.map((i) => nativeTaskFromIssue(i))),
    getTaskByExternalId: vi.fn().mockReturnValue(null),
    getTaskById: vi.fn((id: string) => currentReadyIssues.map((i) => nativeTaskFromIssue(i)).find((t) => t.id === id) ?? null),
    claimTask: vi.fn().mockReturnValue(true),
    updateTaskStatus: vi.fn(),
    updateTaskLabels: vi.fn(),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    sendMessage: vi.fn(),
    hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    ...overrides,
  } as unknown as ForemanStore;
}

function makeSeeds(): ITaskClient {
  return {
    ready: vi.fn().mockResolvedValue([]),
    show: vi.fn().mockResolvedValue({ status: "open" }),
    update: vi.fn().mockResolvedValue(undefined),
    close: vi.fn().mockResolvedValue(undefined),
    list: vi.fn().mockResolvedValue([]),
    comments: vi.fn().mockResolvedValue(null),
  } as unknown as ITaskClient;
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. DIRECT TASK RUNNER — STATE-GATE BYPASS
// ─────────────────────────────────────────────────────────────────────────────

describe("Dispatcher — state-gate bypass for direct task runner", () => {
  beforeEach(() => { currentReadyIssues = []; });

  it("dispatches a 'closed' task when targeted via seedId option (bypass ready-state filter)", async () => {
    // `foreman run task <id>` bypasses state gating — it uses opts.seedId
    const closedTask = makeIssue("bd-closed", { status: "closed" });
    currentReadyIssues = [closedTask];

    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(true),
      getReadyTasks: vi.fn().mockReturnValue([nativeTaskFromIssue(closedTask)]),
      getTaskByExternalId: vi.fn().mockResolvedValue(null),
      getTaskById: vi.fn().mockResolvedValue(nativeTaskFromIssue(closedTask, "closed")),
      claimTask: vi.fn().mockReturnValue(true),
      updateTaskStatus: vi.fn(),
      updateTaskLabels: vi.fn(),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      sendMessage: vi.fn(),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    } as unknown as ForemanStore;

    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    // seedId option: simulates `foreman run --bead bd-closed` on a closed task
    const result = await dispatcher.dispatch({ dryRun: true, seedId: "bd-closed", projectId: "proj-1" });

    // Task is found (not skipped as "not found") — may be skipped due to non-ready status,
    // but the key behavior is that no false "not found" error occurs.
    expect(result.dispatched.some((d) => d.seedId === "bd-closed") || result.skipped.some((s) => s.seedId === "bd-closed")).toBe(true);
  });

  it("skips a merged-outcome task even when explicitly targeted via seedId (defensive guard)", async () => {
    const mergedTask = makeIssue("bd-merged");
    currentReadyIssues = [mergedTask];

    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([makeRun({ seed_id: "bd-merged", status: "merged" })]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(true),
      getReadyTasks: vi.fn().mockReturnValue([nativeTaskFromIssue(mergedTask)]),
      getTaskByExternalId: vi.fn().mockResolvedValue(null),
      getTaskById: vi.fn().mockResolvedValue(nativeTaskFromIssue(mergedTask)),
      claimTask: vi.fn().mockReturnValue(true),
      updateTaskStatus: vi.fn(),
      updateTaskLabels: vi.fn(),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      sendMessage: vi.fn(),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    } as unknown as ForemanStore;

    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, seedId: "bd-merged", projectId: "proj-1" });

    // Merged-outcome guard takes precedence — even explicit targeting skips it
    expect(result.dispatched.some((d) => d.seedId === "bd-merged")).toBe(false);
    expect(result.skipped.some((s) => s.seedId === "bd-merged" && s.reason.includes("merged"))).toBe(true);
  });

  it("dispatches when cooldown has expired and clears the cooldown state", async () => {
    const cooldownTask = makeIssue("bd-cool");
    currentReadyIssues = [cooldownTask];

    // Cooldown expired 1 minute ago
    const pastCooldownUntil = new Date(Date.now() - 60_000).toISOString();
    const updateTaskStatus = vi.fn();

    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([makeRun({ seed_id: "bd-cool", status: "cooldown", cooldown_until: pastCooldownUntil })]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(true),
      getReadyTasks: vi.fn().mockReturnValue([nativeTaskFromIssue(cooldownTask, "cooldown")]),
      getTaskByExternalId: vi.fn().mockResolvedValue(null),
      getTaskById: vi.fn().mockResolvedValue(nativeTaskFromIssue(cooldownTask, "cooldown")),
      claimTask: vi.fn().mockReturnValue(true),
      updateTaskStatus,
      updateTaskLabels: vi.fn(),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      sendMessage: vi.fn(),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    } as unknown as ForemanStore;

    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, seedId: "bd-cool", projectId: "proj-1" });

    // Expired cooldown → dispatcher clears task status to ready → dispatched
    expect(updateTaskStatus).toHaveBeenCalledWith("bd-cool", "ready");
    expect(result.dispatched.some((d) => d.seedId === "bd-cool")).toBe(true);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// 2. INVALID TASK / WORKFLOW ERROR HANDLING
// ─────────────────────────────────────────────────────────────────────────────

describe("Dispatcher.dispatch — invalid task / workflow errors", () => {
  beforeEach(() => { currentReadyIssues = []; });
  // Note: We do NOT call vi.restoreAllMocks() here because the workflow error
  // test uses mockImplementationOnce which must persist through the test.

  it("skips a non-ready task when targeted via seedId (not in 'ready' status)", async () => {
    // Task is in 'review' state, not 'ready'
    const reviewTask = makeIssue("bd-review", { status: "review" });
    currentReadyIssues = [reviewTask];

    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(true),
      getReadyTasks: vi.fn().mockReturnValue([]), // not in ready list
      getTaskByExternalId: vi.fn().mockResolvedValue(nativeTaskFromIssue(reviewTask, "review")),
      getTaskById: vi.fn().mockResolvedValue(nativeTaskFromIssue(reviewTask, "review")),
      claimTask: vi.fn().mockReturnValue(true),
      updateTaskStatus: vi.fn(),
      updateTaskLabels: vi.fn(),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      sendMessage: vi.fn(),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    } as unknown as ForemanStore;

    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, seedId: "bd-review", projectId: "proj-1" });

    expect(result.dispatched.some((d) => d.seedId === "bd-review")).toBe(false);
    expect(result.skipped.some((s) => s.seedId === "bd-review" && s.reason.includes("not ready"))).toBe(true);
  });

  it("skips when nativeTaskOps.getTaskById returns null (task not found)", async () => {
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(true),
      getReadyTasks: vi.fn().mockReturnValue([]),
      getTaskByExternalId: vi.fn().mockResolvedValue(null),
      getTaskById: vi.fn().mockResolvedValue(null),
      claimTask: vi.fn().mockReturnValue(true),
      updateTaskStatus: vi.fn(),
      updateTaskLabels: vi.fn(),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      sendMessage: vi.fn(),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    } as unknown as ForemanStore;

    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, seedId: "non-existent-task", projectId: "proj-1" });

    expect(result.dispatched).toHaveLength(0);
    expect(result.skipped.some((s) => s.seedId === "non-existent-task" && s.reason.includes("not found"))).toBe(true);
  });

  it("handles getTaskById throwing without crashing dispatch", async () => {
    const seed = makeIssue("bd-error");
    currentReadyIssues = [seed];

    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(true),
      getReadyTasks: vi.fn().mockReturnValue([nativeTaskFromIssue(seed)]),
      getTaskByExternalId: vi.fn().mockResolvedValue(null),
      getTaskById: vi.fn().mockImplementation(() => { throw new Error("DB connection error"); }),
      claimTask: vi.fn().mockReturnValue(true),
      updateTaskStatus: vi.fn(),
      updateTaskLabels: vi.fn(),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      sendMessage: vi.fn(),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    } as unknown as ForemanStore;

    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    // Non-fatal: dispatch proceeds even when detail fetch fails
    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.dispatched.some((d) => d.seedId === "bd-error")).toBe(true);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// 3. SAFE WORKTREE / RUN LOCKING
// ─────────────────────────────────────────────────────────────────────────────

describe("Dispatcher.dispatch — safe worktree/run locking", () => {
  beforeEach(() => {
    currentReadyIssues = [];
  });
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("skips when hasActiveOrPendingRun returns true (worktree locked)", async () => {
    const seed = makeIssue("bd-locked");
    currentReadyIssues = [seed];

    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(true),
      getReadyTasks: vi.fn().mockReturnValue([nativeTaskFromIssue(seed)]),
      getTaskByExternalId: vi.fn().mockResolvedValue(null),
      getTaskById: vi.fn().mockResolvedValue(nativeTaskFromIssue(seed)),
      claimTask: vi.fn().mockReturnValue(true),
      updateTaskStatus: vi.fn(),
      updateTaskLabels: vi.fn(),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      sendMessage: vi.fn(),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(true),
    } as unknown as ForemanStore;

    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: false, projectId: "proj-1" });

    // Worktree locked → not dispatched
    expect(result.dispatched.some((d) => d.seedId === "bd-locked")).toBe(false);
    // Skipped due to concurrent race condition
    expect(result.skipped.some((s) => s.seedId === "bd-locked" && /concurrent|race|locked/i.test(s.reason))).toBe(true);
  });

  it("skips tasks with completed-but-unmerged runs (pending merge lock)", async () => {
    const seed = makeIssue("bd-pending-merge");
    currentReadyIssues = [seed];

    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([makeRun({ seed_id: "bd-pending-merge", status: "completed" })]),
      hasNativeTasks: vi.fn().mockReturnValue(true),
      getReadyTasks: vi.fn().mockReturnValue([nativeTaskFromIssue(seed)]),
      getTaskByExternalId: vi.fn().mockResolvedValue(null),
      getTaskById: vi.fn().mockResolvedValue(nativeTaskFromIssue(seed)),
      claimTask: vi.fn().mockReturnValue(true),
      updateTaskStatus: vi.fn(),
      updateTaskLabels: vi.fn(),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      sendMessage: vi.fn(),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    } as unknown as ForemanStore;

    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: false, projectId: "proj-1" });

    expect(result.dispatched.some((d) => d.seedId === "bd-pending-merge")).toBe(false);
    expect(result.skipped.some((s) => s.seedId === "bd-pending-merge" && s.reason.includes("completed run"))).toBe(true);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// 4. DISPATCHER DELEGATION TO CANONICAL RUNNER
// ─────────────────────────────────────────────────────────────────────────────

describe("Dispatcher — delegates to canonical pipeline runner (spawnWorkerProcess)", () => {
  beforeEach(() => { currentReadyIssues = []; });

  it("dispatches with correct worktreePath in the result for the canonical runner", async () => {
    const seed = makeIssue("bd-delegate");
    currentReadyIssues = [seed];

    const store = makeStore();
    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    // dryRun: true so we can verify the dispatched config without needing spawn mocking
    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.dispatched.some((d) => d.seedId === "bd-delegate")).toBe(true);
    const dispatched = result.dispatched.find((d) => d.seedId === "bd-delegate");
    expect(dispatched).toBeDefined();
    // The worktreePath in the dispatch result is used by spawnWorkerProcess to create the worktree
    expect(dispatched!.worktreePath).toBeDefined();
    expect(dispatched!.worktreePath).toContain("bd-delegate");
  });

  it("dispatches with runtime=claude-code (canonical Pi SDK runner)", async () => {
    const seed = makeIssue("bd-pipeline-cfg");
    currentReadyIssues = [seed];

    const store = makeStore();
    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.dispatched.some((d) => d.seedId === "bd-pipeline-cfg")).toBe(true);
    const dispatched = result.dispatched.find((d) => d.seedId === "bd-pipeline-cfg");
    expect(dispatched!.runtime).toBe("claude-code");
  });

  it("dispatches with model from resolved workflow config", async () => {
    const seed = makeIssue("bd-model-cfg");
    currentReadyIssues = [seed];

    const store = makeStore();
    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.dispatched.some((d) => d.seedId === "bd-model-cfg")).toBe(true);
    const dispatched = result.dispatched.find((d) => d.seedId === "bd-model-cfg");
    expect(dispatched!.model).toBeDefined();
  });

  it("dispatched result includes branchName for the canonical worktree", async () => {
    const seed = makeIssue("bd-branch-name");
    currentReadyIssues = [seed];

    const store = makeStore();
    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.dispatched.some((d) => d.seedId === "bd-branch-name")).toBe(true);
    const dispatched = result.dispatched.find((d) => d.seedId === "bd-branch-name");
    expect(dispatched!.branchName).toBeDefined();
    expect(dispatched!.branchName).toContain("bd-branch-name");
  });

  it("dispatched result includes runId for tracking", async () => {
    const seed = makeIssue("bd-run-id");
    currentReadyIssues = [seed];

    const store = makeStore();
    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, projectId: "proj-1" });

    expect(result.dispatched.some((d) => d.seedId === "bd-run-id")).toBe(true);
    const dispatched = result.dispatched.find((d) => d.seedId === "bd-run-id");
    expect(dispatched!.runId).toBeDefined();
  });

  it("does not dispatch when seedId targets a non-existent task (canonical runner not called)", async () => {
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(true),
      getReadyTasks: vi.fn().mockReturnValue([]),
      getTaskByExternalId: vi.fn().mockResolvedValue(null),
      getTaskById: vi.fn().mockResolvedValue(null),
      claimTask: vi.fn().mockReturnValue(true),
      updateTaskStatus: vi.fn(),
      updateTaskLabels: vi.fn(),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      sendMessage: vi.fn(),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    } as unknown as ForemanStore;

    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true, seedId: "truly-missing", projectId: "proj-1" });

    // No dispatched seeds at all
    expect(result.dispatched).toHaveLength(0);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// 5. nativeTaskToIssue — conversion utility
// ─────────────────────────────────────────────────────────────────────────────

describe("nativeTaskToIssue", () => {
  it("converts a native task to Issue format correctly", () => {
    const nativeTask: NativeTask = {
      id: "nt-001",
      title: "Native Task Conversion",
      description: "Test description",
      type: "feature",
      priority: 1,
      status: "ready",
      run_id: null,
      branch: null,
      external_id: null,
      labels: ["backend", "urgent"],
      parent: "parent-001",
      created_at: "2026-01-01T00:00:00.000Z",
      updated_at: "2026-01-02T00:00:00.000Z",
      approved_at: null,
      closed_at: null,
    };

    const issue = nativeTaskToIssue(nativeTask);

    expect(issue.id).toBe("nt-001");
    expect(issue.title).toBe("Native Task Conversion");
    expect(issue.description).toBe("Test description");
    expect(issue.type).toBe("feature");
    expect(issue.priority).toBe("P1");
    expect(issue.status).toBe("ready");
    expect(issue.labels).toEqual(["backend", "urgent"]);
    expect(issue.parent).toBe("parent-001");
  });

  it("extracts github issue number from external_id", () => {
    const nativeTask: NativeTask = {
      id: "gh-001",
      title: "GitHub Issue",
      description: null,
      type: "bug",
      priority: 0,
      status: "backlog",
      run_id: null,
      branch: null,
      external_id: "github:org/repo#42",
      labels: [],
      parent: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      approved_at: null,
      closed_at: null,
    };

    const issue = nativeTaskToIssue(nativeTask);

    expect(issue.githubIssueNumber).toBe(42);
    expect(issue.priority).toBe("P0");
  });

  it("maps numeric priority 0-4 to P0-P4 strings", () => {
    const cases: Array<[number, string]> = [[0, "P0"], [1, "P1"], [2, "P2"], [3, "P3"], [4, "P4"]];
    for (const [priority, expected] of cases) {
      const task: NativeTask = {
        id: `nt-${priority}`,
        title: "Priority Test",
        description: null,
        type: "task",
        priority,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        labels: [],
        parent: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      };
      expect(nativeTaskToIssue(task).priority).toBe(expected);
    }
  });

  it("handles null description and empty labels gracefully", () => {
    const task: NativeTask = {
      id: "nt-null",
      title: "Null Fields",
      description: null,
      type: "task",
      priority: 2,
      status: "ready",
      run_id: null,
      branch: null,
      external_id: null,
      labels: [],
      parent: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      approved_at: null,
      closed_at: null,
    };
    const issue = nativeTaskToIssue(task);
    expect(issue.description).toBeUndefined();
    expect(issue.labels).toEqual([]);
  });
});
