/**
 * TRD-015-TEST: Dispatcher VCS Backend creation and propagation.
 *
 * Acceptance Criteria:
 *   AC-T-015-1: Dispatcher creates VcsBackend via factory when workflow has vcs.backend set
 *   AC-T-015-2: VcsBackend is propagated to spawnAgent (with correct name for env var)
 *   AC-T-015-3: VcsBackend creation failure is non-fatal (dispatch continues)
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import { Dispatcher } from "../dispatcher.js";
import type { DispatcherOverrides } from "../dispatcher.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import type { ForemanStore, Run } from "../../lib/store.js";
import type { VcsBackend } from "../../lib/vcs/index.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { loadWorkflowConfig } from "../../lib/workflow-loader.js";
import type { WorkflowConfig } from "../../lib/workflow-loader.js";
import { WorktreeManager } from "../../lib/worktree-manager.js";

// ── Module Mocks ─────────────────────────────────────────────────────────────

let mockShowFn = vi.fn().mockRejectedValue(new Error("not found"));

vi.mock("../../lib/vcs/index.js", async (importOriginal) => {
  const original = await importOriginal<typeof import("../../lib/vcs/index.js")>();
  return {
    ...original,
    VcsBackendFactory: {
      create: vi.fn(),
      fromEnv: vi.fn(),
      resolveBackend: vi.fn(),
      createSync: vi.fn(),
    },
  };
});

vi.mock("../../lib/workflow-loader.js", () => ({
  loadWorkflowConfig: vi.fn(),
  resolveWorkflowName: vi.fn().mockReturnValue("default"),
}));

vi.mock("../../lib/workflow-config-loader.js", () => ({
  resolveWorkflowType: vi.fn().mockReturnValue("feature"),
}));

vi.mock("../../lib/setup.js", () => ({
  installDependencies: vi.fn().mockResolvedValue(undefined),
  runSetupWithCache: vi.fn().mockResolvedValue(undefined),
  runWorkspaceHook: vi.fn().mockResolvedValue(undefined),
}));

// Mock GitBackend so dispatcher's branch detection and fallback createWorkspace work in tests
vi.mock("../../lib/vcs/git-backend.js", () => ({
  GitBackend: class {
    constructor(_path: string) {}
    async getCurrentBranch(_path: string): Promise<string> { return "main"; }
    async detectDefaultBranch(_path: string): Promise<string> { return "main"; }
    async branchExists(_path: string, _branch: string): Promise<boolean> { return false; }
    async createWorkspace(_repoPath: string, taskId: string): Promise<{ workspacePath: string; branchName: string }> {
      return { workspacePath: `/tmp/worktrees/${taskId}`, branchName: `foreman/${taskId}` };
    }
  },
}));

vi.mock("../../lib/worktree-manager.js", () => ({
  WorktreeManager: class {
    async createWorktree(opts: { projectId: string; taskId: string; repoPath: string; baseBranch?: string }) {
      return {
        projectId: opts.projectId,
        taskId: opts.taskId,
        branchName: `foreman/${opts.taskId}`,
        path: `/tmp/worktrees/${opts.projectId}/${opts.taskId}`,
        exists: false,
      };
    }
  },
}));

vi.mock("../../lib/task-client.js", () => ({
  TaskClient: class {
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    constructor(_path: string) {}
    show = mockShowFn;
  },
}));

// Mock fs/promises to prevent actual file system writes during dispatch
vi.mock("node:fs/promises", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...original,
    writeFile: vi.fn().mockResolvedValue(undefined),
    mkdir: vi.fn().mockResolvedValue(undefined),
    open: vi.fn().mockResolvedValue({ fd: 1, close: vi.fn().mockResolvedValue(undefined) }),
    readdir: vi.fn().mockResolvedValue([]),
    unlink: vi.fn().mockResolvedValue(undefined),
  };
});

// ── Test Helpers ─────────────────────────────────────────────────────────────
interface DispatcherOverridesWithDefaultBranch extends DispatcherOverrides {
  defaultBranch: string;
}

interface SpawnAgentHost {
  spawnAgent: (...args: unknown[]) => Promise<{ sessionKey: string }>;
}


function makeGitBackend(): VcsBackend {
  return {
    name: "git",
    createWorkspace: vi.fn().mockResolvedValue({
      workspacePath: "/tmp/worktrees/test-task",
      branchName: "foreman/test-task",
    }),
    getCurrentBranch: vi.fn().mockResolvedValue("main"),
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    branchExists: vi.fn().mockResolvedValue(false),
  } as unknown as VcsBackend;
}

function makeJujutsuBackend(): VcsBackend {
  return {
    name: "jujutsu",
    createWorkspace: vi.fn().mockResolvedValue({
      workspacePath: "/tmp/worktrees/test-task",
      branchName: "foreman/test-task",
    }),
    getCurrentBranch: vi.fn().mockResolvedValue("main"),
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    branchExists: vi.fn().mockResolvedValue(false),
  } as unknown as VcsBackend;
}

function makeStore(): ForemanStore {
  return {
    getActiveRuns: vi.fn().mockReturnValue([]),
    getRunsByStatus: vi.fn().mockReturnValue([]),
    getRunsByStatuses: vi.fn().mockReturnValue([]),
    getStuckRunsForTask: vi.fn().mockReturnValue([]),
    getPendingTaskWrites: vi.fn().mockReturnValue([]),
    hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    getRunsForTask: vi.fn().mockReturnValue([]),
    createRun: vi.fn().mockReturnValue({ id: "run-001" }),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    sendMessage: vi.fn(),
    getProjectByPath: vi.fn().mockReturnValue({ id: "proj-001" }),
    hasNativeTasks: vi.fn().mockReturnValue(true),
    getReadyTasks: vi.fn().mockReturnValue([{
      id: "test-task",
      title: "Test Task",
      description: "task description",
      type: "task",
      priority: 2,
      status: "ready",
      run_id: null,
      branch: null,
      external_id: null,
      labels: [],
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      approved_at: new Date().toISOString(),
      closed_at: null,
    }]),
    getTaskByExternalId: vi.fn().mockReturnValue(null),
    getTaskById: vi.fn().mockReturnValue({ status: "ready" }),
    claimTask: vi.fn().mockReturnValue(true),
  } as unknown as ForemanStore;
}

function makeTasks(issue?: Partial<Issue>): ITaskClient {
  const task: Issue = {
    id: "test-task",
    title: "Test Task",
    status: "open",
    priority: "P2",
    type: "task",
    assignee: null,
    parent: null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    ...issue,
  };
  return {
    ready: vi.fn().mockResolvedValue([task]),
    show: vi.fn().mockResolvedValue({ status: "open", description: "task description" }),
    update: vi.fn().mockResolvedValue(undefined),
    close: vi.fn().mockResolvedValue(undefined),
    list: vi.fn().mockResolvedValue([]),
  };
}

// ── Tests: VcsBackend Creation (AC-T-015-1) ───────────────────────────────────

describe("Dispatcher — VCS Backend creation (TRD-015, AC-T-015-1)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(VcsBackendFactory.resolveBackend).mockImplementation(
      (config: { backend: "git" | "jujutsu" | "auto" }) => config.backend === "auto" ? "git" : config.backend,
    );
    mockShowFn = vi.fn().mockRejectedValue(new Error("not found"));
  });

  it("creates VcsBackend via factory when workflow config specifies 'git'", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockReturnValue({
      name: "default",
      phases: [],
      vcs: { backend: "git" },
    } as unknown as ReturnType<typeof loadWorkflowConfig>);

    const gitBackend = makeGitBackend();
    vi.mocked(VcsBackendFactory.create).mockResolvedValue(gitBackend);

    const store = makeStore();
    const tasks = makeTasks();
    const dispatcher = new Dispatcher(tasks, store, "/tmp/project");

    // Mock the private spawnAgent method to prevent actual process spawning
    vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    await dispatcher.dispatch({ dryRun: false });

    // Dispatcher now creates one auto-detected backend up front and reuses it.
    expect(VcsBackendFactory.create).toHaveBeenCalledWith(
      { backend: "auto" },
      "/tmp/project",
    );
  });

  it("creates VcsBackend via factory when workflow config specifies 'jujutsu'", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockReturnValue({
      name: "default",
      phases: [],
      vcs: { backend: "jujutsu" },
    } as unknown as ReturnType<typeof loadWorkflowConfig>);

    const jjBackend = makeJujutsuBackend();
    vi.mocked(VcsBackendFactory.create).mockResolvedValue(jjBackend);

    const store = makeStore();
    const tasks = makeTasks();
    const dispatcher = new Dispatcher(tasks, store, "/tmp/project");
    vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    await dispatcher.dispatch({ dryRun: false });

    expect(VcsBackendFactory.create).toHaveBeenCalledWith(
      { backend: "auto" },
      "/tmp/project",
    );
  });

  it("defaults to 'git' backend when workflow config has no vcs section", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockReturnValue({
      name: "default",
      phases: [],
      // no vcs section
    } as unknown as ReturnType<typeof loadWorkflowConfig>);

    const gitBackend = makeGitBackend();
    vi.mocked(VcsBackendFactory.create).mockResolvedValue(gitBackend);

    const store = makeStore();
    const tasks = makeTasks();
    const dispatcher = new Dispatcher(tasks, store, "/tmp/project");
    vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    await dispatcher.dispatch({ dryRun: false });

    // Dispatcher now creates one auto-detected backend up front and reuses it.
    expect(VcsBackendFactory.create).toHaveBeenCalledWith(
      { backend: "auto" },
      "/tmp/project",
    );
  });

  it("VcsBackend is created once per task per dispatch call", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockReturnValue({
      name: "default",
      phases: [],
      vcs: { backend: "git" },
    } as unknown as ReturnType<typeof loadWorkflowConfig>);

    vi.mocked(VcsBackendFactory.create).mockResolvedValue(makeGitBackend());

    const store = makeStore();
    const tasks = makeTasks();
    const dispatcher = new Dispatcher(tasks, store, "/tmp/project");
    vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    await dispatcher.dispatch({ dryRun: false });

    // Called exactly once for the single ready task
    expect(VcsBackendFactory.create).toHaveBeenCalledTimes(1);
  });

});

// ── Tests: VcsBackend Propagation to spawnAgent (AC-T-015-2) ─────────────────

describe("Dispatcher — VcsBackend propagation to spawnAgent (TRD-015, AC-T-015-2)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(VcsBackendFactory.resolveBackend).mockImplementation(
      (config: { backend: "git" | "jujutsu" | "auto" }) => config.backend === "auto" ? "git" : config.backend,
    );
    mockShowFn = vi.fn().mockRejectedValue(new Error("not found"));
  });

  it("passes VcsBackend instance (name='git') to spawnAgent", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockReturnValue({
      name: "default",
      phases: [],
      vcs: { backend: "git" },
    } as unknown as ReturnType<typeof loadWorkflowConfig>);

    const gitBackend = makeGitBackend();
    vi.mocked(VcsBackendFactory.create).mockResolvedValue(gitBackend);

    const store = makeStore();
    const tasks = makeTasks();
    const dispatcher = new Dispatcher(tasks, store, "/tmp/project");

    // Spy on private spawnAgent to capture the vcsBackend argument
    const spawnAgentSpy = vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    await dispatcher.dispatch({ dryRun: false });

    expect(spawnAgentSpy).toHaveBeenCalledOnce();

    // The 8th argument (index 7) is vcsBackend — verify it has name='git'
    const callArgs = spawnAgentSpy.mock.calls[0];
    const vcsBackendArg = callArgs[7] as VcsBackend | undefined;
    expect(vcsBackendArg).toBeDefined();
    expect(vcsBackendArg?.name).toBe("git");
  });

  it("uses registered write overrides for dispatch mail/event writes instead of the local store", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockReturnValue({
      name: "default",
      phases: [],
      vcs: { backend: "git" },
    } as unknown as ReturnType<typeof loadWorkflowConfig>);

    vi.mocked(VcsBackendFactory.create).mockResolvedValue(makeGitBackend());

    const store = makeStore();
    const createdRun = {
      id: "run-registered",
      project_id: "proj-registered",
      task_id: "test-task",
      agent_type: "claude-sonnet-4-6",
      session_key: null,
      worktree_path: "/tmp/worktrees/proj-registered/test-task",
      status: "pending",
      started_at: null,
      completed_at: null,
      created_at: new Date().toISOString(),
      progress: null,
      tmux_session: null,
      base_branch: null,
      merge_strategy: "auto",
    };
    const overrides = {
      externalProjectId: "proj-registered",
      getActiveRuns: vi.fn().mockResolvedValue([]),
      getRunsByStatus: vi.fn().mockResolvedValue([]),
      getRunsForTask: vi.fn().mockResolvedValue([]),
      runOps: {
        createRun: vi.fn().mockResolvedValue(createdRun),
        updateRun: vi.fn().mockResolvedValue(undefined),
        sendMessage: vi.fn().mockResolvedValue(undefined),
        logEvent: vi.fn().mockResolvedValue(undefined),
      },
    };

    const tasks = makeTasks();
    const dispatcher = new Dispatcher(tasks, store, "/tmp/project", null, overrides);
    vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    await dispatcher.dispatch({ dryRun: false, projectId: "proj-registered" });

    expect(store.createRun).not.toHaveBeenCalled();
    expect(store.updateRun).not.toHaveBeenCalled();
    expect(store.sendMessage).not.toHaveBeenCalled();
    expect(store.logEvent).not.toHaveBeenCalled();
    expect(overrides.runOps.createRun).toHaveBeenCalledOnce();
    expect(overrides.runOps.logEvent).toHaveBeenCalledWith(
      "run-registered",
      "proj-registered",
      "dispatch",
      expect.objectContaining({ taskId: "test-task" }),
    );
    expect(overrides.runOps.sendMessage).toHaveBeenCalledWith(
      "run-registered",
      "foreman",
      "foreman",
      "worktree-created",
      expect.any(String),
    );
    expect(overrides.runOps.updateRun).toHaveBeenCalledWith(
      "run-registered",
      expect.objectContaining({
        status: "running",
        session_key: "test-key",
      }),
    );
  });

  it("fails fast when registered dispatch is missing sendMessage before side effects", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockReturnValue({
      name: "default",
      phases: [],
      vcs: { backend: "git" },
    } as unknown as ReturnType<typeof loadWorkflowConfig>);

    const store = makeStore();
    const tasks = makeTasks();
    const dispatcher = new Dispatcher(tasks, store, "/tmp/project", null, {
      externalProjectId: "proj-registered",
      getActiveRuns: vi.fn().mockResolvedValue([]),
      getRunsByStatus: vi.fn().mockResolvedValue([]),
      getRunsForTask: vi.fn().mockResolvedValue([]),
      runOps: {
        createRun: vi.fn().mockResolvedValue(undefined),
        updateRun: vi.fn().mockResolvedValue(undefined),
        logEvent: vi.fn().mockResolvedValue(undefined),
      },
    });

    await expect(dispatcher.dispatch({ dryRun: false, projectId: "proj-registered" })).rejects.toThrow(
      "Registered dispatcher write override missing runOps.sendMessage",
    );

    expect(tasks.ready).not.toHaveBeenCalled();
    expect(store.createRun).not.toHaveBeenCalled();
    expect(store.updateRun).not.toHaveBeenCalled();
    expect(store.logEvent).not.toHaveBeenCalled();
    expect(store.sendMessage).not.toHaveBeenCalled();
    expect(VcsBackendFactory.create).not.toHaveBeenCalled();
  });

  it("passes VcsBackend instance (name='jujutsu') to spawnAgent", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockReturnValue({
      name: "default",
      phases: [],
      vcs: { backend: "jujutsu" },
    } as unknown as ReturnType<typeof loadWorkflowConfig>);

    const jjBackend = makeJujutsuBackend();
    vi.mocked(VcsBackendFactory.create).mockResolvedValue(jjBackend);

    const store = makeStore();
    const tasks = makeTasks();
    const dispatcher = new Dispatcher(tasks, store, "/tmp/project");
    const spawnAgentSpy = vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    await dispatcher.dispatch({ dryRun: false });

    const callArgs = spawnAgentSpy.mock.calls[0];
    const vcsBackendArg = callArgs[7] as VcsBackend | undefined;
    expect(vcsBackendArg).toBeDefined();
    expect(vcsBackendArg?.name).toBe("jujutsu");
  });

  it("passes undefined vcsBackend to spawnAgent when VcsBackend creation fails", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockReturnValue({
      name: "default",
      phases: [],
      vcs: { backend: "git" },
    } as unknown as ReturnType<typeof loadWorkflowConfig>);

    // Simulate failure
    vi.mocked(VcsBackendFactory.create).mockRejectedValue(new Error("VCS backend unavailable"));

    const store = makeStore();
    const tasks = makeTasks();
    const dispatcher = new Dispatcher(tasks, store, "/tmp/project");
    const spawnAgentSpy = vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    await dispatcher.dispatch({ dryRun: false });

    const callArgs = spawnAgentSpy.mock.calls[0];
    const vcsBackendArg = callArgs[7] as VcsBackend | undefined;
    // vcsBackend should be undefined when creation fails
    expect(vcsBackendArg).toBeUndefined();
  });
});

// ── Tests: Non-fatal failure (AC-T-015-3) ────────────────────────────────────

describe("Dispatcher — VcsBackend creation failure is non-fatal (TRD-015, AC-T-015-3)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(VcsBackendFactory.resolveBackend).mockImplementation(
      (config: { backend: "git" | "jujutsu" | "auto" }) => config.backend === "auto" ? "git" : config.backend,
    );
    mockShowFn = vi.fn().mockRejectedValue(new Error("not found"));
  });

  it("dispatch continues and dispatches the task even when VcsBackend creation fails", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockReturnValue({
      name: "default",
      phases: [],
      vcs: { backend: "git" },
    } as unknown as ReturnType<typeof loadWorkflowConfig>);

    vi.mocked(VcsBackendFactory.create).mockRejectedValue(new Error("VCS backend unavailable"));

    const store = makeStore();
    const tasks = makeTasks();
    const dispatcher = new Dispatcher(tasks, store, "/tmp/project");
    vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    // Should NOT throw — VcsBackend creation failure is non-fatal
    const result = await dispatcher.dispatch({ dryRun: false });

    // The task should still be dispatched (not skipped due to VCS failure)
    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].taskId).toBe("test-task");
  });
});

describe("Dispatcher — onError=stop uses registered run failure counts", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(VcsBackendFactory.resolveBackend).mockImplementation(
      (config: { backend: "git" | "jujutsu" | "auto" }) => config.backend === "auto" ? "git" : config.backend,
    );
    mockShowFn = vi.fn().mockRejectedValue(new Error("not found"));
  });

  it("stops dispatching when the registered override reports a recent test-failed run", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockReturnValue({
      name: "default",
      phases: [],
      onError: "stop",
      vcs: { backend: "git" },
    } as unknown as ReturnType<typeof loadWorkflowConfig>);

    const store = makeStore();
    const tasks = makeTasks();
    const overrides = {
      getRecentFailureCount: vi.fn().mockResolvedValue(1),
      getActiveRuns: vi.fn().mockResolvedValue([]),
    };
    const dispatcher = new Dispatcher(tasks, store, "/tmp/project", null, overrides);

    const result = await dispatcher.dispatch({ dryRun: false });

    expect(overrides.getRecentFailureCount).toHaveBeenCalledWith("proj-001", expect.stringContaining("T"));
    expect(result.dispatched).toHaveLength(0);
    expect(mockShowFn).not.toHaveBeenCalled();
  });

  it("honors the --workflow override when evaluating the onError gate", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    // The selected workflow ("quick") stops on error; "default" would continue.
    // If the gate ignores the override and loads "default", dispatch proceeds
    // despite recent failures — that is the bug this test guards against.
    vi.mocked(loadWorkflowConfig).mockImplementation(((name: string) => ({
      name,
      phases: [],
      onError: name === "quick" ? "stop" : "continue",
      vcs: { backend: "git" },
    })) as unknown as typeof loadWorkflowConfig);

    const store = makeStore();
    const tasks = makeTasks();
    const overrides = {
      getRecentFailureCount: vi.fn().mockResolvedValue(1),
      getActiveRuns: vi.fn().mockResolvedValue([]),
    };
    const dispatcher = new Dispatcher(tasks, store, "/tmp/project", null, overrides);
    vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ dryRun: false, workflow: "quick" });

    // The gate must consult the actually-selected workflow, not "default"
    expect(loadWorkflowConfig).toHaveBeenCalledWith("quick", "/tmp/project");
    expect(result.dispatched).toHaveLength(0);
  });

  it("gates on the default workflow when no --workflow override is given", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockImplementation(((name: string) => ({
      name,
      phases: [],
      onError: name === "default" ? "stop" : "continue",
      vcs: { backend: "git" },
    })) as unknown as typeof loadWorkflowConfig);

    const store = makeStore();
    const tasks = makeTasks();
    const overrides = {
      getRecentFailureCount: vi.fn().mockResolvedValue(1),
      getActiveRuns: vi.fn().mockResolvedValue([]),
    };
    const dispatcher = new Dispatcher(tasks, store, "/tmp/project", null, overrides);
    vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    const result = await dispatcher.dispatch({ dryRun: false });

    expect(loadWorkflowConfig).toHaveBeenCalledWith("default", "/tmp/project");
    expect(result.dispatched).toHaveLength(0);
  });
});

// ── Unit Tests: FOREMAN_VCS_BACKEND env var (AC-T-015-2) ─────────────────────

describe("buildWorkerEnv — FOREMAN_VCS_BACKEND propagation via VcsBackend.name", () => {
  /**
   * These tests verify AC-T-015-2 by checking that the worker config
   * written to the temp file contains FOREMAN_VCS_BACKEND when a VcsBackend
   * is present. We test this at the spawnAgent level since buildWorkerEnv is internal.
   */
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(VcsBackendFactory.resolveBackend).mockImplementation(
      (config: { backend: "git" | "jujutsu" | "auto" }) => config.backend === "auto" ? "git" : config.backend,
    );
  });

  it("spawnAgent signature accepts VcsBackend type (not string)", async () => {
    // Compile-time test: verify the spawnAgent method accepts VcsBackend.
    // This test documents that the signature was changed from string to VcsBackend.
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockReturnValue({
      name: "default",
      phases: [],
      vcs: { backend: "git" },
    } as unknown as ReturnType<typeof loadWorkflowConfig>);

    const gitBackend = makeGitBackend();
    vi.mocked(VcsBackendFactory.create).mockResolvedValue(gitBackend);

    const store = makeStore();
    const tasks = makeTasks();
    const dispatcher = new Dispatcher(tasks, store, "/tmp/project");
    const spawnAgentSpy = vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    await dispatcher.dispatch({ dryRun: false });

    // Verify the VcsBackend object (not a string) was passed as 8th arg
    const vcsBackendArg = spawnAgentSpy.mock.calls[0][7];
    expect(typeof vcsBackendArg).not.toBe("string");
    expect(vcsBackendArg).toEqual(expect.objectContaining({ name: "git" }));
  });
});

