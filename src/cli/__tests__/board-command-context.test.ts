import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

const { mockListRegisteredProjects, mockCreateTrpcClient } = vi.hoisted(() => {
  const mockListRegisteredProjects = vi.fn();
  const mockCreateTrpcClient = vi.fn();
  return { mockListRegisteredProjects, mockCreateTrpcClient };
});

vi.mock("../commands/project-task-support.js", () => ({
  listRegisteredProjects: mockListRegisteredProjects,
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

import { loadBoardTasks } from "../commands/board.js";

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
      `Project at '${resolve(projectDir)}' is not registered with the daemon.`,
    );

    expect(mockListRegisteredProjects).toHaveBeenCalledOnce();
    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
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
    expect(tasks.get("review")).toHaveLength(1);
    expect(tasks.get("needs_attention")).toHaveLength(0);
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
