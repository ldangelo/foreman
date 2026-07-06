import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  CircularDependencyError,
  InvalidStatusTransitionError,
  TaskNotFoundError,
  isCompactTaskId,
  parsePriority,
  priorityLabel,
} from "../task-store.js";
import {
  createPostgresProjectFixture,
  startPostgresTestcontainer,
  stopPostgresTestcontainer,
} from "../../test-support/postgres-testcontainer.js";

/**
 * Native task persistence now targets production Postgres tables through
 * PostgresAdapter. The old sync NativeTaskStore+ForemanStore sqlite fixture was
 * removed because local sqlite storage is no longer production behavior.
 */
describe("parsePriority", () => {
  it("parses numeric and named priorities", () => {
    expect(parsePriority("0")).toBe(0);
    expect(parsePriority("critical")).toBe(0);
    expect(parsePriority("high")).toBe(1);
    expect(parsePriority("medium")).toBe(2);
    expect(parsePriority("low")).toBe(3);
    expect(parsePriority("backlog")).toBe(4);
  });

  it("throws RangeError for invalid priority", () => {
    expect(() => parsePriority("invalid")).toThrow(RangeError);
    expect(() => parsePriority("5")).toThrow(RangeError);
  });
});

describe("priorityLabel", () => {
  it("formats priority labels", () => {
    expect(priorityLabel(0)).toBe("critical");
    expect(priorityLabel(1)).toBe("high");
    expect(priorityLabel(2)).toBe("medium");
    expect(priorityLabel(3)).toBe("low");
    expect(priorityLabel(4)).toBe("backlog");
  });
});

describe("isCompactTaskId", () => {
  it("recognizes compact task IDs", () => {
    expect(isCompactTaskId("foreman-a1b2c")).toBe(true);
    expect(isCompactTaskId("not compact")).toBe(false);
  });
});

describe("task error types", () => {
  it("preserves custom error names", () => {
    expect(new TaskNotFoundError("x").name).toBe("TaskNotFoundError");
    expect(new InvalidStatusTransitionError("x", "ready", "closed").name).toBe("InvalidStatusTransitionError");
    expect(new CircularDependencyError("a", "b").name).toBe("CircularDependencyError");
  });
});

describe("Postgres native task lifecycle", { timeout: 120_000 }, () => {
  let postgresAvailable = true;

  beforeAll(async () => {
    try {
      await startPostgresTestcontainer();
    } catch {
      postgresAvailable = false;
    }
  }, 120_000);

  afterAll(async () => {
    if (postgresAvailable) {
      await stopPostgresTestcontainer();
    }
  });

  it("creates, approves, claims, updates, resets, and closes tasks", async () => {
    if (!postgresAvailable) return;
    const { adapter, project } = await createPostgresProjectFixture("task-store-lifecycle");
    const task = await adapter.createTask(project.id, {
      id: "task-life-001",
      title: "Lifecycle",
      description: "native task lifecycle",
      type: "task",
      priority: 2,
    });
    expect(task.status).toBe("backlog");
    expect(await adapter.hasNativeTasks(project.id)).toBe(true);

    await adapter.approveTask(project.id, task.id);
    expect(await adapter.listReadyTasks(project.id)).toEqual([expect.objectContaining({ id: task.id, status: "ready" })]);

    const run = await adapter.createRun(project.id, task.id, "developer");
    expect(await adapter.claimTask(project.id, task.id, run.id)).toBe(true);
    expect(await adapter.claimTask(project.id, task.id, run.id)).toBe(false);
    expect(await adapter.getTask(project.id, task.id)).toEqual(expect.objectContaining({ status: "in-progress", run_id: run.id }));

    await adapter.updateTask(project.id, task.id, { status: "failed" });
    await adapter.resetTask(project.id, task.id);
    expect(await adapter.getTask(project.id, task.id)).toEqual(expect.objectContaining({ status: "ready", run_id: null }));

    await adapter.closeTask(project.id, task.id);
    expect(await adapter.getTask(project.id, task.id)).toEqual(expect.objectContaining({ status: "closed" }));
  });

  it("lists tasks by status and external id", async () => {
    if (!postgresAvailable) return;
    const { adapter, project } = await createPostgresProjectFixture("task-store-list");
    await adapter.createTask(project.id, {
      id: "task-list-001",
      title: "List me",
      status: "ready",
      external_id: "github:owner/repo#123",
      priority: 1,
    });
    await adapter.createTask(project.id, { id: "task-list-002", title: "Backlog", status: "backlog", priority: 3 });

    expect(await adapter.listTasks(project.id, { status: ["ready"] })).toEqual([
      expect.objectContaining({ id: "task-list-001" }),
    ]);
    expect(await adapter.getTaskByExternalId(project.id, "github:owner/repo#123")).toEqual(
      expect.objectContaining({ id: "task-list-001" }),
    );
    expect(await adapter.listNeedsHumanTasks(project.id)).toEqual([
      expect.objectContaining({ id: "task-list-002" }),
    ]);
  });

  it("manages dependencies and prevents cycles", async () => {
    if (!postgresAvailable) return;
    const { adapter, project } = await createPostgresProjectFixture("task-store-deps");
    await adapter.createTask(project.id, { id: "task-dep-a", title: "A", status: "ready" });
    await adapter.createTask(project.id, { id: "task-dep-b", title: "B", status: "ready" });
    await adapter.createTask(project.id, { id: "task-dep-c", title: "C", status: "ready" });

    await adapter.addTaskDependency(project.id, "task-dep-a", "task-dep-b");
    await adapter.addTaskDependency(project.id, "task-dep-b", "task-dep-c");

    expect(await adapter.listTaskDependencies(project.id, "task-dep-a", "outgoing")).toEqual([
      expect.objectContaining({ from_task_id: "task-dep-a", to_task_id: "task-dep-b" }),
    ]);
    expect(await adapter.listTaskDependencies(project.id, "task-dep-b", "incoming")).toEqual([
      expect.objectContaining({ from_task_id: "task-dep-a", to_task_id: "task-dep-b" }),
    ]);
    await expect(adapter.addTaskDependency(project.id, "task-dep-c", "task-dep-a")).rejects.toThrow(/circular/i);

    await adapter.removeTaskDependency(project.id, "task-dep-a", "task-dep-b");
    expect(await adapter.listTaskDependencies(project.id, "task-dep-a", "outgoing")).toEqual([]);
  });
});
