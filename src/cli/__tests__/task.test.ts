import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { query } from "../../lib/db/pool-manager.js";
import {
  CircularDependencyError,
  InvalidStatusTransitionError,
  TaskNotFoundError,
  isCompactTaskId,
  parsePriority,
  priorityLabel,
} from "../../lib/task-store.js";
import {
  createPostgresProjectFixture,
  startPostgresTestcontainer,
  stopPostgresTestcontainer,
} from "../../test-support/postgres-testcontainer.js";

/**
 * `foreman task` storage behavior now targets the production Postgres task
 * tables via PostgresAdapter. The old NativeTaskStore/ForemanStore sqlite setup
 * was removed because it no longer matches production.
 */
describe("task helpers", () => {
  it("parses and formats priorities", () => {
    expect(parsePriority("critical")).toBe(0);
    expect(parsePriority("high")).toBe(1);
    expect(parsePriority("medium")).toBe(2);
    expect(parsePriority("low")).toBe(3);
    expect(parsePriority("backlog")).toBe(4);
    expect(parsePriority("0")).toBe(0);
    expect(() => parsePriority("urgent")).toThrow(RangeError);
    expect(priorityLabel(0)).toBe("critical");
    expect(priorityLabel(4)).toBe("backlog");
    expect(isCompactTaskId("foreman-a1b2c")).toBe(true);
  });

  it("keeps task error classes available for callers", () => {
    expect(new TaskNotFoundError("x").name).toBe("TaskNotFoundError");
    expect(new InvalidStatusTransitionError("x", "ready", "closed").name).toBe("InvalidStatusTransitionError");
    expect(new CircularDependencyError("a", "b").name).toBe("CircularDependencyError");
  });
});

describe("task storage — PostgresAdapter", { timeout: 120_000 }, () => {
  beforeAll(async () => {
    await startPostgresTestcontainer();
  });

  afterAll(async () => {
    await stopPostgresTestcontainer();
  });

  it("creates, lists, filters, shows, approves, claims, and closes tasks", async () => {
    const { adapter, project } = await createPostgresProjectFixture("task-cli");
    await adapter.createTask(project.id, { id: "task-cli-low", title: "Low", priority: 3, type: "task" });
    await adapter.createTask(project.id, { id: "task-cli-high", title: "High", priority: 1, type: "bug" });

    expect(await adapter.listTasks(project.id)).toHaveLength(2);
    expect(await adapter.listTasks(project.id, { status: ["backlog"] })).toHaveLength(2);
    expect(await adapter.getTask(project.id, "task-cli-high")).toEqual(
      expect.objectContaining({ title: "High", type: "bug", status: "backlog" }),
    );

    await adapter.approveTask(project.id, "task-cli-low");
    await adapter.approveTask(project.id, "task-cli-high");
    expect((await adapter.listReadyTasks(project.id)).map((task) => task.id)).toEqual(["task-cli-high", "task-cli-low"]);

    const run = await adapter.createRun(project.id, "task-cli-high", "developer");
    expect(await adapter.claimTask(project.id, "task-cli-high", run.id)).toBe(true);
    expect(await adapter.claimTask(project.id, "task-cli-high", run.id)).toBe(false);
    expect(await adapter.getTask(project.id, "task-cli-high")).toEqual(
      expect.objectContaining({ status: "in-progress", run_id: run.id }),
    );

    await adapter.closeTask(project.id, "task-cli-high");
    expect(await adapter.getTask(project.id, "task-cli-high")).toEqual(expect.objectContaining({ status: "closed" }));
  });

  it("updates task fields and external identifiers", async () => {
    const { adapter, project } = await createPostgresProjectFixture("task-cli-update");
    await adapter.createTask(project.id, { id: "task-cli-update", title: "Old", external_id: "github:o/r#1" });

    await adapter.updateTask(project.id, "task-cli-update", {
      title: "New",
      description: "desc",
      type: "feature",
      priority: 0,
      status: "ready",
      external_id: "github:o/r#2",
    });

    expect(await adapter.getTask(project.id, "task-cli-update")).toEqual(
      expect.objectContaining({ title: "New", description: "desc", type: "feature", priority: 0, status: "ready" }),
    );
    expect(await adapter.getTaskByExternalId(project.id, "github:o/r#2")).toEqual(
      expect.objectContaining({ id: "task-cli-update" }),
    );
  });

  it("manages dependencies and rejects cycles", async () => {
    const { adapter, project } = await createPostgresProjectFixture("task-cli-deps");
    await adapter.createTask(project.id, { id: "task-cli-a", title: "A", status: "ready" });
    await adapter.createTask(project.id, { id: "task-cli-b", title: "B", status: "ready" });
    await adapter.createTask(project.id, { id: "task-cli-c", title: "C", status: "ready" });

    await adapter.addTaskDependency(project.id, "task-cli-a", "task-cli-b");
    await adapter.addTaskDependency(project.id, "task-cli-b", "task-cli-c");
    expect(await adapter.listTaskDependencies(project.id, "task-cli-a", "outgoing")).toEqual([
      expect.objectContaining({ from_task_id: "task-cli-a", to_task_id: "task-cli-b" }),
    ]);
    await expect(adapter.addTaskDependency(project.id, "task-cli-c", "task-cli-a")).rejects.toThrow(/circular/i);
    await adapter.removeTaskDependency(project.id, "task-cli-a", "task-cli-b");
    expect(await adapter.listTaskDependencies(project.id, "task-cli-a", "outgoing")).toEqual([]);
  });

  it("can reset failed/stuck tasks to ready", async () => {
    const { adapter, project } = await createPostgresProjectFixture("task-cli-retry");
    await adapter.createTask(project.id, { id: "task-cli-failed", title: "Failed", status: "failed" });
    await adapter.retryTask(project.id, "task-cli-failed");
    expect(await adapter.getTask(project.id, "task-cli-failed")).toEqual(expect.objectContaining({ status: "ready" }));

    await expect(adapter.retryTask(project.id, "missing-task")).rejects.toThrow(/not found|failed\/stuck/);
  });

  it("stores GitHub metadata and labels", async () => {
    const { adapter, project } = await createPostgresProjectFixture("task-cli-github");
    await adapter.createTask(project.id, {
      id: "task-cli-gh",
      title: "GH",
      external_repo: "owner/repo",
      github_issue_number: 123,
      github_milestone: "v1",
      sync_enabled: true,
      labels: ["bug", "p1"],
    });

    const rows = await query<{ labels: string[] }>(`SELECT labels FROM tasks WHERE id = $1`, ["task-cli-gh"]);
    expect(rows[0].labels).toEqual(["bug", "p1"]);
  });
});