// ── Tests: WorktreeManager.createWorktree() used for workspace creation (TRD-037) ──

describe("Dispatcher — uses WorktreeManager.createWorktree() for workspace creation (TRD-037)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(VcsBackendFactory.resolveBackend).mockImplementation(
      (config: { backend: "git" | "jujutsu" | "auto" }) => config.backend === "auto" ? "git" : config.backend,
    );
  });

  it("calls WorktreeManager.createWorktree() when dispatching a task (TRD-037)", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockReturnValue({
      name: "default",
      phases: [],
      vcs: { backend: "git" },
    } as unknown as ReturnType<typeof loadWorkflowConfig>);

    vi.mocked(VcsBackendFactory.create).mockResolvedValue(makeGitBackend());

    const store = makeStore();
    const tasks = makeTasks();
    const dispatcher = new Dispatcher(tasks, store, "/tmp/project");
    vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    // Spy on the WorktreeManager module
    const { WorktreeManager } = await import("../../lib/worktree-manager.js");
    const createWorktreeSpy = vi.spyOn(WorktreeManager.prototype, "createWorktree");

    await dispatcher.dispatch({ dryRun: false });

    // WorktreeManager.createWorktree() should be called with projectId, taskId, repoPath, baseBranch
    expect(createWorktreeSpy).toHaveBeenCalledWith({
      projectId: "proj-001",
      taskId: "test-task",
      repoPath: "/tmp/project",
      baseBranch: "main",
    });
  });

  it("uses a registered defaultBranch override as the worktree base when assuming the default branch", async () => {
    const workflowConfig: WorkflowConfig = {
      name: "default",
      phases: [],
      vcs: { backend: "git" },
    };
    vi.mocked(loadWorkflowConfig).mockReturnValue(workflowConfig);
    const backend = makeGitBackend();
    vi.mocked(backend.detectDefaultBranch).mockResolvedValue("main");
    vi.mocked(VcsBackendFactory.create).mockResolvedValue(backend);

    const store = makeStore();
    const tasks = makeTasks();
    const overrides: DispatcherOverridesWithDefaultBranch = { defaultBranch: "release/2026" };
    const dispatcher = new Dispatcher(tasks, store, "/tmp/project", null, overrides);
    const dispatcherWithPrivate = dispatcher as unknown as SpawnAgentHost;
    vi.spyOn(dispatcherWithPrivate, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });
    const createWorktreeSpy = vi.spyOn(WorktreeManager.prototype, "createWorktree");

    await dispatcher.dispatch({ dryRun: false, assumeDefaultBranch: true });

    expect(createWorktreeSpy).toHaveBeenCalledWith(expect.objectContaining({
      projectId: "proj-001",
      taskId: "test-task",
      repoPath: "/tmp/project",
      baseBranch: "release/2026",
    }));
  });
});

