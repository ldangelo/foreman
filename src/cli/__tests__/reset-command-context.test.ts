import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Mock } from "vitest";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

interface MockResetClient {
  getTask: Mock;
  listRuns: Mock;
  sendCommand: Mock;
  schedulerTick: Mock;
}

interface ResetRunFixture {
  id: string;
  run_id: string;
  project_id: string;
  task_id: string;
  status: string;
  worktree_path: string;
  created_at: string;
  started_at: string | null;
  completed_at: string | null;
  agent_type: string;
  session_key: string | null;
  progress: null;
  pr_url?: string;
  pr_state?: string;
}

const {
  mockResolveProjectContext,
  mockGetTask,
  mockListRuns,
  mockSendCommand,
  mockSchedulerTick,
  mockExecFile,
  mockExecFileAsync,
  mockRunStore,
  mockLocalStore,
  mockMergeQueueList,
  mockMergeQueueRemove,
  mockRemoveWorkspace,
  mockDeleteBranch,
  mockDeleteRemoteBranch,
  mockBranchExistsOnRemote,
  mockHomedir,
} = vi.hoisted(() => {
  const mockResolveProjectContext = vi.fn();
  const mockGetTask = vi.fn();
  const mockListRuns = vi.fn();
  const mockSendCommand = vi.fn();
  const mockSchedulerTick = vi.fn();
  const mockHomedir = vi.fn();
  const mockExecFileAsync = vi.fn(async () => ({ stdout: "", stderr: "" }));
  const mockExecFile = vi.fn((...args: unknown[]) => {
    const maybeCallback = args[args.length - 1];
    if (typeof maybeCallback === "function") {
      maybeCallback(null, "", "");
    }
    return {};
  });
  const promisifyCustom = Symbol.for("nodejs.util.promisify.custom");
  Object.assign(mockExecFile, {
    [promisifyCustom]: mockExecFileAsync,
  });
  const mockRunStore = {
    close: vi.fn(),
    getRun: vi.fn(),
    getRunsForTask: vi.fn(),
    getRunsByStatus: vi.fn(),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    updateTaskStatus: vi.fn(),
  };
  const mockLocalStore = {
    getDb: vi.fn(() => ({})),
    close: vi.fn(),
  };
  const mockMergeQueueList = vi.fn();
  const mockMergeQueueRemove = vi.fn();
  const mockRemoveWorkspace = vi.fn();
  const mockDeleteBranch = vi.fn();
  const mockDeleteRemoteBranch = vi.fn();
  const mockBranchExistsOnRemote = vi.fn();

  return {
    mockResolveProjectContext,
    mockGetTask,
    mockListRuns,
    mockSendCommand,
    mockSchedulerTick,
    mockExecFile,
    mockExecFileAsync,
    mockRunStore,
    mockLocalStore,
    mockMergeQueueList,
    mockMergeQueueRemove,
    mockRemoveWorkspace,
    mockDeleteBranch,
    mockDeleteRemoteBranch,
    mockBranchExistsOnRemote,
    mockHomedir,
  };
});

vi.mock("node:child_process", () => ({
  execFile: mockExecFile,
}));
vi.mock("node:os", () => ({
  homedir: mockHomedir,
}));


vi.mock("../commands/project-context.js", () => ({
  resolveProjectContext: mockResolveProjectContext,
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn(function MockElixirServerManager(this: { ensureRunning: Mock }) {
    this.ensureRunning = vi.fn().mockResolvedValue({ url: "http://127.0.0.1:4766", pid: 123 });
  }),
}));

vi.mock("../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: vi.fn(function MockElixirServerClient(this: MockResetClient) {
    this.getTask = mockGetTask;
    this.listRuns = mockListRuns;
    this.sendCommand = mockSendCommand;
    this.schedulerTick = mockSchedulerTick;
  }),
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: { forProject: vi.fn(() => mockLocalStore) },
}));

vi.mock("../commands/elixir-cli-store.js", () => ({
  ElixirCliStore: { forProject: vi.fn(() => mockRunStore) },
}));

vi.mock("../../orchestrator/merge-queue.js", () => ({
  MergeQueue: class MockMergeQueue {
    list = mockMergeQueueList;
    remove = mockMergeQueueRemove;
  },
}));

vi.mock("../commands/elixir-merge-queue.js", () => ({
  ElixirMergeQueue: class MockElixirMergeQueue {
    list = mockMergeQueueList;
    remove = mockMergeQueueRemove;
  },
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: vi.fn(async () => ({
      removeWorkspace: mockRemoveWorkspace,
      deleteBranch: mockDeleteBranch,
      deleteRemoteBranch: mockDeleteRemoteBranch,
      branchExistsOnRemote: mockBranchExistsOnRemote,
    })),
  },
}));

