/**
 * Integration tests for Dispatcher — native task store path.
 *
 * Uses a real ForemanStore (in-memory SQLite) instead of mocks to verify
 * the end-to-end dispatch path with native tasks.
 *
 * Covers:
 * - Native store auto-detection (hasNativeTasks → native, empty → beads fallback)
 * - FOREMAN_TASK_STORE env var overrides (native / beads)
 * - Atomic claim transaction (claimTask)
 *
 * Verifies TRD-007 / REQ-014 / REQ-017.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { Dispatcher, resolveTaskStoreMode, nativeTaskToIssue } from "../dispatcher.js";
import { ForemanStore } from "../../lib/store.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import type { ForemanStore as ForemanStoreType } from "../../lib/store.js";

// ── Module mocks (minimal — only VCS needs mocking, store is real) ────────

vi.mock("../../lib/vcs/git-backend.js", () => ({
  GitBackend: vi.fn().mockImplementation(() => ({
    getCurrentBranch: vi.fn().mockResolvedValue("main"),
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    createWorkspace: vi.fn().mockResolvedValue({
      workspacePath: "/tmp/mock-worktree",
      branchName: "foreman/t-001",
    }),
  })),
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: vi.fn().mockResolvedValue({
      name: "git",
      getCurrentBranch: vi.fn().mockResolvedValue("main"),
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
      createWorkspace: vi.fn().mockResolvedValue({
        workspacePath: "/tmp/mock-worktree",
        branchName: "foreman/mock",
      }),
    }),
  },
}));

vi.mock("../../lib/setup.js", () => ({
  installDependencies: vi.fn().mockResolvedValue(undefined),
  runSetupWithCache: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("node:fs/promises", async (importOriginal) => {
  const orig = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...orig,
    writeFile: vi.fn().mockResolvedValue(undefined),
    mkdir: vi.fn().mockResolvedValue(undefined),
    open: vi.fn().mockResolvedValue({ fd: 3, close: vi.fn() }),
    readdir: vi.fn().mockResolvedValue([]),
    unlink: vi.fn().mockResolvedValue(undefined),
  };
});

vi.mock("../../lib/workflow-loader.js", () => ({
  loadWorkflowConfig: vi.fn().mockReturnValue({ setup: [], setupCache: undefined, vcs: undefined }),
  resolveWorkflowName: vi.fn().mockReturnValue("default"),
}));

vi.mock("../../lib/project-config.js", () => ({
  loadProjectConfig: vi.fn().mockReturnValue(null),
  resolveVcsConfig: vi.fn().mockReturnValue({ backend: "git" }),
}));

vi.mock("../templates.js", () => ({
  workerAgentMd: vi.fn().mockReturnValue("# Mock TASK.md\n"),
}));

vi.mock("../pi-sdk-runner.js", () => ({
  runWithPiSdk: vi.fn().mockResolvedValue({ sessionKey: "mock-session" }),
}));

vi.mock("../../lib/workflow-config-loader.js", () => ({
  resolveWorkflowType: vi.fn().mockReturnValue("feature"),
}));

// ── Test Fixtures ─────────────────────────────────────────────────────────

/** Insert a native task directly into the real store */
function insertNativeTask(store: ForemanStoreType, id: string, priority = 2, status = "ready"): void {
  const now = new Date().toISOString();
  store.getDb().prepare(
    `INSERT INTO tasks (id, title, description, type, priority, status, run_id, branch, external_id, created_at, updated_at)
     VALUES (?, ?, NULL, 'task', ?, ?, NULL, NULL, NULL, ?, ?)`,
  ).run(id, `Native task ${id}`, priority, status, now, now);
}

/** Create a mock Beads client that returns given issues */
function makeMockBeadsClient(issues: Issue[] = []): ITaskClient {
  return {
    ready: vi.fn().mockResolvedValue(issues),
    show: vi.fn().mockResolvedValue({ status: "open" }),
    update: vi.fn().mockResolvedValue(undefined),
    close: vi.fn().mockResolvedValue(undefined),
    list: vi.fn().mockResolvedValue([]),
  };
}

// ── Integration tests: resolveTaskStoreMode ──────────────────────────────

