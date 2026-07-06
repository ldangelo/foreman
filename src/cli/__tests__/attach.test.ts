import { afterEach, describe, expect, it, vi } from "vitest";
import { attachAction, attachCommand, listSessionsEnhanced, listSessionsEnhancedDaemon } from "../commands/attach.js";

function makeMessage(overrides: Record<string, unknown> = {}) {
  return {
    id: "msg-1",
    run_id: "run-1",
    sender_agent_type: "developer",
    recipient_agent_type: "qa",
    subject: "status",
    body: JSON.stringify({ phase: "developer", status: "running" }),
    read: 0,
    created_at: "2026-01-01T00:00:00.000Z",
    deleted_at: null,
    ...overrides,
  };
}

function makeRun(overrides: Record<string, unknown> = {}) {
  return {
    id: "run-1",
    project_id: "project-1",
    task_id: "task-1",
    agent_type: "developer",
    session_key: null,
    worktree_path: "/tmp/worktree-1",
    status: "running",
    started_at: "2026-01-01T00:00:00.000Z",
    completed_at: null,
    created_at: "2026-01-01T00:00:00.000Z",
    progress: null,
    base_branch: null,
    merge_strategy: null,
    ...overrides,
  };
}

describe("attach command", () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("loads the production command", () => {
    expect(attachCommand.name()).toBe("attach");
  });

  it("returns 1 when no run matches", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const store = {
      getRun: vi.fn().mockReturnValue(null),
      getProjectByPath: vi.fn().mockReturnValue(null),
    } as any;

    await expect(attachAction("missing", {}, store, "/tmp/project")).resolves.toBe(1);
    expect(errorSpy).toHaveBeenCalledWith("No run found for \"missing\". Use 'foreman attach --list' to see available sessions.");
  });

  it("kills a local run without pid as a no-op success", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const store = {
      getRun: vi.fn().mockReturnValue(makeRun({ session_key: null })),
      updateRun: vi.fn(),
    } as any;

    await expect(attachAction("run-1", { kill: true }, store, "/tmp/project")).resolves.toBe(0);
    expect(logSpy).toHaveBeenCalledWith("No pid found for this run.");
    expect(store.updateRun).not.toHaveBeenCalled();
  });

  it("returns 1 when killing a local run fails", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const processKillSpy = vi.spyOn(process, "kill").mockImplementation(() => {
      throw new Error("permission denied");
    });
    const store = {
      getRun: vi.fn().mockReturnValue(makeRun({ session_key: "pid-999", status: "running" })),
      updateRun: vi.fn(),
    } as any;

    await expect(attachAction("run-1", { kill: true }, store, "/tmp/project")).resolves.toBe(1);
    expect(processKillSpy).toHaveBeenCalledWith(999, "SIGTERM");
    expect(errorSpy).toHaveBeenCalledWith("Failed to kill pid 999: permission denied");
    expect(store.updateRun).not.toHaveBeenCalled();
  });

  it("opens worktree mode only when the run has a worktree path", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const store = {
      getRun: vi.fn().mockReturnValue(makeRun({ worktree_path: null })),
    } as any;

    await expect(attachAction("run-1", { worktree: true }, store, "/tmp/project")).resolves.toBe(1);
    expect(errorSpy).toHaveBeenCalledWith("Run run-1 has no worktree path.");
  });

  it("lists local sessions with enriched output", () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const store = {
      getProjectByPath: vi.fn().mockReturnValue({ id: "project-1" }),
      getRunsByStatus: vi.fn((status: string) => {
        if (status === "running") {
          return [makeRun({ task_id: "task-running", progress: JSON.stringify({ currentPhase: "developer", toolCalls: 3, filesChanged: ["a.ts"], costUsd: 1.25 }) })];
        }
        if (status === "failed") {
          return [makeRun({ id: "run-2", task_id: "task-failed", status: "failed", progress: null })];
        }
        return [];
      }),
    } as any;

    listSessionsEnhanced(store, "/tmp/project");

    expect(logSpy).toHaveBeenCalledWith("Attachable sessions:\n");
    expect(logSpy.mock.calls.some((call) => String(call[0]).includes("task-running"))).toBe(true);
    expect(logSpy.mock.calls.some((call) => String(call[0]).includes("task-failed"))).toBe(true);
  });

  it("errors when listing local sessions without a registered project", () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const store = {
      getProjectByPath: vi.fn().mockReturnValue(null),
    } as any;

    listSessionsEnhanced(store, "/tmp/project");

    expect(errorSpy).toHaveBeenCalledWith("No project registered for this directory. Run 'foreman init' first.");
  });

  it("shows a friendly message when no local sessions exist", () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const store = {
      getProjectByPath: vi.fn().mockReturnValue({ id: "project-1" }),
      getRunsByStatus: vi.fn().mockReturnValue([]),
    } as any;

    listSessionsEnhanced(store, "/tmp/project");

    expect(logSpy).toHaveBeenCalledWith("No sessions found.");
  });

  it("streams local agent mail and exits immediately for terminal runs", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const store = {
      getRun: vi
        .fn()
        .mockReturnValueOnce(makeRun({ status: "running" }))
        .mockReturnValueOnce(makeRun({ status: "completed" })),
      getAllMessages: vi.fn().mockReturnValue([makeMessage()]),
    } as any;

    await expect(attachAction("run-1", { stream: true }, store, "/tmp/project")).resolves.toBe(0);
    expect(store.getAllMessages).toHaveBeenCalledWith("run-1");
    expect(logSpy.mock.calls.some((call) => String(call[0]).includes("Run task-1 is already completed."))).toBe(true);
  });

  it("streams new messages until the run reaches a terminal state", async () => {
    vi.useFakeTimers();
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const abort = new AbortController();
    const message1 = makeMessage({ id: "msg-1" });
    const message2 = makeMessage({ id: "msg-2", subject: "done", body: "plain text update" });
    const store = {
      getRun: vi
        .fn()
        .mockReturnValueOnce(makeRun({ status: "running" }))
        .mockReturnValueOnce(makeRun({ status: "running" }))
        .mockReturnValueOnce(makeRun({ status: "completed" })),
      getAllMessages: vi
        .fn()
        .mockReturnValueOnce([message1])
        .mockReturnValueOnce([message1, message2]),
    } as any;

    const promise = attachAction("run-1", { stream: true, _signal: abort.signal, _pollIntervalMs: 50 }, store, "/tmp/project");
    await vi.advanceTimersByTimeAsync(60);
    await expect(promise).resolves.toBe(0);
    expect(logSpy.mock.calls.some((call) => String(call[0]).includes("done"))).toBe(true);
    expect(logSpy.mock.calls.some((call) => String(call[0]).includes("reached terminal state: completed"))).toBe(true);
  });

  it("stops streaming when aborted", async () => {
    vi.useFakeTimers();
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const abort = new AbortController();
    const store = {
      getRun: vi.fn().mockReturnValue(makeRun({ status: "running" })),
      getAllMessages: vi.fn().mockReturnValue([]),
    } as any;

    const promise = attachAction("run-1", { stream: true, _signal: abort.signal, _pollIntervalMs: 100 }, store, "/tmp/project");
    abort.abort();
    await expect(promise).resolves.toBe(0);
    expect(logSpy.mock.calls.some((call) => String(call[0]).includes("Stream interrupted."))).toBe(true);
  });

  it("lists daemon sessions with adapted rows", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const daemon = {
      projectId: "project-1",
      projectPath: "/tmp/project",
      client: {
        runs: {
          list: vi.fn().mockResolvedValue([
            {
              id: "run-1",
              project_id: "project-1",
              bead_id: "task-running",
              status: "running",
              branch: "feature/a",
              agent_type: "developer",
              session_key: null,
              worktree_path: "/tmp/worktree-1",
              progress: null,
              base_branch: null,
              merge_strategy: null,
              queued_at: "2026-01-01T00:00:00.000Z",
              started_at: "2026-01-01T00:00:00.000Z",
              finished_at: null,
              created_at: "2026-01-01T00:00:00.000Z",
            },
          ]),
        },
      },
    } as any;

    await listSessionsEnhancedDaemon(daemon);

    expect(logSpy).toHaveBeenCalledWith("Attachable sessions:\n");
    expect(logSpy.mock.calls.some((call) => String(call[0]).includes("task-running"))).toBe(true);
  });

  it("shows a friendly message when no daemon sessions exist", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const daemon = {
      projectId: "project-1",
      projectPath: "/tmp/project",
      client: {
        runs: {
          list: vi.fn().mockResolvedValue([]),
        },
      },
    } as any;

    await listSessionsEnhancedDaemon(daemon);

    expect(logSpy).toHaveBeenCalledWith("No sessions found.");
  });

  it("kills daemon runs via daemon status update before sending SIGTERM", async () => {
    const processKillSpy = vi.spyOn(process, "kill").mockImplementation(() => true as never);
    const store = {
      getRun: vi.fn().mockReturnValue(makeRun({ session_key: "pid-777", status: "running" })),
      updateRun: vi.fn(),
    } as any;
    const daemon = {
      projectId: "project-1",
      projectPath: "/tmp/project",
      client: {
        runs: {
          list: vi.fn().mockResolvedValue([
            {
              id: "run-1",
              project_id: "project-1",
              bead_id: "task-1",
              status: "running",
              branch: "feature/a",
              agent_type: "developer",
              session_key: "pid-777",
              worktree_path: "/tmp/worktree-1",
              progress: null,
              base_branch: null,
              merge_strategy: null,
              queued_at: "2026-01-01T00:00:00.000Z",
              started_at: "2026-01-01T00:00:00.000Z",
              finished_at: null,
              created_at: "2026-01-01T00:00:00.000Z",
            },
          ]),
          updateStatus: vi.fn().mockResolvedValue(undefined),
        },
      },
    } as any;

    await expect(attachAction("run-1", { kill: true }, store, "/tmp/project", daemon)).resolves.toBe(0);
    expect(daemon.client.runs.updateStatus).toHaveBeenCalledWith({ runId: "run-1", status: "stuck" });
    expect(processKillSpy).toHaveBeenCalledWith(777, "SIGTERM");
    expect(store.updateRun).not.toHaveBeenCalled();
  });

  it("falls back to local kill when daemon status update fails", async () => {
    const processKillSpy = vi.spyOn(process, "kill").mockImplementation(() => true as never);
    const store = {
      getRun: vi.fn().mockReturnValue(makeRun({ session_key: "pid-888", status: "pending" })),
      updateRun: vi.fn(),
    } as any;
    const daemon = {
      projectId: "project-1",
      projectPath: "/tmp/project",
      client: {
        runs: {
          list: vi.fn().mockResolvedValue([
            {
              id: "run-1",
              project_id: "project-1",
              bead_id: "task-1",
              status: "running",
              branch: "feature/a",
              agent_type: "developer",
              session_key: "pid-888",
              worktree_path: "/tmp/worktree-1",
              progress: null,
              base_branch: null,
              merge_strategy: null,
              queued_at: "2026-01-01T00:00:00.000Z",
              started_at: "2026-01-01T00:00:00.000Z",
              finished_at: null,
              created_at: "2026-01-01T00:00:00.000Z",
            },
          ]),
          updateStatus: vi.fn().mockRejectedValue(new Error("daemon unavailable")),
        },
      },
    } as any;

    await expect(attachAction("run-1", { kill: true }, store, "/tmp/project", daemon)).resolves.toBe(0);
    expect(processKillSpy).toHaveBeenCalledWith(888, "SIGTERM");
    expect(store.updateRun).toHaveBeenCalledWith("run-1", { status: "stuck" });
  });

  it("treats daemon kills without a pid as a no-op success", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const store = {
      getRun: vi.fn().mockReturnValue(null),
      getProjectByPath: vi.fn().mockReturnValue(null),
      updateRun: vi.fn(),
    } as any;
    const daemon = {
      projectId: "project-1",
      projectPath: "/tmp/project",
      client: {
        runs: {
          list: vi.fn().mockResolvedValue([
            {
              id: "run-1",
              project_id: "project-1",
              bead_id: "task-1",
              status: "running",
              branch: "feature/a",
              agent_type: "developer",
              session_key: null,
              worktree_path: "/tmp/worktree-1",
              progress: null,
              base_branch: null,
              merge_strategy: null,
              queued_at: "2026-01-01T00:00:00.000Z",
              started_at: "2026-01-01T00:00:00.000Z",
              finished_at: null,
              created_at: "2026-01-01T00:00:00.000Z",
            },
          ]),
          updateStatus: vi.fn(),
        },
      },
    } as any;

    await expect(attachAction("run-1", { kill: true }, store, "/tmp/project", daemon)).resolves.toBe(0);
    expect(logSpy).toHaveBeenCalledWith("No pid found for this run.");
    expect(daemon.client.runs.updateStatus).not.toHaveBeenCalled();
  });
});
