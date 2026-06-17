import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

const { mockListRegisteredProjects, mockCreateTrpcClient, mockEnsureRunning, mockListTasks } = vi.hoisted(() => {
  const mockListRegisteredProjects = vi.fn();
  const mockCreateTrpcClient = vi.fn();
  const mockEnsureRunning = vi.fn();
  const mockListTasks = vi.fn();
  return { mockListRegisteredProjects, mockCreateTrpcClient, mockEnsureRunning, mockListTasks };
});

vi.mock("../commands/project-task-support.js", () => ({
  listRegisteredProjects: mockListRegisteredProjects,
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn().mockImplementation(function MockElixirServerManager() {
    return { ensureRunning: mockEnsureRunning };
  }),
}));

vi.mock("../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: vi.fn().mockImplementation(function MockElixirServerClient() {
    return { listTasks: mockListTasks };
  }),
}));

import { applyBoardTaskUpdate, loadBoardTasks, pollBoardInboxTaskUpdates, type BoardTask } from "../commands/board.js";

describe("foreman board command context", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-board-command-context-"));
    tempDirs.push(dir);
    return dir;
  }

  beforeEach(() => {
    vi.clearAllMocks();
    mockListRegisteredProjects.mockReset();
    mockCreateTrpcClient.mockReset();
    mockEnsureRunning.mockReset();
    mockListTasks.mockReset();
    delete process.env.FOREMAN_BACKEND;
  });

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("resolves a registered board project when projectPath is a non-canonical equivalent path", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "registered-project", path: projectDir },
    ]);
    const list = vi.fn().mockResolvedValue([]);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list },
    });

    const equivalentPath = `${projectDir}/.`;
    const tasks = await loadBoardTasks(equivalentPath);

    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    expect(list).toHaveBeenCalledWith({ projectId: "proj-1", limit: 1000 });
    expect(tasks.size).toBeGreaterThan(0);
  });

  it("keeps unregistered board project behavior unchanged", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "local-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([]);
    mockCreateTrpcClient.mockReturnValue({
      tasks: { list: vi.fn() },
    });

    await expect(loadBoardTasks(resolve(projectDir))).rejects.toThrow(
      `Project at '${resolve(projectDir)}' is not registered.`,
    );

    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
  });

  it("loads board tasks from Elixir without creating a tRPC client in Elixir mode", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "registered-project", path: projectDir }]);
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockListTasks.mockResolvedValue([
      { task_id: "task-1", project_id: "proj-1", title: "Elixir task", status: "ready" },
    ]);

    const tasks = await loadBoardTasks(projectDir);

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockListTasks).toHaveBeenCalledOnce();
    expect(tasks.get("ready")?.map((task) => task.id)).toEqual(["task-1"]);
  });
});

describe("loadBoardTasks status routing", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-board-status-routing-"));
    tempDirs.push(dir);
    return dir;
  }

  beforeEach(() => {
    vi.clearAllMocks();
    mockListRegisteredProjects.mockReset();
    mockCreateTrpcClient.mockReset();
    delete process.env.FOREMAN_BACKEND;
  });

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  function setupProject() {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "test-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "test-project", path: projectDir },
    ]);

    return { projectDir };
  }

  it("routes failed, stuck, conflict, blocked to needs_attention column", async () => {
    const { projectDir } = setupProject();

    const mockTasks = [
      { id: "task-1", title: "Failed task", status: "failed" },
      { id: "task-2", title: "Stuck task", status: "stuck" },
      { id: "task-3", title: "Conflict task", status: "conflict" },
      { id: "task-4", title: "Blocked task", status: "blocked" },
    ];
    const list = vi.fn().mockResolvedValue(mockTasks);
    mockCreateTrpcClient.mockReturnValue({ tasks: { list } });

    const tasks = await loadBoardTasks(projectDir);

    expect(tasks.get("needs_attention")).toHaveLength(4);
    expect(tasks.get("needs_attention")?.map((t) => t.id)).toEqual([
      "task-1",
      "task-2",
      "task-3",
      "task-4",
    ]);
  });

  it("routes backlog, ready, in_progress, review to their respective columns", async () => {
    const { projectDir } = setupProject();

    const mockTasks = [
      { id: "task-1", title: "Backlog task", status: "backlog" },
      { id: "task-2", title: "Ready task", status: "ready" },
      { id: "task-3", title: "In progress task", status: "in_progress" },
      { id: "task-4", title: "Review task", status: "review" },
    ];
    const list = vi.fn().mockResolvedValue(mockTasks);
    mockCreateTrpcClient.mockReturnValue({ tasks: { list } });

    const tasks = await loadBoardTasks(projectDir);

    expect(tasks.get("backlog")).toHaveLength(1);
    expect(tasks.get("ready")).toHaveLength(1);
    expect(tasks.get("in_progress")).toHaveLength(1);
    expect(tasks.get("needs_attention")).toHaveLength(1);
  });

  it("routes closed and merged to closed column", async () => {
    const { projectDir } = setupProject();

    const mockTasks = [
      { id: "task-1", title: "Closed task", status: "closed" },
      { id: "task-2", title: "Merged task", status: "merged" },
    ];
    const list = vi.fn().mockResolvedValue(mockTasks);
    mockCreateTrpcClient.mockReturnValue({ tasks: { list } });

    const tasks = await loadBoardTasks(projectDir);

    expect(tasks.get("closed")).toHaveLength(2);
    expect(tasks.get("closed")?.map((t) => t.id)).toEqual([
      "task-1",
      "task-2",
    ]);
  });

  it("routes unknown statuses to closed column", async () => {
    const { projectDir } = setupProject();

    const mockTasks = [
      { id: "task-1", title: "Unknown status", status: "unknown_status" },
      { id: "task-2", title: "Another unknown", status: "foobar" },
    ];
    const list = vi.fn().mockResolvedValue(mockTasks);
    mockCreateTrpcClient.mockReturnValue({ tasks: { list } });

    const tasks = await loadBoardTasks(projectDir);

    expect(tasks.get("closed")).toHaveLength(2);
    expect(tasks.get("needs_attention")).toHaveLength(0);
  });

  it("normalizes kebab-case status to snake_case", async () => {
    const { projectDir } = setupProject();

    const mockTasks = [
      { id: "task-1", title: "In-progress task", status: "in-progress" },
      { id: "task-2", title: "In-review task (falls through to closed)", status: "in-review" },
    ];
    const list = vi.fn().mockResolvedValue(mockTasks);
    mockCreateTrpcClient.mockReturnValue({ tasks: { list } });

    const tasks = await loadBoardTasks(projectDir);

    // "in-progress" normalizes to "in_progress" which is a valid BoardStatus
    expect(tasks.get("in_progress")).toHaveLength(1);
    // "in-review" normalizes to "in_review" which is NOT a valid BoardStatus -> falls to closed
    expect(tasks.get("closed")).toHaveLength(1);
  });
});