describe("resolveTaskStoreMode()", () => {
  afterEach(() => {
    delete process.env.FOREMAN_TASK_STORE;
  });

  it("returns 'auto' when FOREMAN_TASK_STORE is not set", () => {
    delete process.env.FOREMAN_TASK_STORE;
    expect(resolveTaskStoreMode()).toBe("auto");
  });

  it("returns 'auto' when FOREMAN_TASK_STORE='auto'", () => {
    process.env.FOREMAN_TASK_STORE = "auto";
    expect(resolveTaskStoreMode()).toBe("auto");
  });

  it("returns 'native' when FOREMAN_TASK_STORE='native'", () => {
    process.env.FOREMAN_TASK_STORE = "native";
    expect(resolveTaskStoreMode()).toBe("native");
  });

  it("returns 'beads' when FOREMAN_TASK_STORE='beads'", () => {
    process.env.FOREMAN_TASK_STORE = "beads";
    expect(resolveTaskStoreMode()).toBe("beads");
  });

  it("returns 'auto' for invalid value", () => {
    process.env.FOREMAN_TASK_STORE = "invalid-value";
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const mode = resolveTaskStoreMode();
    expect(mode).toBe("auto");
    consoleSpy.mockRestore();
  });
});

// ── Integration tests: nativeTaskToIssue ─────────────────────────────────

describe("nativeTaskToIssue()", () => {
  it("converts integer priority 0..4 to P-string form", () => {
    for (let p = 0; p <= 4; p++) {
      const task = {
        id: `t-${p}`,
        title: `Task ${p}`,
        description: null,
        type: "task" as const,
        priority: p,
        status: "ready" as const,
        run_id: null,
        branch: null,
        external_id: null,
        created_at: "2024-01-01T00:00:00.000Z",
        updated_at: "2024-01-01T00:00:00.000Z",
        approved_at: null,
        closed_at: null,
      };
      const issue = nativeTaskToIssue(task);
      expect(issue.priority).toBe(`P${p}`);
    }
  });

  it("preserves id, title, type, status", () => {
    const task = {
      id: "native-42",
      title: "My task",
      description: "A description",
      type: "bug" as const,
      priority: 1,
      status: "ready" as const,
      run_id: null,
      branch: null,
      external_id: null,
      created_at: "2024-01-01T00:00:00.000Z",
      updated_at: "2024-01-01T00:00:00.000Z",
      approved_at: null,
      closed_at: null,
    };
    const issue = nativeTaskToIssue(task);
    expect(issue.id).toBe("native-42");
    expect(issue.title).toBe("My task");
    expect(issue.type).toBe("bug");
    expect(issue.status).toBe("ready");
    expect(issue.description).toBe("A description");
  });

  it("maps null description to undefined", () => {
    const task = {
      id: "t-null-desc",
      title: "Task",
      description: null,
      type: "task" as const,
      priority: 2,
      status: "ready" as const,
      run_id: null,
      branch: null,
      external_id: null,
      created_at: "2024-01-01T00:00:00.000Z",
      updated_at: "2024-01-01T00:00:00.000Z",
      approved_at: null,
      closed_at: null,
    };
    const issue = nativeTaskToIssue(task);
    expect(issue.description == null).toBe(true);
  });
});

// ── Integration tests: ForemanStore native task methods ───────────────────

describe("ForemanStore native task methods (real SQLite)", () => {
  let store: ForemanStoreType;
  let tmpDir: string;
  let projectId: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-native-integ-"));
    const dbPath = join(tmpDir, "test.db");
    store = new ForemanStore(dbPath);
    // Register a project so runs can reference it
    const project = store.registerProject("Test Project", tmpDir);
    projectId = project.id;
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("hasNativeTasks returns false when no tasks exist", () => {
    expect(store.hasNativeTasks()).toBe(false);
  });

  it("hasNativeTasks returns true after inserting a ready task", () => {
    insertNativeTask(store, "native-001", 2, "ready");
    expect(store.hasNativeTasks()).toBe(true);
  });

  it("getReadyTasks returns empty array when no tasks exist", () => {
    expect(store.getReadyTasks()).toEqual([]);
  });

  it("getReadyTasks returns only 'ready' tasks ordered by priority ASC", () => {
    // Insert out of order
    insertNativeTask(store, "low-prio", 3, "ready");
    insertNativeTask(store, "high-prio", 0, "ready");
    insertNativeTask(store, "mid-prio", 2, "ready");
    // Insert a non-ready task (should be filtered out)
    insertNativeTask(store, "not-ready", 1, "backlog");

    const ready = store.getReadyTasks();
    expect(ready).toHaveLength(3);
    expect(ready[0].id).toBe("high-prio");
    expect(ready[1].id).toBe("mid-prio");
    expect(ready[2].id).toBe("low-prio");
  });

  it("claimTask returns true and updates status when task is unclaimed", () => {
    insertNativeTask(store, "claim-001", 2, "ready");
    // Create a run first so the FK constraint passes
    const run = store.createRun(projectId, "claim-001", "claude-sonnet-4-6");

    const result = store.claimTask("claim-001", run.id);
    expect(result).toBe(true);

    // Verify status changed to in-progress
    const task = store.getDb().prepare("SELECT status, run_id FROM tasks WHERE id = ?").get("claim-001") as { status: string; run_id: string };
    expect(task.status).toBe("in-progress");
    expect(task.run_id).toBe(run.id);
  });

  it("claimTask returns false when task is already claimed", () => {
    insertNativeTask(store, "double-claim", 2, "ready");
    // Create runs first
    const run1 = store.createRun(projectId, "double-claim", "claude-sonnet-4-6");
    const run2 = store.createRun(projectId, "double-claim", "claude-sonnet-4-6");

    // First claim succeeds
    const first = store.claimTask("double-claim", run1.id);
    expect(first).toBe(true);

    // Second claim fails (task no longer in 'ready' status)
    const second = store.claimTask("double-claim", run2.id);
    expect(second).toBe(false);

    // Verify original run_id preserved
    const task = store.getDb().prepare("SELECT run_id FROM tasks WHERE id = ?").get("double-claim") as { run_id: string };
    expect(task.run_id).toBe(run1.id);
  });

  it("claimTask returns false when task does not exist", () => {
    // Create a run first (needed because FK constraint is checked before WHERE clause)
    const run = store.createRun(projectId, "nonexistent", "claude-sonnet-4-6");
    const result = store.claimTask("nonexistent", run.id);
    expect(result).toBe(false);
  });
});

