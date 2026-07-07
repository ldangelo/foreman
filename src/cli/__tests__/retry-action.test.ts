import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ITaskClient } from "../../lib/task-client.js";
import { retryAction } from "../commands/retry.js";

function makeStore(overrides: Record<string, unknown> = {}) {
  return {
    getProjectByPath: vi.fn().mockResolvedValue({ id: "proj-1", path: "/repo" }),
    getRunsForTask: vi.fn().mockResolvedValue([]),
    updateRun: vi.fn().mockResolvedValue(undefined),
    logEvent: vi.fn().mockResolvedValue(undefined),
    ...overrides,
  };
}

function makeTaskClient(overrides: Partial<ITaskClient> = {}): ITaskClient {
  return {
    show: vi.fn().mockResolvedValue({ status: "failed", title: "Retry me" }),
    update: vi.fn().mockResolvedValue(undefined),
    resetToReady: vi.fn().mockResolvedValue(undefined),
    ready: vi.fn().mockResolvedValue([]),
    list: vi.fn().mockResolvedValue([]),
    close: vi.fn().mockResolvedValue(undefined),
    ...overrides,
  } as ITaskClient;
}

describe("retryAction", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  it("returns 1 when the project is missing", async () => {
    const store = makeStore({ getProjectByPath: vi.fn().mockResolvedValue(null) });
    const tasksClient = makeTaskClient();

    const exitCode = await retryAction("task-1", {}, tasksClient, store as never, "/repo");

    expect(exitCode).toBe(1);
    expect(tasksClient.show).not.toHaveBeenCalled();
  });

  it("returns 1 when the task cannot be shown", async () => {
    const store = makeStore();
    const tasksClient = makeTaskClient({ show: vi.fn().mockRejectedValue(new Error("missing task")) });

    const exitCode = await retryAction("task-1", {}, tasksClient, store as never, "/repo");

    expect(exitCode).toBe(1);
    expect(store.getRunsForTask).not.toHaveBeenCalled();
  });

  it("resets retryable task status to ready via resetToReady and marks failed runs failed", async () => {
    const latestRun = { id: "run-1", status: "failed" };
    const store = makeStore({ getRunsForTask: vi.fn().mockResolvedValue([latestRun]) });
    const tasksClient = makeTaskClient({ show: vi.fn().mockResolvedValue({ status: "failed", title: "Retry me" }) });

    const exitCode = await retryAction("task-1", {}, tasksClient, store as never, "/repo");

    expect(exitCode).toBe(0);
    expect(tasksClient.resetToReady).toHaveBeenCalledWith("task-1");
    expect(tasksClient.update).not.toHaveBeenCalled();
    expect(store.updateRun).toHaveBeenCalledWith("run-1", expect.objectContaining({ status: "failed" }));
    expect(store.logEvent).toHaveBeenCalledWith("proj-1", "restart", expect.objectContaining({ taskId: "task-1", previousRunId: "run-1" }), "run-1");
  });

  it("resets native stuck tasks to ready and marks terminal runs reset", async () => {
    const latestRun = { id: "run-2", status: "completed" };
    const store = makeStore({ getRunsForTask: vi.fn().mockResolvedValue([latestRun]) });
    const tasksClient = makeTaskClient({ show: vi.fn().mockResolvedValue({ status: "stuck", title: "Retry me" }) });

    const exitCode = await retryAction("task-2", {}, tasksClient, store as never, "/repo");

    expect(exitCode).toBe(0);
    expect(tasksClient.resetToReady).toHaveBeenCalledWith("task-2");
    expect(tasksClient.update).not.toHaveBeenCalled();
    expect(store.updateRun).toHaveBeenCalledWith("run-2", expect.objectContaining({ status: "reset" }));
  });

  it("describes dry-run actions without mutating task or run state", async () => {
    const latestRun = { id: "run-3", status: "conflict" };
    const store = makeStore({ getRunsForTask: vi.fn().mockResolvedValue([latestRun]) });
    const tasksClient = makeTaskClient({ show: vi.fn().mockResolvedValue({ status: "stuck", title: "Retry me" }) });

    const exitCode = await retryAction("task-3", { dryRun: true }, tasksClient, store as never, "/repo");

    expect(exitCode).toBe(0);
    expect(tasksClient.update).not.toHaveBeenCalled();
    expect(tasksClient.resetToReady).not.toHaveBeenCalled();
    expect(store.updateRun).not.toHaveBeenCalled();
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Would reset task status");
    expect(rendered).toContain("Would reset run run-3: conflict → reset");
    expect(rendered).toContain("Dry run complete — no changes were made.");
  });

  it("prints dispatched tasks when a dispatcher launches work", async () => {
    const store = makeStore();
    const tasksClient = makeTaskClient({ show: vi.fn().mockResolvedValue({ status: "ready", title: "Retry me" }) });
    const dispatcher = {
      dispatch: vi.fn().mockResolvedValue({
        dispatched: [{ taskId: "task-1", worktreePath: "/tmp/wt-1" }],
        skipped: [],
      }),
    };

    const exitCode = await retryAction("task-1", { dispatch: true, model: "claude-test" as never }, tasksClient, store as never, "/repo", dispatcher as never);

    expect(exitCode).toBe(0);
    expect(dispatcher.dispatch).toHaveBeenCalledWith({ maxAgents: 1, model: "claude-test", taskId: "task-1", dryRun: false });
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("dispatched");
    expect(rendered).toContain("/tmp/wt-1");
  });

  it("prints skipped reasons when dispatch skips work", async () => {
    const store = makeStore();
    const tasksClient = makeTaskClient({ show: vi.fn().mockResolvedValue({ status: "ready", title: "Retry me" }) });
    const dispatcher = {
      dispatch: vi.fn().mockResolvedValue({
        dispatched: [],
        skipped: [{ taskId: "task-1", reason: "already running" }],
      }),
    };

    const exitCode = await retryAction("task-1", { dispatch: true }, tasksClient, store as never, "/repo", dispatcher as never);

    expect(exitCode).toBe(0);
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("skipped");
    expect(rendered).toContain("already running");
  });

  it("prints a warning when dispatch returns no dispatched or skipped tasks", async () => {
    const store = makeStore();
    const tasksClient = makeTaskClient({ show: vi.fn().mockResolvedValue({ status: "ready", title: "Retry me" }) });
    const dispatcher = {
      dispatch: vi.fn().mockResolvedValue({ dispatched: [], skipped: [] }),
    };

    const exitCode = await retryAction("task-1", { dispatch: true }, tasksClient, store as never, "/repo", dispatcher as never);

    expect(exitCode).toBe(0);
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("warn");
    expect(rendered).toContain("no tasks dispatched");
  });

  it("throws when dispatch is requested without an available dispatcher", async () => {
    const store = makeStore();
    const tasksClient = makeTaskClient({ show: vi.fn().mockResolvedValue({ status: "ready", title: "Retry me" }) });

    await expect(
      retryAction("task-1", { dispatch: true }, tasksClient, store as never, "/repo"),
    ).rejects.toThrow("Dispatcher unavailable");
  });
});
