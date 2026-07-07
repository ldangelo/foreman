import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
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

const fetchSpy = vi.spyOn(globalThis, "fetch");

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: localForProject,
  },
}));

const { updateFatalRunStatus } = await import("../agent-worker-fatal-path.js");

afterAll(() => {
  fetchSpy.mockRestore();
});

function jsonResponse(body: unknown, ok = true, status = 200): Response {
  return { ok, status, json: vi.fn().mockResolvedValue(body) } as unknown as Response;
}

describe("agent-worker fatal-path run-status repair", () => {
  beforeEach(() => {
    localGetRun.mockReset();
    localUpdateRun.mockReset();
    localClose.mockReset();
    localForProject.mockClear();
    fetchSpy.mockReset();
    localGetRun.mockReturnValue(null);
    fetchSpy
      .mockResolvedValueOnce(jsonResponse({ ok: true, runs: [] }))
      .mockResolvedValueOnce(jsonResponse({ ok: true }));
  });

  it("uses Elixir for registered fatal run-status updates", async () => {
    await updateFatalRunStatus({
      runId: "run-1",
      projectId: "proj-1",
      projectPath: "/tmp/local-project",
      completedAt: "2026-04-25T00:00:00.000Z",
    });

    expect(String(fetchSpy.mock.calls[0][0])).toContain("/api/v1/runs?project_id=proj-1");
    const command = JSON.parse(String((fetchSpy.mock.calls[1][1] as RequestInit).body));
    expect(command).toMatchObject({
      command_type: "run.update",
      payload: {
        run_id: "run-1",
        project_id: "proj-1",
        status: "failed",
        completed_at: "2026-04-25T00:00:00.000Z",
      },
    });
    expect(localForProject).not.toHaveBeenCalled();
  });

  it("preserves a registered pr-created run instead of downgrading it to failed", async () => {
    fetchSpy
      .mockReset()
      .mockResolvedValueOnce(jsonResponse({ ok: true, runs: [{ run_id: "run-pr", status: "pr-created" }] }));

    await updateFatalRunStatus({
      runId: "run-pr",
      projectId: "proj-pr",
      projectPath: "/tmp/local-project",
      completedAt: "2026-04-25T00:00:30.000Z",
    });

    expect(fetchSpy).toHaveBeenCalledTimes(1);
  });

  it("uses ForemanStore for local fatal run-status updates", async () => {
    await updateFatalRunStatus({
      runId: "run-2",
      projectPath: "/tmp/local-project",
      completedAt: "2026-04-25T00:01:00.000Z",
    });

    expect(localForProject).toHaveBeenCalledWith("/tmp/local-project");
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(localUpdateRun).toHaveBeenCalledWith("run-2", {
      status: "failed",
      completed_at: "2026-04-25T00:01:00.000Z",
    });
    expect(localClose).toHaveBeenCalled();
  });

  it("preserves a local merged run instead of downgrading it to failed", async () => {
    localGetRun.mockReturnValueOnce({ id: "run-merged", status: "merged" });

    await updateFatalRunStatus({
      runId: "run-merged",
      projectPath: "/tmp/local-project",
      completedAt: "2026-04-25T00:01:30.000Z",
    });

    expect(localUpdateRun).not.toHaveBeenCalled();
  });

  it("threads cfg.projectId into fatalHandler's fatal-path helper call", () => {
    const sourcePath = fileURLToPath(new URL("../agent-worker.ts", import.meta.url));
    const source = readFileSync(sourcePath, "utf8");

    expect(source).toContain("import { updateFatalRunStatus } from \"./agent-worker-fatal-path.js\";");
    expect(source).toContain("projectId = cfg.projectId;");
    expect(source).toContain("await updateFatalRunStatus({");
    expect(source).toContain("projectId,");
  });
});
