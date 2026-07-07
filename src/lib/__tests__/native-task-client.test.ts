import { afterAll, afterEach, describe, expect, it, vi } from "vitest";

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

const fetchSpy = vi.spyOn(globalThis, "fetch");

function jsonResponse(body: unknown, ok = true, status = 200): Response {
  return { ok, status, json: vi.fn().mockResolvedValue(body) } as unknown as Response;
}

afterAll(() => {
  fetchSpy.mockRestore();
});

function task(overrides: Record<string, unknown> = {}) {
  return {
    task_id: "task-1",
    id: "task-1",
    project_id: "proj-1",
    title: "Task one",
    task_type: "task",
    priority: 2,
    status: "ready",
    created_at: "2026-01-01T00:00:00.000Z",
    updated_at: "2026-01-01T00:00:00.000Z",
    description: null,
    annotations: [],
    ...overrides,
  };
}

afterEach(() => {
  fetchSpy.mockReset();
  for (const mock of [...Object.values(nativeStoreInstance), ...Object.values(foremanStoreInstance)]) {
    if (typeof mock === "function" && "mockReset" in mock) mock.mockReset();
  }
  foremanStoreInstance.getDb.mockReturnValue({});
});

describe("NativeTaskClient", () => {
  it("lists, creates, and filters Elixir-backed tasks for registered projects", async () => {
    fetchSpy
      .mockResolvedValueOnce(jsonResponse({ ok: true, tasks: [task({ task_type: "bug" }), task({ task_id: "task-2", type: "feature" })] }))
      .mockResolvedValueOnce(jsonResponse({ ok: true }))
      .mockResolvedValueOnce(jsonResponse({ ok: true }));
    const client = new NativeTaskClient("/tmp/my repo", { registeredProjectId: "proj-1" });

    await expect(client.list({ status: "in_progress", type: "bug" })).resolves.toEqual([]);
    const created = await client.create("Created", { description: "body", priority: "p1", type: "bug", parent: "parent-1" });
    expect(created).toMatchObject({ priority: "1", title: "Created", type: "bug" });

    const createCommand = JSON.parse(String((fetchSpy.mock.calls[1][1] as RequestInit).body));
    expect(createCommand).toMatchObject({
      command_type: "task.create",
      payload: expect.objectContaining({ project_id: "proj-1", title: "Created", priority: 1, task_type: "bug" }),
    });
    const dependencyCommand = JSON.parse(String((fetchSpy.mock.calls[2][1] as RequestInit).body));
    expect(dependencyCommand).toMatchObject({
      command_type: "task.add_dependency",
      payload: expect.objectContaining({ project_id: "proj-1", task_id: created.id, depends_on: "parent-1", kind: "parent-child" }),
    });
  });

  it("uses the local native task store when no registered project id is available", async () => {
    nativeStoreInstance.list.mockReturnValueOnce([{ id: "local-1", title: "Local", type: "bug", priority: 2, status: "ready", created_at: "2026-01-01", updated_at: "2026-01-01", description: null, labels: null }]);
    nativeStoreInstance.create.mockReturnValueOnce({ id: "local-2", title: "Local", type: "task", priority: 2, status: "backlog", created_at: "2026-01-01", updated_at: "2026-01-01", description: null, labels: null });
    nativeStoreInstance.ready.mockReturnValueOnce([{ id: "local-3", title: "Ready", type: "task", priority: 2, status: "ready", created_at: "2026-01-01", updated_at: "2026-01-01", description: null, labels: null }]);
    nativeStoreInstance.get.mockReturnValueOnce({ id: "local-4", title: "Shown", type: "task", priority: 2, status: "ready", created_at: "2026-01-01", updated_at: "2026-01-01", description: null, labels: null });
    const client = new NativeTaskClient("/tmp/repo");

    await expect(client.list({ status: "ready", type: "bug" })).resolves.toMatchObject([{ id: "local-1", labels: ["project:/tmp/repo"] }]);
    await expect(client.create("Local", { priority: "high", parent: "parent-1" })).resolves.toMatchObject({ id: "local-2" });
    await expect(client.ready()).resolves.toMatchObject([{ id: "local-3" }]);
    await expect(client.show("local-4")).resolves.toMatchObject({ id: "local-4" });

    expect(nativeStoreInstance.addDependency).toHaveBeenCalledWith("local-2", "parent-1", "parent-child");
    expect(foremanStoreInstance.close).toHaveBeenCalledTimes(4);
  });

  it("updates, comments, closes, and resets Elixir tasks with transition guards", async () => {
    fetchSpy
      .mockResolvedValueOnce(jsonResponse({ ok: true, task: task({ status: "ready" }) }))
      .mockResolvedValueOnce(jsonResponse({ ok: true }))
      .mockResolvedValueOnce(jsonResponse({ ok: true }))
      .mockResolvedValueOnce(jsonResponse({ ok: true, task: task({ annotations: [{ author: "qa", created_at: "2026-01-02T03:04:05.000Z", body: "Looks good" }] }) }))
      .mockResolvedValueOnce(jsonResponse({ ok: true, task: task() }))
      .mockResolvedValueOnce(jsonResponse({ ok: true }))
      .mockResolvedValueOnce(jsonResponse({ ok: true, task: task({ status: "backlog" }) }))
      .mockResolvedValueOnce(jsonResponse({ ok: true }));
    const client = new NativeTaskClient("/tmp/repo", { registeredProjectId: "proj-1" });

    await client.update("task-1", { claim: true, title: "New title", description: "", notes: "manual note" });
    await expect(client.comments("task-1")).resolves.toContain("**qa** (2026-01-02T03:04:05.000Z):\nLooks good");
    await client.close("task-1");
    await client.resetToReady("task-1");

    const commands = fetchSpy.mock.calls
      .filter((call) => String(call[0]).includes("/api/v1/commands"))
      .map((call) => JSON.parse(String((call[1] as RequestInit).body)));
    expect(commands).toEqual(expect.arrayContaining([
      expect.objectContaining({ command_type: "task.update", payload: expect.objectContaining({ status: "in-progress", title: "New title", description: "" }) }),
      expect.objectContaining({ command_type: "task.annotate", payload: expect.objectContaining({ body: "manual note" }) }),
      expect.objectContaining({ command_type: "task.close", payload: expect.objectContaining({ task_id: "task-1" }) }),
      expect.objectContaining({ command_type: "task.update", payload: expect.objectContaining({ status: "ready" }) }),
    ]));
  });

  it("reports missing tasks, empty comments, and invalid backward transitions", async () => {
    const client = new NativeTaskClient("/tmp/repo", { registeredProjectId: "proj-1" });
    fetchSpy.mockResolvedValueOnce(jsonResponse({ ok: false, error: { message: "missing" } }, false, 404));
    await expect(client.show("missing")).rejects.toBeInstanceOf(TaskNotFoundError);

    fetchSpy.mockResolvedValueOnce(jsonResponse({ ok: true, task: task({ annotations: [] }) }));
    await expect(client.comments("task-1")).resolves.toBeNull();

    fetchSpy.mockResolvedValueOnce(jsonResponse({ ok: true, task: task({ status: "merged" }) }));
    await expect(client.update("task-1", { status: "ready" })).rejects.toBeInstanceOf(InvalidStatusTransitionError);

    fetchSpy.mockResolvedValueOnce(jsonResponse({ ok: true, task: task({ status: "closed" }) }));
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
