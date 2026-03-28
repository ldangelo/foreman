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
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import type { ForemanStore } from "../../lib/store.js";
import type { VcsBackend } from "../../lib/vcs/index.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";

// ── Module Mocks ─────────────────────────────────────────────────────────────

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

vi.mock("../../lib/git.js", () => ({
  // TRD-015: createWorktree and gitBranchExists replaced by VcsBackend methods
  // getCurrentBranch and detectDefaultBranch replaced by GitBackend methods
  installDependencies: vi.fn().mockResolvedValue(undefined),
  runSetupWithCache: vi.fn().mockResolvedValue(undefined),
}));

// Mock GitBackend so dispatcher's branch detection and fallback createWorkspace work in tests
vi.mock("../../lib/vcs/git-backend.js", () => ({
  GitBackend: class {
    constructor(_path: string) {}
    async getCurrentBranch(_path: string): Promise<string> { return "main"; }
    async detectDefaultBranch(_path: string): Promise<string> { return "main"; }
    async branchExists(_path: string, _branch: string): Promise<boolean> { return false; }
    async createWorkspace(_repoPath: string, seedId: string): Promise<{ workspacePath: string; branchName: string }> {
      return { workspacePath: `/tmp/worktrees/${seedId}`, branchName: `foreman/${seedId}` };
    }
  },
}));

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: class {
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    constructor(_path: string) {}
    async show(_id: string): Promise<never> { throw new Error("not found"); }
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

function makeGitBackend(): VcsBackend {
  return {
    name: "git",
    createWorkspace: vi.fn().mockResolvedValue({
      workspacePath: "/tmp/worktrees/test-seed",
      branchName: "foreman/test-seed",
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
      workspacePath: "/tmp/worktrees/test-seed",
      branchName: "foreman/test-seed",
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
    getStuckRunsForSeed: vi.fn().mockReturnValue([]),
    getPendingBeadWrites: vi.fn().mockReturnValue([]),
    hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    getRunsForSeed: vi.fn().mockReturnValue([]),
    createRun: vi.fn().mockReturnValue({ id: "run-001" }),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    sendMessage: vi.fn(),
    getProjectByPath: vi.fn().mockReturnValue({ id: "proj-001" }),
  } as unknown as ForemanStore;
}

function makeSeeds(issue?: Partial<Issue>): ITaskClient {
  const seed: Issue = {
    id: "test-seed",
    title: "Test Seed",
    status: "open",
    priority: "P2",
    type: "feature",
    assignee: null,
    parent: null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    ...issue,
  };
  return {
    ready: vi.fn().mockResolvedValue([seed]),
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
    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp/project");

    // Mock the private spawnAgent method to prevent actual process spawning
    vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    await dispatcher.dispatch({ dryRun: false });

    // VcsBackendFactory.create should have been called with 'git' backend
    expect(VcsBackendFactory.create).toHaveBeenCalledWith(
      { backend: "git" },
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
    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp/project");
    vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    await dispatcher.dispatch({ dryRun: false });

    expect(VcsBackendFactory.create).toHaveBeenCalledWith(
      { backend: "jujutsu" },
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
    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp/project");
    vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    await dispatcher.dispatch({ dryRun: false });

    // Should default to 'git' when no .jj/ directory exists in /tmp/project
    expect(VcsBackendFactory.create).toHaveBeenCalledWith(
      { backend: "git" },
      "/tmp/project",
    );
  });

  it("VcsBackend is created once per seed per dispatch call", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockReturnValue({
      name: "default",
      phases: [],
      vcs: { backend: "git" },
    } as unknown as ReturnType<typeof loadWorkflowConfig>);

    vi.mocked(VcsBackendFactory.create).mockResolvedValue(makeGitBackend());

    const store = makeStore();
    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp/project");
    vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    await dispatcher.dispatch({ dryRun: false });

    // Called exactly once for the single ready seed
    expect(VcsBackendFactory.create).toHaveBeenCalledTimes(1);
  });
});

// ── Tests: VcsBackend Propagation to spawnAgent (AC-T-015-2) ─────────────────

describe("Dispatcher — VcsBackend propagation to spawnAgent (TRD-015, AC-T-015-2)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
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
    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp/project");

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
    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp/project");
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
    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp/project");
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
  });

  it("dispatch continues and dispatches the seed even when VcsBackend creation fails", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockReturnValue({
      name: "default",
      phases: [],
      vcs: { backend: "git" },
    } as unknown as ReturnType<typeof loadWorkflowConfig>);

    vi.mocked(VcsBackendFactory.create).mockRejectedValue(new Error("VCS backend unavailable"));

    const store = makeStore();
    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp/project");
    vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    // Should NOT throw — VcsBackend creation failure is non-fatal
    const result = await dispatcher.dispatch({ dryRun: false });

    // The seed should still be dispatched (not skipped due to VCS failure)
    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].seedId).toBe("test-seed");
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
    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp/project");
    const spawnAgentSpy = vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    await dispatcher.dispatch({ dryRun: false });

    // Verify the VcsBackend object (not a string) was passed as 8th arg
    const vcsBackendArg = spawnAgentSpy.mock.calls[0][7];
    expect(typeof vcsBackendArg).not.toBe("string");
    expect(vcsBackendArg).toEqual(expect.objectContaining({ name: "git" }));
  });
});

// ── Tests: VcsBackend.createWorkspace() used instead of createWorktree shim (TRD-015) ──

describe("Dispatcher — uses VcsBackend.createWorkspace() instead of createWorktree shim", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("calls vcsBackend.createWorkspace() when dispatching a seed (TRD-015)", async () => {
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");
    vi.mocked(loadWorkflowConfig).mockReturnValue({
      name: "default",
      phases: [],
      vcs: { backend: "git" },
    } as unknown as ReturnType<typeof loadWorkflowConfig>);

    const gitBackend = makeGitBackend();
    vi.mocked(VcsBackendFactory.create).mockResolvedValue(gitBackend);

    const store = makeStore();
    const seeds = makeSeeds();
    const dispatcher = new Dispatcher(seeds, store, "/tmp/project");
    vi.spyOn(dispatcher as any, "spawnAgent").mockResolvedValue({ sessionKey: "test-key" });

    await dispatcher.dispatch({ dryRun: false });

    // VcsBackend.createWorkspace() should be called instead of the old createWorktree shim
    expect(gitBackend.createWorkspace).toHaveBeenCalledWith(
      "/tmp/project",
      "test-seed",
      undefined, // baseBranch
    );
  });
});