vi.mock("../../lib/archive-reports.js", () => ({
  archiveWorktreeReports: vi.fn(async () => {}),
}));

import { resetAction } from "../commands/reset.js";

const projectPath = "/tmp/foreman-reset-project";
const project = {
  id: "proj-1",
  name: "Reset Project",
  path: projectPath,
  defaultBranch: "main",
  status: "active",
};

function makeRun(id: string, status: string, worktreePath = "/tmp/wt/task-1"): ResetRunFixture {
  return {
    id,
    run_id: id,
    project_id: "proj-1",
    task_id: "task-1",
    status,
    worktree_path: worktreePath,
    created_at: "2026-07-08T00:00:00.000Z",
    started_at: "2026-07-08T00:01:00.000Z",
    completed_at: null,
    agent_type: "developer",
    session_key: null,
    progress: null,
  };
}

function createRunArtifacts(foremanHome: string, runs: ResetRunFixture[]): void {
  const logsDir = join(foremanHome, ".foreman", "logs");
  mkdirSync(logsDir, { recursive: true });
  writeFileSync(join(logsDir, "unrelated.log"), "keep\n");

  for (const run of runs) {
    writeFileSync(join(logsDir, `${run.id}.log`), `log ${run.id}\n`);
    writeFileSync(join(logsDir, `${run.id}.err`), `err ${run.id}\n`);
    writeFileSync(join(logsDir, `${run.id}.out`), `out ${run.id}\n`);

    const reportDir = join(foremanHome, "reports", run.project_id, run.task_id, run.id);
    mkdirSync(reportDir, { recursive: true });
    writeFileSync(join(reportDir, "DEVELOPER_REPORT.md"), `# ${run.id}\n`);
  }
}