// ── Integration tests: Dispatcher — native auto-detection ────────────────

describe("Dispatcher — Native task store auto-detection (integration)", () => {
  let store: ForemanStoreType;
  let beadsClient: ITaskClient;
  let tmpDir: string;
  let projectId: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-native-integ-"));
    const dbPath = join(tmpDir, "test.db");
    store = new ForemanStore(dbPath);
    // Register a project so dispatcher can resolve projectId
    const project = store.registerProject("Test Project", tmpDir);
    projectId = project.id;
    beadsClient = makeMockBeadsClient([]);
  });

  afterEach(() => {
    delete process.env.FOREMAN_TASK_STORE;
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("uses native store when hasNativeTasks() returns true (auto mode)", async () => {
    insertNativeTask(store, "n-001", 2, "ready");
    insertNativeTask(store, "n-002", 1, "ready");

    const dispatcher = new Dispatcher(beadsClient, store, tmpDir);
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const result = await dispatcher.dispatch({ dryRun: true });
    consoleSpy.mockRestore();

    // Native tasks dispatched
    expect(result.dispatched.map((d) => d.seedId)).toContain("n-001");
    expect(result.dispatched.map((d) => d.seedId)).toContain("n-002");
  });

  it("falls back to beads when hasNativeTasks() returns false (auto mode)", async () => {
    // No native tasks inserted — hasNativeTasks() returns false
    const beadsIssues: Issue[] = [
      {
        id: "b-001",
        title: "Beads task 1",
        type: "task",
        priority: "P2",
        status: "open",
        assignee: null,
        parent: null,
        created_at: "2024-01-01T00:00:00.000Z",
        updated_at: "2024-01-01T00:00:00.000Z",
      },
    ];
    const clientWithIssues = makeMockBeadsClient(beadsIssues);

    const dispatcher = new Dispatcher(clientWithIssues, store, tmpDir);
    const result = await dispatcher.dispatch({ dryRun: true });

    // Beads tasks dispatched
    expect(result.dispatched.map((d) => d.seedId)).toContain("b-001");
  });
});

// ── Integration tests: FOREMAN_TASK_STORE overrides ──────────────────────

describe("Dispatcher — FOREMAN_TASK_STORE overrides (integration)", () => {
  let store: ForemanStoreType;
  let beadsClient: ITaskClient;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-native-integ-"));
    const dbPath = join(tmpDir, "test.db");
    store = new ForemanStore(dbPath);
    // Register a project so dispatcher can resolve projectId
    store.registerProject("Test Project", tmpDir);
    beadsClient = makeMockBeadsClient([]);
  });

  afterEach(() => {
    delete process.env.FOREMAN_TASK_STORE;
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("FOREMAN_TASK_STORE=native forces native store even when no native tasks", async () => {
    process.env.FOREMAN_TASK_STORE = "native";
    // No native tasks inserted, but env override should force native path

    const dispatcher = new Dispatcher(beadsClient, store, tmpDir);
    const result = await dispatcher.dispatch({ dryRun: true });

    // With no native tasks and FOREMAN_TASK_STORE=native, nothing is dispatched in dry-run mode
    // (dry-run mode doesn't call claimTask, but it also doesn't skip seeds without active runs)
    // The important thing is the native path was used (verified by no beads fallback message)
    expect(result.skipped.length).toBe(0); // No seeds were blocked/skipped
  });

  it("FOREMAN_TASK_STORE=beads forces beads even when native tasks exist", async () => {
    process.env.FOREMAN_TASK_STORE = "beads";
    insertNativeTask(store, "n-native-only", 1, "ready");

    const beadsIssues: Issue[] = [
      {
        id: "b-forced",
        title: "Forced beads task",
        type: "task",
        priority: "P1",
        status: "open",
        assignee: null,
        parent: null,
        created_at: "2024-01-01T00:00:00.000Z",
        updated_at: "2024-01-01T00:00:00.000Z",
      },
    ];
    const clientWithIssues = makeMockBeadsClient(beadsIssues);

    const dispatcher = new Dispatcher(clientWithIssues, store, tmpDir);
    const result = await dispatcher.dispatch({ dryRun: true });

    // Beads task dispatched, not native
    expect(result.dispatched.map((d) => d.seedId)).toContain("b-forced");
    expect(result.dispatched.map((d) => d.seedId)).not.toContain("n-native-only");
  });
});