describe("Dispatcher — registered override-backed dependency stacking", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(VcsBackendFactory.resolveBackend).mockImplementation(
      (config: { backend: "git" | "jujutsu" | "auto" }) => config.backend === "auto" ? "git" : config.backend,
    );
    mockShowFn = vi.fn().mockResolvedValue({ dependencies: ["dep-a"] });
  });

  it("uses the override-backed run lookup when resolving a stacked base branch", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockReturnValue({
      name: "default",
      phases: [],
      vcs: { backend: "git" },
    } as unknown as ReturnType<typeof loadWorkflowConfig>);

    vi.mocked(VcsBackendFactory.create).mockResolvedValue({
      name: "git",
      createWorkspace: vi.fn().mockResolvedValue({ workspacePath: "/tmp/worktrees/test-task", branchName: "foreman/test-task" }),
      getCurrentBranch: vi.fn().mockResolvedValue("main"),
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
      branchExists: vi.fn().mockResolvedValue(true),
    } as unknown as VcsBackend);

    const store = makeStore();
    store.getRunsForTask = vi.fn().mockResolvedValue([]);
    const overrides = {
      getRunsForTask: vi.fn(async (taskId: string, _projectId: string) => {
        if (taskId === "dep-a") {
          return [{
            id: "run-dep-a",
            project_id: "proj-001",
            task_id: "dep-a",
            agent_type: "claude-code",
            session_key: null,
            worktree_path: "/tmp/worktrees/dep-a",
            status: "completed" as Run["status"],
            started_at: new Date().toISOString(),
            completed_at: new Date().toISOString(),
            created_at: new Date().toISOString(),
            progress: null,
            base_branch: null,
          }] satisfies Run[];
        }
        return [];
      }),
    };

    const tasks = makeTasks({ id: "task-b", title: "Test Task" });
    const dispatcher = new Dispatcher(tasks, store, "/tmp/project", null, overrides);
    vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });
    const { WorktreeManager } = await import("../../lib/worktree-manager.js");
    const createWorktreeSpy = vi.spyOn(WorktreeManager.prototype, "createWorktree");

    await dispatcher.dispatch({ dryRun: false });

    expect(overrides.getRunsForTask).not.toHaveBeenCalledWith("dep-a", "proj-001");
    expect(createWorktreeSpy).toHaveBeenCalledWith(expect.objectContaining({ baseBranch: "main" }));
  });
});
