import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockListRegisteredProjects,
  mockCreateTrpcClient,
} = vi.hoisted(() => ({
  mockListRegisteredProjects: vi.fn(),
  mockCreateTrpcClient: vi.fn(),
}));

vi.mock("../commands/project-task-support.js", () => ({
  listRegisteredProjects: (...args: unknown[]) => mockListRegisteredProjects(...args),
  resolveRepoRootProjectPath: vi.fn(),
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: (...args: unknown[]) => mockCreateTrpcClient(...args),
}));

import { adaptDaemonMessage, adaptDaemonRun, handleStreamDaemon, resolveDaemonAttachContext, resolveDaemonRun } from "../commands/attach.js";

describe("attach daemon helpers", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("adapts daemon run statuses and falls back the worktree path from task id", () => {
    const success = adaptDaemonRun({
      id: "run-1",
      project_id: "proj-1",
      task_id: "task-1",
      status: "success",
      branch: "foreman/task-1",
      agent_type: null,
      session_key: null,
      worktree_path: null,
      progress: null,
      base_branch: null,
      merge_strategy: null,
      queued_at: "2026-01-01T00:00:00.000Z",
      started_at: "2026-01-01T00:01:00.000Z",
      finished_at: "2026-01-01T00:02:00.000Z",
      created_at: "2026-01-01T00:00:00.000Z",
    }, "/repo");
    const cancelled = adaptDaemonRun({
      id: "run-2",
      project_id: "proj-1",
      task_id: "task-2",
      status: "cancelled",
      branch: "foreman/task-2",
      agent_type: "developer",
      session_key: "pid-222",
      worktree_path: "/tmp/wt-2",
      progress: "{}",
      base_branch: "main",
      merge_strategy: "auto",
      queued_at: "2026-01-01T00:00:00.000Z",
      started_at: null,
      finished_at: null,
      created_at: "2026-01-01T00:00:00.000Z",
    }, "/repo");
    const unknown = adaptDaemonRun({
      id: "run-3",
      project_id: "proj-1",
      task_id: "task-3",
      status: "mystery",
      branch: "foreman/task-3",
      agent_type: "qa",
      session_key: null,
      worktree_path: "/tmp/wt-3",
      progress: null,
      base_branch: null,
      merge_strategy: null,
      queued_at: "2026-01-01T00:00:00.000Z",
      started_at: null,
      finished_at: null,
      created_at: "2026-01-01T00:00:00.000Z",
    }, "/repo");

    expect(success.status).toBe("completed");
    expect(success.agent_type).toBe("daemon");
    expect(success.worktree_path).toContain("task-1");
    expect(cancelled.status).toBe("reset");
    expect(cancelled.worktree_path).toBe("/tmp/wt-2");
    expect(unknown.status).toBe("failed");
  });

  it("resolves daemon attach context only for registered projects", async () => {
    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "proj", path: "/repo" }]);
    mockCreateTrpcClient.mockReturnValue({ runs: true });

    await expect(resolveDaemonAttachContext("/repo")).resolves.toEqual({
      client: { runs: true },
      projectId: "proj-1",
      projectPath: "/repo",
    });

    mockListRegisteredProjects.mockResolvedValue([]);
    await expect(resolveDaemonAttachContext("/repo")).resolves.toBeNull();

    mockListRegisteredProjects.mockRejectedValue(new Error("registry unavailable"));
    await expect(resolveDaemonAttachContext("/repo")).resolves.toBeNull();
  });

  it("resolves daemon runs by exact id, prefix, task id, or returns null", async () => {
    const context = {
      client: {
        runs: {
          list: vi.fn().mockResolvedValue([
            {
              id: "run-1111",
              project_id: "proj-1",
              task_id: "task-1",
              status: "running",
              branch: "foreman/task-1",
              agent_type: "developer",
              session_key: null,
              worktree_path: null,
              progress: null,
              base_branch: null,
              merge_strategy: null,
              queued_at: "2026-01-01T00:00:00.000Z",
              started_at: "2026-01-01T00:01:00.000Z",
              finished_at: null,
              created_at: "2026-01-01T00:00:00.000Z",
            },
            {
              id: "run-2222",
              project_id: "proj-1",
              task_id: "task-2",
              status: "failure",
              branch: "foreman/task-2",
              agent_type: "developer",
              session_key: null,
              worktree_path: null,
              progress: null,
              base_branch: null,
              merge_strategy: null,
              queued_at: "2026-01-01T00:00:00.000Z",
              started_at: "2026-01-01T00:01:00.000Z",
              finished_at: null,
              created_at: "2026-01-01T00:00:00.000Z",
            },
          ]),
        },
      },
      projectId: "proj-1",
      projectPath: "/repo",
    } as any;

    await expect(resolveDaemonRun(context, "run-1111")).resolves.toMatchObject({ id: "run-1111", task_id: "task-1" });
    await expect(resolveDaemonRun(context, "run-22")).resolves.toMatchObject({ id: "run-2222", task_id: "task-2" });
    await expect(resolveDaemonRun(context, "task-2")).resolves.toMatchObject({ id: "run-2222", task_id: "task-2" });
    await expect(resolveDaemonRun(context, "missing")).resolves.toBeNull();
  });

  it("adapts daemon mail messages directly", () => {
    expect(adaptDaemonMessage({
      id: "msg-1",
      run_id: "run-1",
      sender_agent_type: "developer",
      recipient_agent_type: "qa",
      subject: "status",
      body: "{}",
      read: 0,
      created_at: "2026-01-01T00:00:00.000Z",
      deleted_at: null,
    })).toEqual({
      id: "msg-1",
      run_id: "run-1",
      sender_agent_type: "developer",
      recipient_agent_type: "qa",
      subject: "status",
      body: "{}",
      read: 0,
      created_at: "2026-01-01T00:00:00.000Z",
      deleted_at: null,
    });
  });

  it("daemon stream exits immediately when the current run is already terminal", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const context = {
      projectId: "proj-1",
      projectPath: "/repo",
      client: {
        mail: { list: vi.fn().mockResolvedValue([]) },
        runs: { get: vi.fn().mockResolvedValue({
          id: "run-1",
          project_id: "proj-1",
          task_id: "task-1",
          status: "success",
          branch: "foreman/task-1",
          agent_type: "developer",
          session_key: null,
          worktree_path: "/tmp/wt",
          progress: null,
          base_branch: null,
          merge_strategy: null,
          queued_at: "2026-01-01T00:00:00.000Z",
          started_at: "2026-01-01T00:01:00.000Z",
          finished_at: "2026-01-01T00:02:00.000Z",
          created_at: "2026-01-01T00:00:00.000Z",
        }) },
      },
    } as any;
    const run = { id: "run-1", task_id: "task-1", status: "running", worktree_path: "/tmp/wt" } as any;

    await expect(handleStreamDaemon(run, context)).resolves.toBe(0);
    expect(logSpy.mock.calls.some((call) => String(call[0]).includes("already completed"))).toBe(true);
  });

  it("daemon stream prints new messages and stops on terminal state", async () => {
    vi.useFakeTimers();
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const context = {
      projectId: "proj-1",
      projectPath: "/repo",
      client: {
        mail: { list: vi.fn()
          .mockResolvedValueOnce([{ id: "msg-1", run_id: "run-1", sender_agent_type: "developer", recipient_agent_type: "qa", subject: "first", body: "{}", read: 0, created_at: "2026-01-01T00:00:00.000Z", deleted_at: null }])
          .mockResolvedValueOnce([
            { id: "msg-1", run_id: "run-1", sender_agent_type: "developer", recipient_agent_type: "qa", subject: "first", body: "{}", read: 0, created_at: "2026-01-01T00:00:00.000Z", deleted_at: null },
            { id: "msg-2", run_id: "run-1", sender_agent_type: "developer", recipient_agent_type: "qa", subject: "second", body: "plain text", read: 0, created_at: "2026-01-01T00:01:00.000Z", deleted_at: null },
          ]) },
        runs: { get: vi.fn()
          .mockResolvedValueOnce({ id: "run-1", project_id: "proj-1", task_id: "task-1", status: "running", branch: "foreman/task-1", agent_type: "developer", session_key: null, worktree_path: "/tmp/wt", progress: null, base_branch: null, merge_strategy: null, queued_at: "2026-01-01T00:00:00.000Z", started_at: "2026-01-01T00:01:00.000Z", finished_at: null, created_at: "2026-01-01T00:00:00.000Z" })
          .mockResolvedValueOnce({ id: "run-1", project_id: "proj-1", task_id: "task-1", status: "success", branch: "foreman/task-1", agent_type: "developer", session_key: null, worktree_path: "/tmp/wt", progress: null, base_branch: null, merge_strategy: null, queued_at: "2026-01-01T00:00:00.000Z", started_at: "2026-01-01T00:01:00.000Z", finished_at: "2026-01-01T00:02:00.000Z", created_at: "2026-01-01T00:00:00.000Z" }) },
      },
    } as any;
    const run = { id: "run-1", task_id: "task-1", status: "running", worktree_path: "/tmp/wt" } as any;

    const promise = handleStreamDaemon(run, context, undefined, 50);
    await vi.advanceTimersByTimeAsync(60);
    await expect(promise).resolves.toBe(0);
    expect(logSpy.mock.calls.some((call) => String(call[0]).includes("second"))).toBe(true);
    expect(logSpy.mock.calls.some((call) => String(call[0]).includes("reached terminal state: completed"))).toBe(true);
    vi.useRealTimers();
  });
});
