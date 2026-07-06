import { afterEach, describe, expect, it, vi } from "vitest";

const postgresInstance = vi.hoisted(() => ({
  listTasks: vi.fn(),
  createTask: vi.fn(),
  addTaskDependency: vi.fn(),
  listReadyTasks: vi.fn(),
  getTask: vi.fn(),
  updateTask: vi.fn(),
  addTaskNote: vi.fn(),
  listTaskNotes: vi.fn(),
  closeTask: vi.fn(),
  resetTask: vi.fn(),
}));

const nativeStoreInstance = vi.hoisted(() => ({
  list: vi.fn(),
  create: vi.fn(),
  addDependency: vi.fn(),
  ready: vi.fn(),
  get: vi.fn(),
  update: vi.fn(),
  close: vi.fn(),
  resetToReady: vi.fn(),
}));

const foremanStoreInstance = vi.hoisted(() => ({
  getDb: vi.fn(() => ({})),
  close: vi.fn(),
}));

vi.mock("../db/postgres-adapter.js", () => ({
  PostgresAdapter: vi.fn(function PostgresAdapterMock() {
    return postgresInstance;
  }),
}));

vi.mock("../store.js", () => ({
  ForemanStore: {
    forProject: vi.fn(() => foremanStoreInstance),
  },
}));

vi.mock("../task-store.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../task-store.js")>();
  return {
    ...actual,
    NativeTaskStore: vi.fn(function NativeTaskStoreMock() {
      return nativeStoreInstance;
    }),
  };
});

const { NativeTaskClient } = await import("../native-task-client.js");
const { InvalidStatusTransitionError, TaskNotFoundError } = await import("../task-store.js");

function pgTask(overrides: Record<string, unknown> = {}) {
  return {
    id: "task-1",
    title: "Task one",
    type: "task",
    priority: 2,
    status: "ready",
    created_at: "2026-01-01T00:00:00.000Z",
    updated_at: "2026-01-01T00:00:00.000Z",
    description: null,
    labels: ["backend"],
    ...overrides,
  };
}

afterEach(() => {
  for (const mock of [...Object.values(postgresInstance), ...Object.values(nativeStoreInstance), ...Object.values(foremanStoreInstance)]) {
    if (typeof mock === "function" && "mockReset" in mock) mock.mockReset();
  }
  foremanStoreInstance.getDb.mockReturnValue({});
});

