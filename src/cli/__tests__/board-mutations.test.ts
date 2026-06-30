import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const {
  mockListRegisteredProjects,
  mockCreateTrpcClient,
  mockEnsureRunning,
  mockListTasks,
  mockSendCommand,
} = vi.hoisted(() => ({
  mockListRegisteredProjects: vi.fn(),
  mockCreateTrpcClient: vi.fn(),
  mockEnsureRunning: vi.fn(),
  mockListTasks: vi.fn(),
  mockSendCommand: vi.fn(),
}));

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
    return { listTasks: mockListTasks, sendCommand: mockSendCommand };
  }),
}));

describe("board mutation helpers", () => {
  const tempDirs: string[] = [];

  function makeProjectDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-board-mutations-"));
    mkdirSync(join(dir, ".foreman"), { recursive: true });
    tempDirs.push(dir);
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "proj", path: dir },
    ]);
    return dir;
  }

  beforeEach(() => {
    vi.clearAllMocks();
    mockListRegisteredProjects.mockReset();
    mockCreateTrpcClient.mockReset();
    mockEnsureRunning.mockReset();
    mockListTasks.mockReset();
    mockSendCommand.mockReset();
    process.env.FOREMAN_BACKEND = "node";
  });

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
    delete process.env.FOREMAN_BACKEND;
  });

  it("updates task status through node tRPC in node mode", async () => {
    const projectDir = makeProjectDir();
    const update = vi.fn().mockResolvedValue(undefined);
    mockCreateTrpcClient.mockReturnValue({ tasks: { update } });

    const { applyStatusChangeAsync } = await import("../commands/board.js");
    await expect(applyStatusChangeAsync(projectDir, "task-1", "ready")).resolves.toBeNull();
    expect(update).toHaveBeenCalledWith({
      projectId: "proj-1",
      taskId: "task-1",
      updates: { status: "ready" },
    });
  });

  it("returns node update errors as strings", async () => {
    const projectDir = makeProjectDir();
    const update = vi.fn().mockRejectedValue(new Error("update failed"));
    mockCreateTrpcClient.mockReturnValue({ tasks: { update } });

    const { applyStatusChangeAsync } = await import("../commands/board.js");
    await expect(applyStatusChangeAsync(projectDir, "task-1", "ready")).resolves.toBe("update failed");
  });

  it("sends Elixir status updates through sendCommand", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const projectDir = makeProjectDir();
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockSendCommand.mockResolvedValue({ ok: true });

    const { applyStatusChangeAsync } = await import("../commands/board.js");
    await expect(applyStatusChangeAsync(projectDir, "task-1", "ready")).resolves.toBeNull();
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "task.update",
      payload: { project_id: "proj-1", task_id: "task-1", status: "ready" },
    }));
  });

  it("returns Elixir status update failures as strings", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const projectDir = makeProjectDir();
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockSendCommand.mockResolvedValue({ ok: false, error: { message: "status failed" } });

    const { applyStatusChangeAsync } = await import("../commands/board.js");
    await expect(applyStatusChangeAsync(projectDir, "task-1", "ready")).resolves.toBe("status failed");
  });

  it("closes tasks through node tRPC in node mode", async () => {
    const projectDir = makeProjectDir();
    const close = vi.fn().mockResolvedValue(undefined);
    mockCreateTrpcClient.mockReturnValue({ tasks: { close } });

    const { closeTaskAsync } = await import("../commands/board.js");
    await expect(closeTaskAsync(projectDir, "task-1")).resolves.toBeNull();
    expect(close).toHaveBeenCalledWith({ projectId: "proj-1", taskId: "task-1" });
  });

  it("returns node close failures as strings", async () => {
    const projectDir = makeProjectDir();
    const close = vi.fn().mockRejectedValue(new Error("close failed"));
    mockCreateTrpcClient.mockReturnValue({ tasks: { close } });

    const { closeTaskAsync } = await import("../commands/board.js");
    await expect(closeTaskAsync(projectDir, "task-1")).resolves.toBe("close failed");
  });

  it("returns Elixir close failures as strings", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const projectDir = makeProjectDir();
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockSendCommand.mockResolvedValue({ ok: false, error: { message: "close failed" } });

    const { closeTaskAsync } = await import("../commands/board.js");
    await expect(closeTaskAsync(projectDir, "task-1")).resolves.toBe("close failed");
  });

  it("closes tasks through Elixir task.close", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const projectDir = makeProjectDir();
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockSendCommand.mockResolvedValue({ ok: true });

    const { closeTaskAsync } = await import("../commands/board.js");
    await expect(closeTaskAsync(projectDir, "task-1")).resolves.toBeNull();
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "task.close",
      payload: { project_id: "proj-1", task_id: "task-1" },
    }));
  });

  it("saves edited tasks through Elixir task.update", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const projectDir = makeProjectDir();
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockSendCommand.mockResolvedValue({ ok: true });

    const { saveEditedTaskAsync } = await import("../commands/board.js");
    await expect(saveEditedTaskAsync(projectDir, "task-1", {
      id: "task-1",
      title: "Updated title",
      description: "Updated description",
      type: "task",
      priority: 1,
      status: "needs_attention",
      external_id: null,
      created_at: "2026-01-01T00:00:00.000Z",
      updated_at: "2026-01-01T00:00:00.000Z",
      approved_at: null,
      closed_at: null,
    })).resolves.toBeNull();

    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "task.update",
      payload: {
        project_id: "proj-1",
        task_id: "task-1",
        title: "Updated title",
        description: "Updated description",
        priority: 1,
        status: "needs_attention",
      },
    }));
  });

  it("saves edited tasks through Elixir with null descriptions omitted", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const projectDir = makeProjectDir();
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockSendCommand.mockResolvedValue({ ok: true });

    const { saveEditedTaskAsync } = await import("../commands/board.js");
    await expect(saveEditedTaskAsync(projectDir, "task-1", {
      id: "task-1",
      title: "Updated title",
      description: null,
      type: "task",
      priority: 1,
      status: "needs_attention",
      external_id: null,
      created_at: "2026-01-01T00:00:00.000Z",
      updated_at: "2026-01-01T00:00:00.000Z",
      approved_at: null,
      closed_at: null,
    })).resolves.toBeNull();

    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "task.update",
      payload: expect.objectContaining({ description: undefined }),
    }));
  });

  it("saves edited tasks through node tRPC", async () => {
    const projectDir = makeProjectDir();
    const update = vi.fn().mockResolvedValue(undefined);
    mockCreateTrpcClient.mockReturnValue({ tasks: { update } });

    const { saveEditedTaskAsync } = await import("../commands/board.js");
    await expect(saveEditedTaskAsync(projectDir, "task-1", {
      id: "task-1",
      title: "Updated title",
      description: "Updated description",
      type: "task",
      priority: 1,
      status: "needs_attention",
      external_id: null,
      created_at: "2026-01-01T00:00:00.000Z",
      updated_at: "2026-01-01T00:00:00.000Z",
      approved_at: null,
      closed_at: null,
    })).resolves.toBeNull();

    expect(update).toHaveBeenCalledWith({
      projectId: "proj-1",
      taskId: "task-1",
      updates: {
        title: "Updated title",
        description: "Updated description",
        priority: 1,
        status: "needs_attention",
      },
    });
  });

  it("returns node save failures as strings", async () => {
    const projectDir = makeProjectDir();
    const update = vi.fn().mockRejectedValue(new Error("save failed"));
    mockCreateTrpcClient.mockReturnValue({ tasks: { update } });

    const { saveEditedTaskAsync } = await import("../commands/board.js");
    await expect(saveEditedTaskAsync(projectDir, "task-1", {
      id: "task-1",
      title: "Updated title",
      description: "Updated description",
      type: "task",
      priority: 1,
      status: "needs_attention",
      external_id: null,
      created_at: "2026-01-01T00:00:00.000Z",
      updated_at: "2026-01-01T00:00:00.000Z",
      approved_at: null,
      closed_at: null,
    })).resolves.toBe("save failed");
  });

  it("creates tasks through node tRPC and returns the created id", async () => {
    const projectDir = makeProjectDir();
    const create = vi.fn().mockResolvedValue({ id: "task-42" });
    mockCreateTrpcClient.mockReturnValue({ tasks: { create } });

    const { createTaskAsync } = await import("../commands/board.js");
    await expect(createTaskAsync(projectDir, {
      title: "New task",
      description: "Task description",
      type: "bug",
      priority: 0,
      status: "backlog",
    })).resolves.toEqual({ taskId: "task-42" });

    expect(create).toHaveBeenCalledWith({
      projectId: "proj-1",
      title: "New task",
      description: "Task description",
      type: "bug",
      priority: 0,
      status: "backlog",
    });
  });

  it("creates tasks through Elixir and generates an id when one is missing", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const projectDir = makeProjectDir();
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockSendCommand.mockResolvedValue({ ok: true });

    const { createTaskAsync } = await import("../commands/board.js");
    const result = await createTaskAsync(projectDir, { title: "Generated id task" });

    expect(typeof result).toBe("object");
    expect((result as { taskId: string }).taskId).toMatch(/^task-/);
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "task.create",
      payload: expect.objectContaining({
        project_id: "proj-1",
        title: "Generated id task",
      }),
    }));
  });

  it("creates tasks through Elixir with explicit id and optional fields", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const projectDir = makeProjectDir();
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockSendCommand.mockResolvedValue({ ok: true });

    const { createTaskAsync } = await import("../commands/board.js");
    await expect(createTaskAsync(projectDir, {
      id: "task-custom",
      title: "Explicit Elixir task",
      description: null,
      type: "bug",
      priority: 0,
      status: "ready",
    })).resolves.toEqual({ taskId: "task-custom" });

    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "task.create",
      payload: {
        project_id: "proj-1",
        task_id: "task-custom",
        title: "Explicit Elixir task",
        description: undefined,
        task_type: "bug",
        priority: 0,
        status: "ready",
      },
    }));
  });

  it("generates a node task id when one is not provided", async () => {
    const projectDir = makeProjectDir();
    const create = vi.fn().mockResolvedValue({ id: "task-generated" });
    mockCreateTrpcClient.mockReturnValue({ tasks: { create } });

    const { createTaskAsync } = await import("../commands/board.js");
    await expect(createTaskAsync(projectDir, { title: "Generated node task" })).resolves.toEqual({ taskId: "task-generated" });

    expect(create).toHaveBeenCalledWith(expect.objectContaining({
      projectId: "proj-1",
      title: "Generated node task",
    }));
    const payload = create.mock.calls[0]?.[0] as Record<string, unknown>;
    expect(payload).not.toHaveProperty("id");
    expect(payload).not.toHaveProperty("description");
    expect(payload).not.toHaveProperty("type");
    expect(payload).not.toHaveProperty("priority");
    expect(payload).not.toHaveProperty("status");
  });

  it("passes through explicit ids for node task creation", async () => {
    const projectDir = makeProjectDir();
    const create = vi.fn().mockResolvedValue({ id: "task-custom" });
    mockCreateTrpcClient.mockReturnValue({ tasks: { create } });

    const { createTaskAsync } = await import("../commands/board.js");
    await expect(createTaskAsync(projectDir, {
      id: "task-custom",
      title: "Explicit id task",
    })).resolves.toEqual({ taskId: "task-custom" });

    expect(create).toHaveBeenCalledWith(expect.objectContaining({ id: "task-custom", title: "Explicit id task" }));
  });

  it("returns node project-registration failures as strings", async () => {
    const projectDir = makeProjectDir();
    mockListRegisteredProjects.mockResolvedValue([]);

    const { createTaskAsync, saveEditedTaskAsync, closeTaskAsync, applyStatusChangeAsync } = await import("../commands/board.js");
    await expect(createTaskAsync(projectDir, { title: "Broken task" })).resolves.toContain("not registered");
    await expect(saveEditedTaskAsync(projectDir, "task-1", {
      id: "task-1",
      title: "Updated title",
      description: null,
      type: "task",
      priority: 2,
      status: "backlog",
      external_id: null,
      created_at: "2026-01-01T00:00:00.000Z",
      updated_at: "2026-01-01T00:00:00.000Z",
      approved_at: null,
      closed_at: null,
    })).resolves.toContain("not registered");
    await expect(closeTaskAsync(projectDir, "task-1")).resolves.toContain("not registered");
    await expect(applyStatusChangeAsync(projectDir, "task-1", "ready")).resolves.toContain("not registered");
  });

  it("returns Elixir create failures as strings", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const projectDir = makeProjectDir();
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockSendCommand.mockResolvedValue({ ok: false, error: { message: "create failed" } });

    const { createTaskAsync } = await import("../commands/board.js");
    await expect(createTaskAsync(projectDir, { title: "Broken task" })).resolves.toBe("create failed");
  });
});