function expectRunArtifactsPresent(foremanHome: string, run: ResetRunFixture, present: boolean): void {
  expect(existsSync(join(foremanHome, ".foreman", "logs", `${run.id}.log`))).toBe(present);
  expect(existsSync(join(foremanHome, ".foreman", "logs", `${run.id}.err`))).toBe(present);
  expect(existsSync(join(foremanHome, ".foreman", "logs", `${run.id}.out`))).toBe(present);
  expect(existsSync(join(foremanHome, "reports", run.project_id, run.task_id, run.id))).toBe(present);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

interface SendCommandMatch {
  command: Record<string, unknown>;
  payload: Record<string, unknown>;
  index: number;
}

function findSendCommandMatch(
  predicate: (command: Record<string, unknown>, payload: Record<string, unknown>) => boolean,
): SendCommandMatch | undefined {
  return mockSendCommand.mock.calls.reduce<SendCommandMatch | undefined>((match, call, index) => {
    if (match) return match;
    const command = call[0];
    if (!isRecord(command)) return undefined;
    const payload = command.payload;
    if (!isRecord(payload)) return undefined;
    return predicate(command, payload) ? { command, payload, index } : undefined;
  }, undefined);
}

function findReadyTaskUpdateCommand(): SendCommandMatch | undefined {
  return findSendCommandMatch(
    (command, payload) =>
      command.command_type === "task.update" &&
      payload.project_id === "proj-1" &&
      payload.task_id === "task-1" &&
      payload.status === "ready",
  );
}

function findRunFailCommand(runId: string): SendCommandMatch | undefined {
  return findSendCommandMatch(
    (command, payload) =>
      command.command_type === "run.fail" &&
      payload.project_id === "proj-1" &&
      payload.task_id === "task-1" &&
      payload.run_id === runId,
  );
}

describe("resetAction", () => {
  let foremanHome: string;
  let previousForemanHome: string | undefined;
  let runs: ResetRunFixture[];

  beforeEach(() => {
    vi.clearAllMocks();
    previousForemanHome = process.env.FOREMAN_HOME;
    foremanHome = join("/tmp", `foreman-reset-home-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    process.env.FOREMAN_HOME = foremanHome;
    mockHomedir.mockReturnValue(foremanHome);

    runs = [
      makeRun("run-active", "running"),
      makeRun("run-failed", "failed"),
      makeRun("run-completed", "completed"),
    ];
    createRunArtifacts(foremanHome, runs);

    mockResolveProjectContext.mockResolvedValue({ projectPath, registered: project });
    mockGetTask.mockResolvedValue({ task_id: "task-1", project_id: "proj-1", title: "Reset me" });
    mockListRuns.mockResolvedValue(runs);
    mockSendCommand.mockResolvedValue({ ok: true });
    mockSchedulerTick.mockResolvedValue(undefined);
    mockRunStore.getRun.mockResolvedValue(null);
    mockRunStore.getRunsForTask.mockResolvedValue([runs[0]]);
    mockRunStore.getRunsByStatus.mockResolvedValue([]);
    mockRunStore.updateRun.mockResolvedValue(undefined);
    mockRunStore.logEvent.mockResolvedValue(undefined);
    mockRunStore.updateTaskStatus.mockResolvedValue(undefined);
    mockMergeQueueList.mockResolvedValue([
      { id: 9, run_id: "run-active", task_id: "task-1", branch_name: "foreman/task-1" },
    ]);
    mockMergeQueueRemove.mockResolvedValue(undefined);
    mockRemoveWorkspace.mockResolvedValue(undefined);
    mockDeleteBranch.mockResolvedValue({ deleted: true, wasFullyMerged: false });
    mockDeleteRemoteBranch.mockResolvedValue(undefined);
    mockBranchExistsOnRemote.mockResolvedValue(true);
  });

  afterEach(() => {
    if (previousForemanHome === undefined) {
      delete process.env.FOREMAN_HOME;
    } else {
      process.env.FOREMAN_HOME = previousForemanHome;
    }
    rmSync(foremanHome, { recursive: true, force: true });
  });

  it("dry-run plans task reset, branch/worktree removal, and all prior run artifact cleanup without mutating", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const code = await resetAction("task-1", { dryRun: true, reason: "RCA retry" });

      expect(code).toBe(0);
      expect(mockRemoveWorkspace).not.toHaveBeenCalled();
      expect(mockDeleteBranch).not.toHaveBeenCalled();
      expect(mockDeleteRemoteBranch).not.toHaveBeenCalled();
      expect(mockSendCommand).not.toHaveBeenCalled();
      for (const run of runs) {
        expectRunArtifactsPresent(foremanHome, run, true);
      }
      expect(existsSync(join(foremanHome, ".foreman", "logs", "unrelated.log"))).toBe(true);

      const output = logSpy.mock.calls.map((call) => call.join(" ")).join("\n");
      expect(output).toContain("foreman/task-1");
      expect(output).toContain("origin");
      expect(output).toContain("/tmp/wt/task-1");
      expect(output).toContain("run-active.log");
      expect(output).toContain("run-failed.err");
      expect(output).toContain(join(foremanHome, "reports", "proj-1", "task-1", "run-completed"));
      expect(output).toContain("would mark active run");
      expect(output).toContain("run-active");
      expect(output).toContain("failed");
    } finally {
      logSpy.mockRestore();
      errorSpy.mockRestore();
    }
  });

  it("dry-run reports active draft PR retirement without closing GitHub or deleting branches", async () => {
    runs = [
      {
        ...makeRun("run-active", "running"),
        pr_url: "https://github.com/org/repo/pull/123",
        pr_state: "draft",
      },
      makeRun("run-completed", "completed"),
    ];
    mockListRuns.mockResolvedValue(runs);
    createRunArtifacts(foremanHome, runs);
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const code = await resetAction("task-1", { dryRun: true, reason: "RCA retry" });

      expect(code).toBe(0);
      expect(mockDeleteBranch).not.toHaveBeenCalled();
      expect(mockDeleteRemoteBranch).not.toHaveBeenCalled();
      expect((mockExecFileAsync.mock.calls as unknown[][]).some((call) => call[0] === "gh")).toBe(false);
      expect(mockSendCommand).not.toHaveBeenCalled();
      const output = logSpy.mock.calls.map((call) => call.join(" ")).join("\n");
      expect(output).toContain("would close PR https://github.com/org/repo/pull/123 as superseded by reset");
    } finally {
      logSpy.mockRestore();
      errorSpy.mockRestore();
    }
  });

  it("applies reset by failing the active run before clearing artifacts and marking the task ready", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const code = await resetAction("task-1", { reason: "RCA retry" });

      expect(code).toBe(0);
      expect(mockRemoveWorkspace).toHaveBeenCalledWith(projectPath, "/tmp/wt/task-1");
      expect(mockDeleteBranch.mock.calls.some((call) => call[0] === projectPath && call[1] === "foreman/task-1")).toBe(true);
      expect(mockDeleteRemoteBranch).toHaveBeenCalledWith(projectPath, "foreman/task-1");
      for (const run of runs) {
        expectRunArtifactsPresent(foremanHome, run, false);
      }
      expect(existsSync(join(foremanHome, ".foreman", "logs", "unrelated.log"))).toBe(true);

      const runFailCommand = findRunFailCommand("run-active");
      expect(runFailCommand).toBeDefined();
      if (!runFailCommand) throw new Error("run.fail command for active run was not sent");
      expect(runFailCommand.payload).toEqual(expect.objectContaining({
        project_id: "proj-1",
        task_id: "task-1",
        run_id: "run-active",
        reason: "RCA retry",
      }));

      const readyCommand = findReadyTaskUpdateCommand();
      expect(readyCommand).toBeDefined();
      if (!readyCommand) throw new Error("ready task.update command was not sent");
      expect(runFailCommand.index).toBeLessThan(readyCommand.index);
      expect(readyCommand.payload.run_id).toBeNull();
      expect(mockSchedulerTick).toHaveBeenCalledOnce();
    } finally {
      logSpy.mockRestore();
      errorSpy.mockRestore();
    }
  });

  it("closes an active open PR before deleting the remote branch during reset", async () => {
    runs = [
      {
        ...makeRun("run-active", "running"),
        pr_url: "https://github.com/org/repo/pull/124",
        pr_state: "open",
      },
      makeRun("run-completed", "completed"),
    ];
    mockListRuns.mockResolvedValue(runs);
    createRunArtifacts(foremanHome, runs);
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const code = await resetAction("task-1", { reason: "RCA retry" });

      expect(code).toBe(0);
      const execCalls = mockExecFileAsync.mock.calls as unknown[][];
      const ghCloseCallIndex = execCalls.findIndex((call) => call[0] === "gh");
      expect(ghCloseCallIndex).toBeGreaterThanOrEqual(0);
      const ghCloseCall = execCalls[ghCloseCallIndex];
      expect(ghCloseCall).toEqual([
        "gh",
        [
          "pr",
          "close",
          "https://github.com/org/repo/pull/124",
          "--comment",
          "Closed by foreman reset: RCA retry. A fresh run will create a new PR.",
        ],
        { cwd: projectPath },
      ]);
      expect(mockDeleteRemoteBranch).toHaveBeenCalledWith(projectPath, "foreman/task-1");
      const ghCloseOrder = mockExecFileAsync.mock.invocationCallOrder[ghCloseCallIndex];
      const deleteRemoteOrder = mockDeleteRemoteBranch.mock.invocationCallOrder[0];
      expect(ghCloseOrder).toBeDefined();
      expect(deleteRemoteOrder).toBeDefined();
      expect(ghCloseOrder!).toBeLessThan(deleteRemoteOrder!);

      const prResetCommand = findSendCommandMatch(
        (command, payload) =>
          command.command_type === "run.pr.reset" &&
          payload.run_id === "run-active" &&
          payload.project_id === "proj-1" &&
          payload.task_id === "task-1",
      );
      expect(prResetCommand?.payload).toEqual(expect.objectContaining({
        action: "closed",
        reason: "RCA retry",
        pr_url: "https://github.com/org/repo/pull/124",
        branch_name: "foreman/task-1",
      }));
    } finally {
      logSpy.mockRestore();
      errorSpy.mockRestore();
    }
  });

  it("continues reset cleanup when GitHub reports the PR was already merged", async () => {
    runs = [
      {
        ...makeRun("run-active", "running"),
        pr_url: "https://github.com/org/repo/pull/125",
        pr_state: "open",
      },
      makeRun("run-completed", "completed"),
    ];
    mockListRuns.mockResolvedValue(runs);
    mockExecFileAsync.mockImplementation(async (command?: string) => {
      if (command === "gh") throw new Error("Pull request org/repo#125 is already merged");
      return { stdout: "", stderr: "" };
    });
    createRunArtifacts(foremanHome, runs);
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const code = await resetAction("task-1", { reason: "RCA retry" });

      expect(code).toBe(0);
      expect(mockDeleteBranch.mock.calls.some((call) => call[0] === projectPath && call[1] === "foreman/task-1")).toBe(true);
      expect(mockDeleteRemoteBranch.mock.calls.some((call) => call[0] === projectPath && call[1] === "foreman/task-1")).toBe(true);
      expect(findRunFailCommand("run-active")).toBeDefined();
      expect(findReadyTaskUpdateCommand()).toBeDefined();
      expect(
        findSendCommandMatch(
          (command, payload) => command.command_type === "run.pr.reset" && payload.run_id === "run-active",
        ),
      ).toBeUndefined();
      const output = logSpy.mock.calls.map((call) => call.join(" ")).join("\n");
      expect(output).toContain("already merged");
    } finally {
      logSpy.mockRestore();
      errorSpy.mockRestore();
    }
  });
});