describe("board inbox-driven task updates", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-board-inbox-updates-"));
    tempDirs.push(dir);
    return dir;
  }

  function setupProject() {
    const projectDir = makeTempDir();
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "test-project", path: projectDir },
    ]);
    return { projectDir };
  }

  beforeEach(() => {
    vi.clearAllMocks();
    mockListRegisteredProjects.mockReset();
    mockCreateTrpcClient.mockReset();
    delete process.env.FOREMAN_BACKEND;
  });

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("seeds its cursor without returning old inbox messages as task changes", async () => {
    const { projectDir } = setupProject();
    mockCreateTrpcClient.mockReturnValue({
      mail: {
        listGlobal: vi.fn().mockResolvedValue([
          { id: "msg-1", run_id: "run-1", created_at: "2026-01-01T00:00:00Z" },
        ]),
      },
      runs: { get: vi.fn() },
    });

    const result = await pollBoardInboxTaskUpdates(projectDir, null);

    expect(result).toEqual({ taskIds: [], newestId: "msg-1" });
  });

  it("processes first messages after an empty inbox has already been seeded", async () => {
    const { projectDir } = setupProject();
    const runGet = vi.fn().mockResolvedValueOnce({ id: "run-1", seed_id: "task-1" });
    mockCreateTrpcClient.mockReturnValue({
      mail: {
        listGlobal: vi.fn().mockResolvedValue([
          { id: "msg-1", run_id: "run-1", created_at: "2026-01-01T00:00:00Z" },
        ]),
      },
      runs: { get: runGet },
    });

    const result = await pollBoardInboxTaskUpdates(projectDir, null, 100, true);

    expect(result).toEqual({ taskIds: ["task-1"], newestId: "msg-1" });
  });

  it("maps new inbox messages to changed task IDs through their run records", async () => {
    const { projectDir } = setupProject();
    const runGet = vi.fn()
      .mockResolvedValueOnce({ id: "run-2", seed_id: "task-2" })
      .mockResolvedValueOnce({ id: "run-3", seed_id: "task-3" });
    mockCreateTrpcClient.mockReturnValue({
      mail: {
        listGlobal: vi.fn().mockResolvedValue([
          { id: "msg-1", run_id: "run-1", created_at: "2026-01-01T00:00:00Z" },
          { id: "msg-2", run_id: "run-2", created_at: "2026-01-01T00:00:01Z" },
          { id: "msg-3", run_id: "run-3", created_at: "2026-01-01T00:00:02Z" },
        ]),
      },
      runs: { get: runGet },
    });

    const result = await pollBoardInboxTaskUpdates(projectDir, "msg-1");

    expect(result).toEqual({ taskIds: ["task-2", "task-3"], newestId: "msg-3" });
    expect(runGet).toHaveBeenCalledWith({ runId: "run-2" });
    expect(runGet).toHaveBeenCalledWith({ runId: "run-3" });
  });

  it("updates only the changed task in the board map", () => {
    const backlogTask: BoardTask = {
      id: "task-1",
      title: "Task",
      description: null,
      type: "bug",
      priority: 2,
      status: "backlog",
      external_id: null,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
      approved_at: null,
      closed_at: null,
    };
    const map = new Map([
      ["backlog", [backlogTask]],
      ["ready", []],
      ["in_progress", []],
      ["needs_attention", []],
      ["closed", []],
    ] as Array<["backlog" | "ready" | "in_progress" | "needs_attention" | "closed", BoardTask[]]>);

    const updated = applyBoardTaskUpdate(map, { ...backlogTask, status: "failed" }, "task-1", "updated");

    expect(updated.get("backlog")).toEqual([]);
    expect(updated.get("needs_attention")?.map((task) => task.id)).toEqual(["task-1"]);
  });
});