describe("NativeTaskClient", () => {
  it("lists, creates, and filters Postgres-backed tasks for registered projects", async () => {
    postgresInstance.listTasks.mockResolvedValueOnce([pgTask({ type: "bug" }), pgTask({ id: "task-2", type: "feature" })]);
    postgresInstance.createTask.mockResolvedValueOnce(pgTask({ id: "repo-abcde", title: "Created", priority: 1 }));
    const client = new NativeTaskClient("/tmp/my repo", { registeredProjectId: "proj-1" });

    await expect(client.list({ status: "in_progress", type: "bug" })).resolves.toMatchObject([
      { id: "task-1", labels: ["project:/tmp/my repo", "backend"] },
    ]);
    await expect(client.create("Created", { description: "body", priority: "p1", type: "bug", parent: "parent-1" })).resolves.toMatchObject({
      id: "repo-abcde",
      priority: "1",
      title: "Created",
    });

    expect(postgresInstance.listTasks).toHaveBeenCalledWith("proj-1", { status: ["in-progress"], limit: 1000 });
    expect(postgresInstance.createTask).toHaveBeenCalledWith("proj-1", expect.objectContaining({ title: "Created", priority: 1, type: "bug" }));
    expect(postgresInstance.addTaskDependency).toHaveBeenCalledWith("proj-1", "repo-abcde", "parent-1", "parent-child");
  });

  it("uses the local native task store when no registered project id is available", async () => {
    nativeStoreInstance.list.mockReturnValueOnce([pgTask({ id: "local-1", type: "bug", labels: null })]);
    nativeStoreInstance.create.mockReturnValueOnce(pgTask({ id: "local-2", labels: null }));
    nativeStoreInstance.ready.mockReturnValueOnce([pgTask({ id: "local-3", labels: null })]);
    nativeStoreInstance.get.mockReturnValueOnce(pgTask({ id: "local-4", labels: null }));
    const client = new NativeTaskClient("/tmp/repo");

    await expect(client.list({ status: "ready", type: "bug" })).resolves.toMatchObject([{ id: "local-1", labels: ["project:/tmp/repo"] }]);
    await expect(client.create("Local", { priority: "high", parent: "parent-1" })).resolves.toMatchObject({ id: "local-2" });
    await expect(client.ready()).resolves.toMatchObject([{ id: "local-3" }]);
    await expect(client.show("local-4")).resolves.toMatchObject({ id: "local-4" });

    expect(nativeStoreInstance.addDependency).toHaveBeenCalledWith("local-2", "parent-1", "parent-child");
    expect(foremanStoreInstance.close).toHaveBeenCalledTimes(4);
  });

  it("updates, comments, closes, and resets Postgres tasks with transition guards", async () => {
    postgresInstance.getTask.mockResolvedValue(pgTask({ status: "ready" }));
    postgresInstance.listTaskNotes.mockResolvedValueOnce([
      { author: "qa", created_at: "2026-01-02T03:04:05.000Z", phase: "review", kind: "note", body: "Looks good" },
    ]);
    const client = new NativeTaskClient("/tmp/repo", { registeredProjectId: "proj-1" });

    await client.update("task-1", { claim: true, title: "New title", description: "", notes: "manual note" });
    await expect(client.comments("task-1")).resolves.toContain("**qa** (2026-01-02T03:04:05.000Z review, note):\nLooks good");
    await client.close("task-1");
    await client.resetToReady("task-1");

    expect(postgresInstance.updateTask).toHaveBeenCalledWith("proj-1", "task-1", expect.objectContaining({ status: "in-progress", title: "New title", description: "" }));
    expect(postgresInstance.addTaskNote).toHaveBeenCalledWith("proj-1", "task-1", expect.objectContaining({ body: "manual note" }));
    expect(postgresInstance.closeTask).toHaveBeenCalledWith("proj-1", "task-1");
    expect(postgresInstance.resetTask).toHaveBeenCalledWith("proj-1", "task-1");
  });

  it("reports missing tasks, empty comments, and invalid backward transitions", async () => {
    const client = new NativeTaskClient("/tmp/repo", { registeredProjectId: "proj-1" });
    postgresInstance.getTask.mockResolvedValueOnce(null);
    await expect(client.show("missing")).rejects.toBeInstanceOf(TaskNotFoundError);

    postgresInstance.getTask.mockResolvedValueOnce(pgTask());
    postgresInstance.listTaskNotes.mockResolvedValueOnce([]);
    await expect(client.comments("task-1")).resolves.toBeNull();

    postgresInstance.getTask.mockResolvedValueOnce(pgTask({ status: "merged" }));
    await expect(client.update("task-1", { status: "ready" })).rejects.toBeInstanceOf(InvalidStatusTransitionError);

    postgresInstance.getTask.mockResolvedValueOnce(pgTask({ status: "closed" }));
    await expect(client.resetToReady("task-1")).rejects.toBeInstanceOf(InvalidStatusTransitionError);
  });

  it("updates, closes, resets, and errors through the local native store", async () => {
    nativeStoreInstance.get.mockReturnValueOnce(null);
    const client = new NativeTaskClient("/tmp/repo");

    await client.update("task-1", { status: "in_progress", description: "body", notes: "ignored" });
    await expect(client.comments("task-1")).resolves.toBeNull();
    await client.close("task-1", "done");
    await client.resetToReady("task-1", "retry");
    await expect(client.show("missing")).rejects.toThrow("Native task 'missing' not found");

    expect(nativeStoreInstance.update).toHaveBeenCalledWith("task-1", expect.objectContaining({ status: "in-progress", description: "body" }));
    expect(nativeStoreInstance.close).toHaveBeenCalledWith("task-1", "done");
    expect(nativeStoreInstance.resetToReady).toHaveBeenCalledWith("task-1", "retry");
  });
});