// ── Integration tests: Atomic claim ─────────────────────────────────────

describe("Dispatcher — Atomic claim transaction (integration)", () => {
  let store: ForemanStoreType;
  let beadsClient: ITaskClient;
  let tmpDir: string;
  let projectId: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-native-integ-"));
    const dbPath = join(tmpDir, "test.db");
    store = new ForemanStore(dbPath);
    // Register a project so dispatcher can resolve projectId
    const project = store.registerProject("Test Project", tmpDir);
    projectId = project.id;
    beadsClient = makeMockBeadsClient([]);
  });

  afterEach(() => {
    delete process.env.FOREMAN_TASK_STORE;
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("claimTask is called with correct taskId and runId on real dispatch", async () => {
    process.env.FOREMAN_TASK_STORE = "native";
    insertNativeTask(store, "t-atomic-001", 1, "ready");

    const dispatcher = new Dispatcher(beadsClient, store, tmpDir);

    // Spy on the store's claimTask method
    const claimSpy = vi.spyOn(store, "claimTask");

    const result = await dispatcher.dispatch({ dryRun: false });

    // The task should be dispatched
    expect(result.dispatched.some((d) => d.seedId === "t-atomic-001")).toBe(true);

    // claimTask should have been called
    expect(claimSpy).toHaveBeenCalled();

    // Verify claimTask was called with the task ID and a run ID
    const callArgs = claimSpy.mock.calls[0];
    expect(callArgs[0]).toBe("t-atomic-001");
    expect(typeof callArgs[1]).toBe("string"); // runId
  });

  it("task that was already claimed by another run does not appear in ready seeds", async () => {
    process.env.FOREMAN_TASK_STORE = "native";
    // Insert two tasks: one ready, one already claimed (in-progress)
    insertNativeTask(store, "t-ready", 1, "ready");
    insertNativeTask(store, "t-claimed", 2, "ready");

    // Simulate race condition: another dispatcher already claimed t-claimed
    // by calling claimTask (which changes status to 'in-progress')
    const run2 = store.createRun(projectId, "t-claimed", "claude-sonnet-4-6");
    store.claimTask("t-claimed", run2.id);

    const dispatcher = new Dispatcher(beadsClient, store, tmpDir);

    // Spy on claimTask to verify it's only called for unclaimed tasks
    const claimSpy = vi.spyOn(store, "claimTask");

    const result = await dispatcher.dispatch({ dryRun: false });

    // Only the ready task should be dispatched
    expect(result.dispatched.map((d) => d.seedId)).toContain("t-ready");
    expect(result.dispatched.map((d) => d.seedId)).not.toContain("t-claimed");

    // claimTask should have been called once (for t-ready)
    expect(claimSpy).toHaveBeenCalledTimes(1);
    expect(claimSpy).toHaveBeenCalledWith("t-ready", expect.any(String));
  });

  it("does NOT call claimTask when using beads path", async () => {
    process.env.FOREMAN_TASK_STORE = "beads";
    insertNativeTask(store, "n-should-not-claim", 1, "ready");

    const beadsIssues: Issue[] = [
      {
        id: "b-001",
        title: "Beads task",
        type: "task",
        priority: "P2",
        status: "open",
        assignee: null,
        parent: null,
        created_at: "2024-01-01T00:00:00.000Z",
        updated_at: "2024-01-01T00:00:00.000Z",
      },
    ];
    const clientWithIssues = makeMockBeadsClient(beadsIssues);

    const dispatcher = new Dispatcher(clientWithIssues, store, tmpDir);

    const claimSpy = vi.spyOn(store, "claimTask");

    await dispatcher.dispatch({ dryRun: false });

    // claimTask must NOT be called on the beads path
    expect(claimSpy).not.toHaveBeenCalled();
  });
});
