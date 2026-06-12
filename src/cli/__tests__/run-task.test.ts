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

// Use vi.hoisted to define mocks that are used in vi.mock
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
  const mockCreateTaskClient = vi.fn(async () => ({
    taskClient: {
      show: vi.fn(),
      update: vi.fn(),
    },
    backendType: "native" as const,
  }));

  const MockForemanStore = vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    this.getProjectByPath = vi.fn().mockReturnValue({ id: "proj-1", path: "/test" });
    this.getRunsForSeed = vi.fn().mockResolvedValue([]);
    this.createRun = vi.fn();
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

  const mockWorktreeManager = vi.fn().mockImplementation(() => ({
    createWorktree: vi.fn().mockResolvedValue({
      path: "/tmp/worktrees/proj-1/task-1",
      branchName: "foreman/task-1",
      created: true,
      exists: false,
    }),
  }));

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

// Mock the modules that interact with external systems
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

vi.mock("../../lib/workspace-paths.js", () => ({
  getWorkspacePath: vi.fn().mockReturnValue("/tmp/worktrees/proj-1/task-1"),
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
  Dispatcher: vi.fn(),
  buildWorkerEnv: vi.fn().mockReturnValue({}),
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

// Import the module under test
import { runTaskCommand, runTaskAction } from "../commands/run-task.js";

describe("run task command", () => {
  let testProjectPath: string;

  beforeEach(() => {
    vi.clearAllMocks();

    testProjectPath = join(tmpdir(), `foreman-test-${Date.now()}`);
    mkdirSync(join(testProjectPath, ".foreman"), { recursive: true });
    writeFileSync(join(testProjectPath, ".foreman", "config.yaml"), "project:\n  id: proj-1\n  path: /test\n");

    // Create a minimal workflow file
    const workflowDir = join(testProjectPath, ".foreman", "workflows");
    mkdirSync(workflowDir, { recursive: true });
    writeFileSync(join(workflowDir, "default.yaml"), `
name: default
phases:
  - name: developer
    prompt: developer.md
    model: sonnet
    maxTurns: 50
`);
  });

  afterEach(() => {
    rmSync(testProjectPath, { recursive: true, force: true });
  });

  describe("command structure", () => {
    it("should export runTaskCommand", () => {
      expect(runTaskCommand).toBeDefined();
      expect(runTaskCommand.name()).toBe("task");
    });

    it("should be added as subcommand to run command", () => {
      const program = new Command();
      program.addCommand(runTaskCommand);

      // Should parse without error
      expect(() => program.parse(["node", "test", "task", "task-123", "default"])).not.toThrow();
    });
  });

  describe("argument parsing", () => {
    it("should require task-id and workflow-path arguments", () => {
      const program = new Command();
      program.addCommand(runTaskCommand);

      // Should fail without required arguments
      expect(() => program.parse(["node", "test", "task"])).toThrow();
    });

    it("should accept task-id and workflow-path", () => {
      const program = new Command();
      program.addCommand(runTaskCommand);

      // Should parse without error
      expect(() => program.parse(["node", "test", "task", "task-123", "default"])).not.toThrow();
    });
  });

  describe("options", () => {
    it("should accept --model option", () => {
      const program = new Command();
      program.addCommand(runTaskCommand);

      expect(() => program.parse(["node", "test", "task", "task-123", "default", "--model", "haiku"])).not.toThrow();
    });

    it("should accept --skip-explore option", () => {
      const program = new Command();
      program.addCommand(runTaskCommand);

      expect(() => program.parse(["node", "test", "task", "task-123", "default", "--skip-explore"])).not.toThrow();
    });

    it("should accept --skip-review option", () => {
      const program = new Command();
      program.addCommand(runTaskCommand);

      expect(() => program.parse(["node", "test", "task", "task-123", "default", "--skip-review"])).not.toThrow();
    });

    it("should accept --dry-run option", () => {
      const program = new Command();
      program.addCommand(runTaskCommand);

      expect(() => program.parse(["node", "test", "task", "task-123", "default", "--dry-run"])).not.toThrow();
    });

    it("should accept --no-watch option", () => {
      const program = new Command();
      program.addCommand(runTaskCommand);

      expect(() => program.parse(["node", "test", "task", "task-123", "default", "--no-watch"])).not.toThrow();
    });

    it("should accept --target-branch option", () => {
      const program = new Command();
      program.addCommand(runTaskCommand);

      expect(() => program.parse(["node", "test", "task", "task-123", "default", "--target-branch", "feature-x"])).not.toThrow();
    });

    it("should accept --project option", () => {
      const program = new Command();
      program.addCommand(runTaskCommand);

      expect(() => program.parse(["node", "test", "task", "task-123", "default", "--project", "myproject"])).not.toThrow();
    });

    it("should accept --project-path option", () => {
      const program = new Command();
      program.addCommand(runTaskCommand);

      expect(() => program.parse(["node", "test", "task", "task-123", "default", "--project-path", "/path/to/project"])).not.toThrow();
    });
  });
});