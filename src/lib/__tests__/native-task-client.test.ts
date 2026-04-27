import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockGetTask,
  mockListReadyTasks,
  mockUpdateTask,
  mockCloseTask,
  mockResetTask,
  mockCreateTask,
  mockAddTaskDependency,
  MockPostgresAdapter,
} = vi.hoisted(() => {
  const rows = new Map<string, Record<string, unknown>>();

  const seedTask = (status = "ready") => {
    rows.set("task-1", {
      id: "task-1",
      project_id: "proj-1",
      title: "Task 1",
      description: "Ship it",
      type: "feature",
      priority: 1,
      status,
      run_id: null,
      branch: null,
      external_id: null,
      created_at: "2026-04-25T00:00:00.000Z",
      updated_at: "2026-04-25T00:00:00.000Z",
      approved_at: null,
      closed_at: null,
    });
  };

  seedTask();

  const mockGetTask = vi.fn(async (_projectId: string, id: string) => rows.get(id) ?? null);
  const mockListReadyTasks = vi.fn(async (_projectId: string) =>
    [...rows.values()].filter((row) => row.status === "ready")
  );
  const mockUpdateTask = vi.fn(async (_projectId: string, id: string, updates: Record<string, unknown>) => {
    const current = rows.get(id);
    if (!current) return;
    rows.set(id, {
      ...current,
      ...updates,
      updated_at: "2026-04-25T01:00:00.000Z",
    });
  });
  const mockCloseTask = vi.fn(async (_projectId: string, id: string) => {
    const current = rows.get(id);
    if (!current) return;
    rows.set(id, {
      ...current,
      status: "closed",
      closed_at: "2026-04-25T02:00:00.000Z",
      updated_at: "2026-04-25T02:00:00.000Z",
    });
  });
  const mockResetTask = vi.fn(async (_projectId: string, id: string) => {
    const current = rows.get(id);
    if (!current) return;
    rows.set(id, {
      ...current,
      status: "ready",
      run_id: null,
      updated_at: "2026-04-25T03:00:00.000Z",
    });
  });
  const mockCreateTask = vi.fn(async (_projectId: string, taskData: Record<string, unknown>) => {
    const id = String(taskData.id);
    const row = {
      id,
      project_id: _projectId,
      title: String(taskData.title),
      description: taskData.description ?? null,
      type: String(taskData.type ?? "task"),
      priority: Number(taskData.priority ?? 2),
      status: String(taskData.status ?? "backlog"),
      run_id: null,
      branch: null,
      external_id: null,
      created_at: "2026-04-25T04:00:00.000Z",
      updated_at: "2026-04-25T04:00:00.000Z",
      approved_at: null,
      closed_at: null,
    };
    rows.set(id, row);
    return row;
  });
  const mockAddTaskDependency = vi.fn(async (_projectId: string, fromTaskId: string, toTaskId: string, type: string) => {
    const current = rows.get(fromTaskId);
    if (!current) return;
    rows.set(fromTaskId, {
      ...current,
      parent: toTaskId,
      dependency_type: type,
    });
  });

  const MockPostgresAdapter = vi.fn(function MockPostgresAdapterImpl(this: Record<string, unknown>) {
    this.getTask = mockGetTask;
    this.listReadyTasks = mockListReadyTasks;
    this.updateTask = mockUpdateTask;
    this.closeTask = mockCloseTask;
    this.resetTask = mockResetTask;
    this.createTask = mockCreateTask;
    this.addTaskDependency = mockAddTaskDependency;
  });

  return {
    mockGetTask,
    mockListReadyTasks,
    mockUpdateTask,
    mockCloseTask,
    mockResetTask,
    mockCreateTask,
    mockAddTaskDependency,
    MockPostgresAdapter,
  };
});

vi.mock("../db/postgres-adapter.js", () => ({
  PostgresAdapter: MockPostgresAdapter,
}));

import { NativeTaskClient } from "../native-task-client.js";
import { InvalidStatusTransitionError } from "../task-store.js";

