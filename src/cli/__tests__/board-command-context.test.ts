import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

const { mockListRegisteredProjects, mockCreateTrpcClient, mockEnsureRunning, mockListTasks, mockGetTask } = vi.hoisted(() => {
  const mockListRegisteredProjects = vi.fn();
  const mockCreateTrpcClient = vi.fn();
  const mockEnsureRunning = vi.fn();
  const mockListTasks = vi.fn();
  const mockGetTask = vi.fn();
  return { mockListRegisteredProjects, mockCreateTrpcClient, mockEnsureRunning, mockListTasks, mockGetTask };
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
    return { listTasks: mockListTasks, getTask: mockGetTask };
  }),
}));

import { applyBoardTaskUpdate, loadBoardTask, loadBoardTaskNotes, loadBoardTasks, pollBoardInboxTaskUpdates, refreshBoardTasksById, type BoardTask } from "../commands/board.js";

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
    mockGetTask.mockReset();
    process.env.FOREMAN_BACKEND = "node";
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
      `Project at '${resolve(projectDir)}' is not registered in Elixir projections. Run 'foreman project register ${resolve(projectDir)}'.`,
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

  it("fails closed when the Elixir board server is not running", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "registered-project", path: projectDir }]);
    mockEnsureRunning.mockResolvedValue({ running: false, url: "http://127.0.0.1:4766", pid: 1 });

    await expect(loadBoardTasks(projectDir)).rejects.toThrow("Elixir server is not running. Start it with 'foreman server start'.");
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
  });

  it("loads a single board task through node tRPC", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "registered-project", path: projectDir }]);
    const get = vi.fn().mockResolvedValue({ id: "task-1", title: "Node task", status: "ready", type: "task", priority: 2, description: null, external_id: null, created_at: "2026-01-01T00:00:00.000Z", updated_at: "2026-01-01T00:00:00.000Z", approved_at: null, closed_at: null, run_id: null });
    mockCreateTrpcClient.mockReturnValue({ tasks: { list: vi.fn(), get, listNotes: vi.fn() } });

    const task = await loadBoardTask(projectDir, "task-1");

    expect(get).toHaveBeenCalledWith({ projectId: "proj-1", taskId: "task-1" });
    expect(task?.id).toBe("task-1");
    expect(task?.title).toBe("Node task");
  });

  it("loads a single board task through Elixir getTask and enforces project match", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "registered-project", path: projectDir }]);
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockGetTask.mockResolvedValue({ task_id: "task-1", project_id: "proj-1", title: "Elixir task", status: "ready" });

    const task = await loadBoardTask(projectDir, "task-1");

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockGetTask).toHaveBeenCalledWith("task-1");
    expect(task?.id).toBe("task-1");
  });

  it("returns null for an Elixir task from a different project", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "registered-project", path: projectDir }]);
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockGetTask.mockResolvedValue({ task_id: "task-1", project_id: "proj-2", title: "Other project task", status: "ready" });

    await expect(loadBoardTask(projectDir, "task-1")).resolves.toBeNull();
  });

  it("loads board task notes through node tRPC and restores oldest-first order", async () => {
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "registered-project", path: projectDir }]);
    const listNotes = vi.fn().mockResolvedValue([
      { id: "note-2", created_at: "2026-01-02T00:00:00.000Z", phase: "qa", kind: "progress", author: "foreman", body: "second" },
      { id: "note-1", created_at: "2026-01-01T00:00:00.000Z", phase: "developer", kind: "progress", author: "foreman", body: "first" },
    ]);
    mockCreateTrpcClient.mockReturnValue({ tasks: { list: vi.fn(), get: vi.fn(), listNotes } });

    const notes = await loadBoardTaskNotes(projectDir, "task-1");

    expect(listNotes).toHaveBeenCalledWith({ projectId: "proj-1", taskId: "task-1", limit: 10, newestFirst: true });
    expect(notes.map((note) => note.id)).toEqual(["note-1", "note-2"]);
  });

  it("loads board task notes from Elixir annotations", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "registered-project", path: projectDir }]);
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockGetTask.mockResolvedValue({
      task_id: "task-1",
      project_id: "proj-1",
      annotations: [
        { created_at: "2026-01-01T00:00:00.000Z", author: "alice", body: "first" },
        { created_at: "2026-01-02T00:00:00.000Z", author: "bob", body: "second" },
      ],
    });

    const notes = await loadBoardTaskNotes(projectDir, "task-1");

    expect(notes).toEqual([
      { id: "task-1-annotation-0", created_at: "2026-01-01T00:00:00.000Z", phase: null, kind: "note", author: "alice", body: "first" },
      { id: "task-1-annotation-1", created_at: "2026-01-02T00:00:00.000Z", phase: null, kind: "note", author: "bob", body: "second" },
    ]);
  });

  it("returns Elixir annotations even when the task row reports a different project", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "registered-project", path: projectDir }]);
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockGetTask.mockResolvedValue({
      task_id: "task-1",
      project_id: "proj-2",
      annotations: [{ created_at: "2026-01-03T00:00:00.000Z", author: "eve", body: "cross-project annotation" }],
    });

    await expect(loadBoardTaskNotes(projectDir, "task-1")).resolves.toEqual([
      { id: "task-1-annotation-0", created_at: "2026-01-03T00:00:00.000Z", phase: null, kind: "note", author: "eve", body: "cross-project annotation" },
    ]);
  });

  it("returns an empty note list when the Elixir task is missing", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const tmpBase = makeTempDir();
    const projectDir = join(tmpBase, "registered-project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });

    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "registered-project", path: projectDir }]);
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockGetTask.mockResolvedValue(null);

    await expect(loadBoardTaskNotes(projectDir, "task-1")).resolves.toEqual([]);
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
    process.env.FOREMAN_BACKEND = "node";
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

  it("routes open, backlog, ready, in_progress, review to their respective columns", async () => {
    const { projectDir } = setupProject();

    const mockTasks = [
      { id: "task-1", title: "Backlog task", status: "backlog" },
      { id: "task-2", title: "Ready task", status: "ready" },
      { id: "task-3", title: "In progress task", status: "in_progress" },
      { id: "task-4", title: "Review task", status: "review" },
      { id: "task-5", title: "Open task", status: "open" },
    ];
    const list = vi.fn().mockResolvedValue(mockTasks);
    mockCreateTrpcClient.mockReturnValue({ tasks: { list } });

    const tasks = await loadBoardTasks(projectDir);

    expect(tasks.get("backlog")?.map((task) => task.id)).toEqual(["task-1", "task-5"]);
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

  it("routes unknown statuses to needs_attention column", async () => {
    const { projectDir } = setupProject();

    const mockTasks = [
      { id: "task-1", title: "Unknown status", status: "unknown_status" },
      { id: "task-2", title: "Another unknown", status: "foobar" },
    ];
    const list = vi.fn().mockResolvedValue(mockTasks);
    mockCreateTrpcClient.mockReturnValue({ tasks: { list } });

    const tasks = await loadBoardTasks(projectDir);

    expect(tasks.get("closed")).toHaveLength(0);
    expect(tasks.get("needs_attention")).toHaveLength(2);
  });

  it("normalizes kebab-case status to snake_case", async () => {
    const { projectDir } = setupProject();

    const mockTasks = [
      { id: "task-1", title: "In-progress task", status: "in-progress" },
      { id: "task-2", title: "In-review task (falls through to needs_attention)", status: "in-review" },
    ];
    const list = vi.fn().mockResolvedValue(mockTasks);
    mockCreateTrpcClient.mockReturnValue({ tasks: { list } });

    const tasks = await loadBoardTasks(projectDir);

    // "in-progress" normalizes to "in_progress" which is a valid BoardStatus
    expect(tasks.get("in_progress")).toHaveLength(1);
    // "in-review" normalizes to "in_review" which is NOT a valid BoardStatus -> falls to needs_attention
    expect(tasks.get("needs_attention")).toHaveLength(1);
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
    process.env.FOREMAN_BACKEND = "node";
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

  it("returns a null newest cursor for an empty node inbox", async () => {
    const { projectDir } = setupProject();
    const runGet = vi.fn();
    mockCreateTrpcClient.mockReturnValue({
      mail: {
        listGlobal: vi.fn().mockResolvedValue([]),
      },
      runs: { get: runGet },
    });

    const result = await pollBoardInboxTaskUpdates(projectDir, null);

    expect(result).toEqual({ taskIds: [], newestId: null });
    expect(runGet).not.toHaveBeenCalled();
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

  it("deduplicates task ids and ignores runs without seed or bead ids", async () => {
    const { projectDir } = setupProject();
    const runGet = vi.fn()
      .mockResolvedValueOnce({ id: "run-2", seed_id: "task-2" })
      .mockResolvedValueOnce({ id: "run-3", bead_id: "task-2" })
      .mockResolvedValueOnce({ id: "run-4" });
    mockCreateTrpcClient.mockReturnValue({
      mail: {
        listGlobal: vi.fn().mockResolvedValue([
          { id: "msg-1", run_id: "run-1", created_at: "2026-01-01T00:00:00Z" },
          { id: "msg-2", run_id: "run-2", created_at: "2026-01-01T00:00:01Z" },
          { id: "msg-3", run_id: "run-3", created_at: "2026-01-01T00:00:02Z" },
          { id: "msg-4", run_id: "run-4", created_at: "2026-01-01T00:00:03Z" },
        ]),
      },
      runs: { get: runGet },
    });

    const result = await pollBoardInboxTaskUpdates(projectDir, "msg-1");

    expect(result).toEqual({ taskIds: ["task-2"], newestId: "msg-4" });
  });

  it("processes all rows when the last-seen cursor is missing and skips rows without run ids", async () => {
    const { projectDir } = setupProject();
    const runGet = vi.fn()
      .mockResolvedValueOnce({ id: "run-1", seed_id: "task-1" })
      .mockResolvedValueOnce({ id: "run-3", bead_id: "task-3" });
    mockCreateTrpcClient.mockReturnValue({
      mail: {
        listGlobal: vi.fn().mockResolvedValue([
          { id: "msg-1", run_id: "run-1", created_at: "2026-01-01T00:00:00Z" },
          { id: "msg-2", run_id: "", created_at: "2026-01-01T00:00:01Z" },
          { id: "msg-3", run_id: "run-3", created_at: "2026-01-01T00:00:02Z" },
        ]),
      },
      runs: { get: runGet },
    });

    const result = await pollBoardInboxTaskUpdates(projectDir, "missing-msg");

    expect(result).toEqual({ taskIds: ["task-1", "task-3"], newestId: "msg-3" });
    expect(runGet).toHaveBeenCalledTimes(2);
  });

  it("returns an Elixir no-op result for inbox polling", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const { projectDir } = setupProject();
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });

    const result = await pollBoardInboxTaskUpdates(projectDir, "msg-9");

    expect(result).toEqual({ taskIds: [], newestId: "msg-9" });
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
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

  it("re-sorts the destination column when applying a board task update", () => {
    const readyOld: BoardTask = {
      id: "task-old",
      title: "Old",
      description: null,
      type: "task",
      priority: 3,
      status: "ready",
      external_id: null,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
      approved_at: null,
      closed_at: null,
    };
    const readyHigh: BoardTask = {
      id: "task-high",
      title: "High",
      description: null,
      type: "task",
      priority: 0,
      status: "ready",
      external_id: null,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-02T00:00:00Z",
      approved_at: null,
      closed_at: null,
    };
    const backlogTask: BoardTask = {
      id: "task-backlog",
      title: "Backlog",
      description: null,
      type: "task",
      priority: 2,
      status: "backlog",
      external_id: null,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-03T00:00:00Z",
      approved_at: null,
      closed_at: null,
    };
    const map = new Map([
      ["backlog", [backlogTask]],
      ["ready", [readyOld, readyHigh]],
      ["in_progress", []],
      ["needs_attention", []],
      ["closed", []],
    ] as Array<["backlog" | "ready" | "in_progress" | "needs_attention" | "closed", BoardTask[]]>);

    const updated = applyBoardTaskUpdate(map, { ...backlogTask, status: "ready", priority: 1 }, "task-backlog", "priority");

    expect(updated.get("backlog")).toEqual([]);
    expect(updated.get("ready")?.map((task) => task.id)).toEqual(["task-high", "task-backlog", "task-old"]);
  });

  it("removes a task from the board when a refresh resolves to null", async () => {
    const { projectDir } = setupProject();
    mockCreateTrpcClient.mockReturnValue({
      tasks: {
        list: vi.fn(),
        get: vi.fn().mockResolvedValue(null),
      },
    });

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

    const updated = await refreshBoardTasksById(projectDir, map, ["task-1"], "updated");

    expect(updated.get("backlog")).toEqual([]);
  });
});
