import { beforeEach, describe, expect, it, vi } from "vitest";

const localUpdateRun = vi.fn();
const localClose = vi.fn();
const pgUpdateRun = vi.fn();
const pgClose = vi.fn();
const localForProject = vi.fn(() => ({ updateRun: localUpdateRun, close: localClose }));
const pgForProject = vi.fn(() => ({ updateRun: pgUpdateRun, close: pgClose }));
const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: localForProject,
  },
}));

vi.mock("../../lib/postgres-store.js", () => ({
  PostgresStore: {
    forProject: pgForProject,
  },
}));

const { updateTerminalRunStatus } = await import("../agent-worker-run-status.js");

describe("updateTerminalRunStatus", () => {
  beforeEach(() => {
    localUpdateRun.mockReset();
    localClose.mockReset();
    pgUpdateRun.mockReset();
    pgClose.mockReset();
    localForProject.mockClear();
    pgForProject.mockClear();
    warnSpy.mockClear();
  });

  it("uses Postgres first for registered terminal updates and skips local fallback on success", async () => {
    await updateTerminalRunStatus({
      runId: "run-1",
      projectId: "proj-1",
      projectPath: "/tmp/project",
      updates: { status: "completed", completed_at: "2026-04-25T00:00:00.000Z" },
    });

    expect(pgForProject).toHaveBeenCalledWith("proj-1");
    expect(pgUpdateRun).toHaveBeenCalledWith("run-1", {
      status: "completed",
      completed_at: "2026-04-25T00:00:00.000Z",
    });
    expect(localForProject).not.toHaveBeenCalled();
    expect(localUpdateRun).not.toHaveBeenCalled();
    expect(pgClose).toHaveBeenCalled();
    expect(localClose).not.toHaveBeenCalled();
  });

  it("falls back to local store when Postgres update fails and stays non-fatal", async () => {
    pgUpdateRun.mockRejectedValueOnce(new Error("pg down"));

    await expect(updateTerminalRunStatus({
      runId: "run-2",
      projectId: "proj-2",
      projectPath: "/tmp/project-2",
      updates: { status: "failed", completed_at: "2026-04-25T00:01:00.000Z" },
    })).resolves.toBeUndefined();

    expect(pgForProject).toHaveBeenCalledWith("proj-2");
    expect(localForProject).toHaveBeenCalledWith("/tmp/project-2");
    expect(localUpdateRun).toHaveBeenCalledWith("run-2", {
      status: "failed",
      completed_at: "2026-04-25T00:01:00.000Z",
    });
    expect(warnSpy).toHaveBeenCalled();
    expect(pgClose).toHaveBeenCalled();
    expect(localClose).toHaveBeenCalled();
  });

  it("uses local store only when projectId is absent", async () => {
    await updateTerminalRunStatus({
      runId: "run-3",
      projectPath: "/tmp/local-project",
      updates: { status: "stuck", completed_at: "2026-04-25T00:02:00.000Z" },
    });

    expect(pgForProject).not.toHaveBeenCalled();
    expect(localForProject).toHaveBeenCalledWith("/tmp/local-project");
    expect(localUpdateRun).toHaveBeenCalledWith("run-3", {
      status: "stuck",
      completed_at: "2026-04-25T00:02:00.000Z",
    });
    expect(localClose).toHaveBeenCalled();
  });
});