describe("NativeTaskClient registered Postgres path", () => {
  let client: NativeTaskClient;

  beforeEach(() => {
    vi.clearAllMocks();
    const seed: {
      id: string;
      project_id: string;
      title: string;
      description: string;
      type: string;
      priority: number;
      status: string;
      run_id: string | null;
      branch: string | null;
      external_id: string | null;
      created_at: string;
      updated_at: string;
      approved_at: string | null;
      closed_at: string | null;
    } = {
      id: "task-1",
      project_id: "proj-1",
      title: "Task 1",
      description: "Ship it",
      type: "feature",
      priority: 1,
      status: "ready",
      run_id: null,
      branch: null,
      external_id: null,
      created_at: "2026-04-25T00:00:00.000Z",
      updated_at: "2026-04-25T00:00:00.000Z",
      approved_at: null,
      closed_at: null,
    };
    mockGetTask.mockImplementation(async (_projectId: string, id: string) => (id === "task-1" ? { ...seed } : null));
    let current = { ...seed };
    mockGetTask.mockImplementation(async (_projectId: string, id: string) => (id === "task-1" ? current : null));
    mockListReadyTasks.mockImplementation(async () => (current.status === "ready" ? [current] : []));
    mockUpdateTask.mockImplementation(async (_projectId: string, id: string, updates: Record<string, unknown>) => {
      if (id === "task-1") {
        current = {
          ...current,
          ...updates,
          updated_at: "2026-04-25T01:00:00.000Z",
        };
      }
    });
    mockCloseTask.mockImplementation(async (_projectId: string, id: string) => {
      if (id === "task-1") {
        current = {
          ...current,
          status: "closed",
          closed_at: "2026-04-25T02:00:00.000Z",
          updated_at: "2026-04-25T02:00:00.000Z",
        };
      }
    });
    mockResetTask.mockImplementation(async (_projectId: string, id: string) => {
      if (id === "task-1") {
        current = {
          ...current,
          status: "ready",
          run_id: null,
          updated_at: "2026-04-25T03:00:00.000Z",
        };
      }
    });

    client = new NativeTaskClient("/mock/project", { registeredProjectId: "proj-1" });
  });

  it("uses Postgres for show, update, close, and resetToReady", async () => {
    await expect(client.show("task-1")).resolves.toMatchObject({
      status: "ready",
      description: "Ship it",
      labels: ["project:/mock/project"],
    });

    await client.update("task-1", { claim: true, title: "Updated title", description: "New body" });

    expect(mockUpdateTask).toHaveBeenCalledWith("proj-1", "task-1", {
      title: "Updated title",
      description: "New body",
      status: "in-progress",
    });

    await client.resetToReady("task-1");
    expect(mockResetTask).toHaveBeenCalledWith("proj-1", "task-1");

    await client.close("task-1");
    expect(mockCloseTask).toHaveBeenCalledWith("proj-1", "task-1");
  });

  it("creates registered native tasks with the requested fields and parent link", async () => {
    const created = await client.create("QA failure: Task 1", {
      type: "bug",
      priority: "1",
      parent: "epic-1",
      description: "QA failed for task task-1 (Task 1) during epic pipeline run.",
    });

    expect(created.title).toBe("QA failure: Task 1");
    expect(created.type).toBe("bug");
    expect(created.priority).toBe("1");
    expect(created.description).toBe("QA failed for task task-1 (Task 1) during epic pipeline run.");
    expect(created.status).toBe("backlog");

    expect(mockCreateTask).toHaveBeenCalledWith("proj-1", expect.objectContaining({
      title: "QA failure: Task 1",
      description: "QA failed for task task-1 (Task 1) during epic pipeline run.",
      type: "bug",
      priority: 1,
    }));
    expect(mockAddTaskDependency).toHaveBeenCalledWith("proj-1", created.id, "epic-1", "parent-child");
  });

  it("preserves native reset guardrails for closed tasks", async () => {
    mockGetTask.mockImplementation(async (_projectId: string, id: string) =>
      id === "task-1"
        ? {
            id: "task-1",
            project_id: "proj-1",
            title: "Task 1",
            description: "Ship it",
            type: "feature",
            priority: 1,
            status: "closed",
            run_id: null,
            branch: null,
            external_id: null,
            created_at: "2026-04-25T00:00:00.000Z",
            updated_at: "2026-04-25T00:00:00.000Z",
            approved_at: null,
            closed_at: "2026-04-25T02:00:00.000Z",
          }
        : null
    );

    await expect(client.resetToReady("task-1")).rejects.toBeInstanceOf(InvalidStatusTransitionError);
    expect(mockResetTask).not.toHaveBeenCalled();
  });
});

describe("NativeTaskClient local NativeTaskStore path", () => {
  it("creates local native tasks and keeps them visible through the store", async () => {
    const projectPath = mkdtempSync(join(tmpdir(), "foreman-native-task-client-"));
    const client = new NativeTaskClient(projectPath);

    try {
      const created = await client.create("Local task", {
        description: "Local body",
        type: "feature",
        priority: "0",
      });

      expect(created.title).toBe("Local task");
      expect(created.type).toBe("feature");
      expect(created.priority).toBe("0");

      await expect(client.show(created.id)).resolves.toMatchObject({
        status: "backlog",
        description: "Local body",
        labels: [`project:${projectPath}`],
      });
    } finally {
      rmSync(projectPath, { recursive: true, force: true });
    }
  });
});
