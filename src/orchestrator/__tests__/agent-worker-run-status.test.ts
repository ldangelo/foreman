import { afterAll, beforeEach, describe, expect, it, vi } from "vitest";

const {
  localGetRun,
  localUpdateRun,
  localClose,
  localForProject,
} = vi.hoisted(() => {
  const localGetRun = vi.fn();
  const localUpdateRun = vi.fn();
  const localClose = vi.fn();
  const localForProject = vi.fn(() => ({ getRun: localGetRun, updateRun: localUpdateRun, close: localClose }));
  return { localGetRun, localUpdateRun, localClose, localForProject };
});

const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
const fetchSpy = vi.spyOn(globalThis, "fetch");

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: localForProject,
  },
}));

const { updateTerminalRunStatus } = await import("../agent-worker-run-status.js");

afterAll(() => {
  fetchSpy.mockRestore();
  warnSpy.mockRestore();
});

function jsonResponse(body: unknown, ok = true, status = 200): Response {
  return { ok, status, json: vi.fn().mockResolvedValue(body) } as unknown as Response;
}

describe("updateTerminalRunStatus", () => {
  beforeEach(() => {
    localGetRun.mockReset();
    localUpdateRun.mockReset();
    localClose.mockReset();
    localForProject.mockClear();
    warnSpy.mockClear();
    fetchSpy.mockReset();
    localGetRun.mockReturnValue(null);
    fetchSpy
      .mockResolvedValueOnce(jsonResponse({ ok: true, runs: [] }))
      .mockResolvedValueOnce(jsonResponse({ ok: true }));
  });

  it("uses Elixir first for registered terminal updates and skips local fallback on success", async () => {
    await updateTerminalRunStatus({
      runId: "run-1",
      projectId: "proj-1",
      projectPath: "/tmp/project",
      updates: { status: "completed", completed_at: "2026-04-25T00:00:00.000Z" },
    });

    expect(String(fetchSpy.mock.calls[0][0])).toContain("/api/v1/runs?project_id=proj-1");
    expect(String(fetchSpy.mock.calls[1][0])).toContain("/api/v1/commands");
    expect(JSON.parse(String((fetchSpy.mock.calls[1][1] as RequestInit).body))).toMatchObject({
      command_type: "run.update",
      payload: {
        run_id: "run-1",
        project_id: "proj-1",
        status: "completed",
        completed_at: "2026-04-25T00:00:00.000Z",
      },
    });
    expect(localForProject).not.toHaveBeenCalled();
    expect(localUpdateRun).not.toHaveBeenCalled();
    expect(localClose).not.toHaveBeenCalled();
  });

  it.each(["failed", "merged"] as const)(
    "syncs registered task status when a run reaches '%s'",
    async (status) => {
      fetchSpy
        .mockReset()
        .mockResolvedValueOnce(jsonResponse({ ok: true, runs: [{ run_id: `run-${status}`, task_id: `task-${status}` }] }))
        .mockResolvedValueOnce(jsonResponse({ ok: true }))
        .mockResolvedValueOnce(jsonResponse({ ok: true }));

      await updateTerminalRunStatus({
        runId: `run-${status}`,
        projectId: `proj-${status}`,
        projectPath: `/tmp/project-${status}`,
        updates: { status, completed_at: "2026-04-25T00:01:00.000Z" },
      });

      const runCommand = JSON.parse(String((fetchSpy.mock.calls[1][1] as RequestInit).body));
      expect(runCommand).toMatchObject({
        command_type: "run.update",
        payload: { run_id: `run-${status}`, project_id: `proj-${status}`, status },
      });
      const taskCommand = JSON.parse(String((fetchSpy.mock.calls[2][1] as RequestInit).body));
      expect(taskCommand).toMatchObject({
        command_type: "task.update",
        payload: { task_id: `task-${status}`, project_id: `proj-${status}`, status },
      });
      expect(localForProject).not.toHaveBeenCalled();
    },
  );

  it("preserves a registered pr-created run instead of downgrading it to failed", async () => {
    fetchSpy
      .mockReset()
      .mockResolvedValueOnce(jsonResponse({ ok: true, runs: [{ run_id: "run-keep", status: "pr-created" }] }));

    await updateTerminalRunStatus({
      runId: "run-keep",
      projectId: "proj-keep",
      projectPath: "/tmp/project-keep",
      updates: { status: "failed", completed_at: "2026-04-25T00:01:00.000Z" },
    });

    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect(localForProject).not.toHaveBeenCalled();
  });

  it("preserves a local merged run instead of downgrading it to stuck", async () => {
    localGetRun.mockReturnValueOnce({ id: "run-keep-local", status: "merged" });

    await updateTerminalRunStatus({
      runId: "run-keep-local",
      projectPath: "/tmp/local-project",
      updates: { status: "stuck", completed_at: "2026-04-25T00:02:00.000Z" },
    });

    expect(localUpdateRun).not.toHaveBeenCalled();
  });

  it("falls back to local store when Elixir update fails and stays non-fatal", async () => {
    fetchSpy
      .mockReset()
      .mockResolvedValueOnce(jsonResponse({ ok: true, runs: [] }))
      .mockRejectedValueOnce(new Error("elixir down"));

    await expect(updateTerminalRunStatus({
      runId: "run-3",
      projectId: "proj-3",
      projectPath: "/tmp/project-3",
      updates: { status: "failed", completed_at: "2026-04-25T00:01:00.000Z" },
    })).resolves.toBeUndefined();

    expect(String(fetchSpy.mock.calls[0][0])).toContain("project_id=proj-3");
    expect(localForProject).toHaveBeenCalledWith("/tmp/project-3");
    expect(localUpdateRun).toHaveBeenCalledWith("run-3", {
      status: "failed",
      completed_at: "2026-04-25T00:01:00.000Z",
    });
    expect(warnSpy).toHaveBeenCalled();
    expect(localClose).toHaveBeenCalled();
  });

  it("uses local store only when projectId is absent", async () => {
    await updateTerminalRunStatus({
      runId: "run-3",
      projectPath: "/tmp/local-project",
      updates: { status: "stuck", completed_at: "2026-04-25T00:02:00.000Z" },
    });

    expect(fetchSpy).not.toHaveBeenCalled();
    expect(localForProject).toHaveBeenCalledWith("/tmp/local-project");
    expect(localUpdateRun).toHaveBeenCalledWith("run-3", {
      status: "stuck",
      completed_at: "2026-04-25T00:02:00.000Z",
    });
    expect(localClose).toHaveBeenCalled();
  });
});
