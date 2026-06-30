/**
 * Tests for `foreman run task` — direct workflow execution for a specific task.
 *
 * @module src/cli/__tests__/run-task.test
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { Command } from "commander";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";

const {
  mockCreateTaskClient,
  MockForemanStore,
  mockPostgresStoreForProject,
  mockVcsCreate,
  mockWorktreeManager,
  mockSpawnWorkerProcess,
  mockWatchRunsInk,
  mockListRegisteredProjects,
  mockResolveRepoRootProjectPath,
} = vi.hoisted(() => {
  const taskClient = {
    show: vi.fn(),
    update: vi.fn(),
  };
  const mockCreateTaskClient = vi.fn(async () => ({
    taskClient,
    backendType: "native" as const,
  }));

  const MockForemanStore = vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    this.getProjectByPath = vi.fn().mockReturnValue({ id: "proj-1", path: "/test/project" });
    this.getRunsForSeed = vi.fn().mockResolvedValue([]);
    this.createRun = vi.fn().mockReturnValue({ id: "local-run-1" });
    this.getRun = vi.fn().mockResolvedValue(null);
    this.close = vi.fn();
  });
  (MockForemanStore as any).forProject = vi.fn(() => new MockForemanStore());

  const mockPostgresStoreForProject = vi.fn(() => ({
    getRunsForSeed: vi.fn().mockResolvedValue([]),
    getRun: vi.fn().mockResolvedValue(null),
    close: vi.fn(),
  }));

  const mockVcsCreate = vi.fn().mockResolvedValue({
    name: "git",
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
  });

  const mockWorktreeManager = vi.fn(function MockWorktreeManagerImpl(this: Record<string, unknown>) {
    this.createWorktree = vi.fn().mockResolvedValue({
      path: "/tmp/worktrees/proj-1/task-1",
      branchName: "foreman/task-1",
      created: true,
      exists: false,
    });
  });

  const mockSpawnWorkerProcess = vi.fn().mockResolvedValue({ pid: 12345 });
  const mockWatchRunsInk = vi.fn().mockResolvedValue({ detached: false });
  const mockListRegisteredProjects = vi.fn().mockResolvedValue([]);
  const mockResolveRepoRootProjectPath = vi.fn().mockResolvedValue("/test/project");

  return {
    mockCreateTaskClient,
    MockForemanStore,
    mockPostgresStoreForProject,
    mockVcsCreate,
    mockWorktreeManager,
    mockSpawnWorkerProcess,
    mockWatchRunsInk,
    mockListRegisteredProjects,
    mockResolveRepoRootProjectPath,
  };
});

vi.mock("../../lib/task-client-factory.js", () => ({
  createTaskClient: mockCreateTaskClient,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: MockForemanStore,
}));

vi.mock("../../lib/postgres-store.js", () => ({
  PostgresStore: { forProject: mockPostgresStoreForProject },
}));

vi.mock("../../lib/db/postgres-adapter.js", () => ({
  PostgresAdapter: vi.fn().mockImplementation(() => ({
    createPipelineRun: vi.fn(),
    updateTask: vi.fn(),
  })),
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: (...args: unknown[]) => mockVcsCreate(...args),
    resolveBackend: vi.fn().mockReturnValue("git"),
  },
}));

vi.mock("../../lib/worktree-manager.js", () => ({
  WorktreeManager: mockWorktreeManager,
}));

vi.mock("../../lib/setup.js", () => ({
  installDependencies: vi.fn().mockResolvedValue(undefined),
  runSetupWithCache: vi.fn().mockResolvedValue(undefined),
  runWorkspaceHook: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("../../orchestrator/dispatcher.js", () => ({
  buildWorkerEnv: vi.fn().mockReturnValue({ FOREMAN_TEST: "1" }),
  spawnWorkerProcess: (...args: unknown[]) => mockSpawnWorkerProcess(...args),
}));

vi.mock("../watch-ui.js", () => ({
  watchRunsInk: (...args: unknown[]) => mockWatchRunsInk(...args),
}));

vi.mock("../../orchestrator/notification-server.js", () => ({
  NotificationServer: vi.fn(function (this: Record<string, unknown>) {
    this.start = vi.fn().mockResolvedValue(undefined);
    this.stop = vi.fn().mockResolvedValue(undefined);
    this.url = "http://127.0.0.1:12345";
  }),
}));

vi.mock("../../orchestrator/notification-bus.js", () => ({
  notificationBus: { on: vi.fn(), emit: vi.fn() },
}));

vi.mock("../../orchestrator/auto-merge.js", () => ({
  autoMerge: vi.fn().mockResolvedValue({ merged: 0, conflicts: 0, failed: 0 }),
}));

vi.mock("../commands/project-task-support.js", () => ({
  resolveRepoRootProjectPath: mockResolveRepoRootProjectPath,
  listRegisteredProjects: mockListRegisteredProjects,
}));

import { runTaskCommand, runTaskAction } from "../commands/run-task.js";

const task = {
  id: "task-123",
  title: "Direct task run",
  status: "closed",
  type: "feature",
  priority: 1,
  description: "Task body",
  labels: ["workflow:task"],
};

describe("run task command", () => {
  let testProjectPath: string;
  let testForemanHome: string;

  beforeEach(() => {
    vi.clearAllMocks();

    testProjectPath = join(tmpdir(), `foreman-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    testForemanHome = join(tmpdir(), `foreman-home-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    mkdirSync(join(testProjectPath, ".foreman"), { recursive: true });
    mkdirSync(join(testForemanHome, "workflows"), { recursive: true });
    writeFileSync(join(testProjectPath, ".foreman", "config.yaml"), "vcs:\n  backend: auto\n");
    process.env.FOREMAN_HOME = testForemanHome;

    const workflowDir = join(testForemanHome, "workflows");
    writeFileSync(join(workflowDir, "default.yaml"), `
name: default
phases:
  - name: developer
    prompt: developer.md
    models:
      default: MiniMax
    maxTurns: 50
`);

    mockResolveRepoRootProjectPath.mockResolvedValue(testProjectPath);
    mockCreateTaskClient.mockImplementation(async () => ({
      taskClient: {
        show: vi.fn().mockResolvedValue(task),
        update: vi.fn().mockResolvedValue(undefined),
      },
      backendType: "native" as const,
    }));
  });

  afterEach(() => {
    delete process.env.FOREMAN_HOME;
    rmSync(testProjectPath, { recursive: true, force: true });
    rmSync(testForemanHome, { recursive: true, force: true });
  });

  describe("command structure", () => {
    it("should export runTaskCommand", () => {
      expect(runTaskCommand).toBeDefined();
      expect(runTaskCommand.name()).toBe("task");
    });

    it("should require task-id and workflow-path arguments", () => {
      const program = new Command();
      program.exitOverride();
      program.configureOutput({ writeErr: () => undefined });
      program.addCommand(runTaskCommand.copyInheritedSettings(program));

      expect(() => program.parse(["node", "test", "task"])).toThrow();
    });
  });

  describe("direct execution", () => {
    it("runs a closed task by explicit workflow without state gating", async () => {
      const exitCode = await runTaskAction("task-123", "default", {
        projectPath: testProjectPath,
        watch: false,
      });

      expect(exitCode).toBe(0);
      const client = (await mockCreateTaskClient.mock.results[0].value).taskClient;
      expect(client.update).toHaveBeenCalledWith("task-123", { status: "in-progress" });
      expect(mockSpawnWorkerProcess).toHaveBeenCalledWith(expect.objectContaining({
        runId: "local-run-1",
        seedId: "task-123",
        seedTitle: "Direct task run",
        seedType: "feature",
        seedPriority: 1,
        worktreePath: "/tmp/worktrees/proj-1/task-1",
        pipeline: true,
        workflowName: "default",
        workflowPath: "default",
      }));
    });

    it("returns an error when the task does not exist", async () => {
      mockCreateTaskClient.mockImplementationOnce(async () => ({
        taskClient: {
          show: vi.fn().mockResolvedValue(undefined),
          update: vi.fn(),
        },
        backendType: "native" as const,
      }));

      const exitCode = await runTaskAction("missing", "default", {
        projectPath: testProjectPath,
        watch: false,
      });

      expect(exitCode).toBe(1);
      expect(mockSpawnWorkerProcess).not.toHaveBeenCalled();
    });

    it("returns an error when the workflow cannot be loaded", async () => {
      const exitCode = await runTaskAction("task-123", "missing-workflow", {
        projectPath: testProjectPath,
        watch: false,
      });

      expect(exitCode).toBe(1);
      expect(mockSpawnWorkerProcess).not.toHaveBeenCalled();
    });

    it("fails closed when worktree lock lookup fails", async () => {
      (MockForemanStore as unknown as { forProject: ReturnType<typeof vi.fn> }).forProject.mockReturnValueOnce({
        getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1", path: testProjectPath }),
        getRunsForSeed: vi.fn().mockRejectedValue(new Error("store unavailable")),
        close: vi.fn(),
      });

      const exitCode = await runTaskAction("task-123", "default", {
        projectPath: testProjectPath,
        watch: false,
      });

      expect(exitCode).toBe(1);
      expect(mockWorktreeManager).not.toHaveBeenCalled();
      expect(mockSpawnWorkerProcess).not.toHaveBeenCalled();
    });

    it("warns about deprecated skip flags and does not forward them to the worker", async () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
      try {
        const exitCode = await runTaskAction("task-123", "default", {
          projectPath: testProjectPath,
          watch: false,
          skipExplore: true,
          skipReview: true,
        });

        expect(exitCode).toBe(0);
        // `foreman run task` takes the workflow as a positional argument, so the
        // warning suggests passing `quick` as the workflow argument (not a flag).
        expect(
          warnSpy.mock.calls.some((call) =>
            String(call[0]).includes("pass `quick`") &&
            String(call[0]).includes("workflow argument"),
          ),
        ).toBe(true);
        expect(
          warnSpy.mock.calls.some((call) => String(call[0]).includes("--workflow quick")),
        ).toBe(false);

        const spawnArg = mockSpawnWorkerProcess.mock.calls[0][0] as Record<string, unknown>;
        expect("skipExplore" in spawnArg).toBe(false);
        expect("skipReview" in spawnArg).toBe(false);
      } finally {
        warnSpy.mockRestore();
      }
    });

    it("blocks when an active run already owns the task worktree", async () => {
      (MockForemanStore as unknown as { forProject: ReturnType<typeof vi.fn> }).forProject.mockReturnValueOnce({
        getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1", path: testProjectPath }),
        getRunsForSeed: vi.fn().mockResolvedValue([{ id: "run-active", status: "running" }]),
        close: vi.fn(),
      });

      const exitCode = await runTaskAction("task-123", "default", {
        projectPath: testProjectPath,
        watch: false,
      });

      expect(exitCode).toBe(1);
      expect(mockWorktreeManager).not.toHaveBeenCalled();
      expect(mockSpawnWorkerProcess).not.toHaveBeenCalled();
    });

    it("returns early in dry-run mode without creating a run or spawning a worker", async () => {
      const exitCode = await runTaskAction("task-123", "default", {
        projectPath: testProjectPath,
        dryRun: true,
      });

      expect(exitCode).toBe(0);
      expect(mockSpawnWorkerProcess).not.toHaveBeenCalled();
      expect(mockWatchRunsInk).not.toHaveBeenCalled();
      const storeInstance = (MockForemanStore as unknown as { forProject: ReturnType<typeof vi.fn> }).forProject.mock.results[0]?.value as { createRun?: ReturnType<typeof vi.fn> };
      expect(storeInstance?.createRun).not.toHaveBeenCalled();
    });

    it("skips watch mode when watch=false", async () => {
      const exitCode = await runTaskAction("task-123", "default", {
        projectPath: testProjectPath,
        watch: false,
      });

      expect(exitCode).toBe(0);
      expect(mockSpawnWorkerProcess).toHaveBeenCalledTimes(1);
      expect(mockWatchRunsInk).not.toHaveBeenCalled();
    });

    it("shows detach messaging when watch mode detaches", async () => {
      mockWatchRunsInk.mockResolvedValueOnce({ detached: true });
      const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
      try {
        const exitCode = await runTaskAction("task-123", "default", {
          projectPath: testProjectPath,
          watch: true,
        });

        expect(exitCode).toBe(0);
        expect(mockWatchRunsInk).toHaveBeenCalledTimes(1);
        const rendered = logSpy.mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
        expect(rendered).toContain("Detached — worker continues in background");
        expect(rendered).toContain("foreman status");
      } finally {
        logSpy.mockRestore();
      }
    });

    it("treats dependency installation failure as non-fatal when no workflow setup is defined", async () => {
      const { installDependencies } = await import("../../lib/setup.js");
      vi.mocked(installDependencies).mockRejectedValueOnce(new Error("npm install failed"));
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
      try {
        const exitCode = await runTaskAction("task-123", "default", {
          projectPath: testProjectPath,
          watch: false,
        });

        expect(exitCode).toBe(0);
        expect(mockSpawnWorkerProcess).toHaveBeenCalledTimes(1);
        expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("Dependency installation failed"));
      } finally {
        warnSpy.mockRestore();
      }
    });

    it("returns an error when worktree creation fails", async () => {
      mockWorktreeManager.mockImplementationOnce(function MockWorktreeManagerImpl(this: Record<string, unknown>) {
        this.createWorktree = vi.fn().mockRejectedValue(new Error("git failed"));
      });

      const exitCode = await runTaskAction("task-123", "default", {
        projectPath: testProjectPath,
        watch: false,
      });

      expect(exitCode).toBe(1);
      expect(mockSpawnWorkerProcess).not.toHaveBeenCalled();
    });

    it("returns an error when workflow setup fails", async () => {
      writeFileSync(join(testForemanHome, "workflows", "setup.yaml"), `
name: setup
setup:
  - npm ci
phases:
  - name: developer
    prompt: developer.md
    models:
      default: MiniMax
`);
      const { runSetupWithCache } = await import("../../lib/setup.js");
      vi.mocked(runSetupWithCache).mockRejectedValueOnce(new Error("setup exploded"));

      const exitCode = await runTaskAction("task-123", "setup", {
        projectPath: testProjectPath,
        watch: false,
      });

      expect(exitCode).toBe(1);
      expect(mockSpawnWorkerProcess).not.toHaveBeenCalled();
    });

    it("returns an error when local run record creation fails", async () => {
      (MockForemanStore as unknown as { forProject: ReturnType<typeof vi.fn> }).forProject.mockReturnValueOnce({
        getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1", path: testProjectPath }),
        getRunsForSeed: vi.fn().mockResolvedValue([]),
        createRun: vi.fn().mockImplementation(() => { throw new Error("create run failed"); }),
        close: vi.fn(),
      });

      const exitCode = await runTaskAction("task-123", "default", {
        projectPath: testProjectPath,
        watch: false,
      });

      expect(exitCode).toBe(1);
      expect(mockSpawnWorkerProcess).not.toHaveBeenCalled();
    });

    it("continues when updating the task to in-progress fails", async () => {
      mockCreateTaskClient.mockImplementationOnce(async () => ({
        taskClient: {
          show: vi.fn().mockResolvedValue(task),
          update: vi.fn().mockRejectedValue(new Error("update failed")),
        },
        backendType: "native" as const,
      }));

      const exitCode = await runTaskAction("task-123", "default", {
        projectPath: testProjectPath,
        watch: false,
      });

      expect(exitCode).toBe(0);
      expect(mockSpawnWorkerProcess).toHaveBeenCalledTimes(1);
    });

    it("continues when notification server startup fails", async () => {
      vi.doMock("../../orchestrator/notification-server.js", () => ({
        NotificationServer: vi.fn(function (this: Record<string, unknown>) {
          this.start = vi.fn().mockRejectedValue(new Error("notify offline"));
          this.stop = vi.fn().mockResolvedValue(undefined);
          this.url = undefined;
        }),
      }));
      vi.resetModules();
      const { runTaskAction: runTaskActionFresh } = await import("../commands/run-task.js");

      const exitCode = await runTaskActionFresh("task-123", "default", {
        projectPath: testProjectPath,
        watch: false,
      });

      expect(exitCode).toBe(0);
      expect(mockSpawnWorkerProcess).toHaveBeenCalledTimes(1);
    });

    it("returns an error when worker spawn fails", async () => {
      mockSpawnWorkerProcess.mockRejectedValueOnce(new Error("spawn exploded"));

      const exitCode = await runTaskAction("task-123", "default", {
        projectPath: testProjectPath,
        watch: false,
      });

      expect(exitCode).toBe(1);
    });

    it("triggers local auto-merge after a watched completed run", async () => {
      const { autoMerge } = await import("../../orchestrator/auto-merge.js");
      mockWatchRunsInk.mockResolvedValueOnce({ detached: false });
      (MockForemanStore as unknown as { forProject: ReturnType<typeof vi.fn> }).forProject.mockReturnValueOnce({
        getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1", path: testProjectPath }),
        getRunsForSeed: vi.fn().mockResolvedValue([]),
        createRun: vi.fn().mockReturnValue({ id: "local-run-1" }),
        getRun: vi.fn().mockResolvedValue({ id: "local-run-1", status: "completed" }),
        close: vi.fn(),
      });

      const exitCode = await runTaskAction("task-123", "default", {
        projectPath: testProjectPath,
        watch: true,
      });

      expect(exitCode).toBe(0);
      expect(vi.mocked(autoMerge)).toHaveBeenCalledWith(expect.objectContaining({
        projectPath: testProjectPath,
        taskClient: expect.any(Object),
      }));
    });
  });
});
