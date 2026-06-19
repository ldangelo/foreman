import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { beforeEach, describe, expect, it, vi } from "vitest";

const localGetRun = vi.fn();
const localUpdateRun = vi.fn();
const localClose = vi.fn();
const pgGetRun = vi.fn();
const pgUpdateRun = vi.fn();
const pgClose = vi.fn();
const localForProject = vi.fn(() => ({ getRun: localGetRun, updateRun: localUpdateRun, close: localClose }));
const pgForProject = vi.fn(() => ({ getRun: pgGetRun, updateRun: pgUpdateRun, close: pgClose }));

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

const { updateFatalRunStatus } = await import("../agent-worker-fatal-path.js");

describe("agent-worker fatal-path run-status repair", () => {
  beforeEach(() => {
    localGetRun.mockReset();
    localUpdateRun.mockReset();
    localClose.mockReset();
    pgGetRun.mockReset();
    pgUpdateRun.mockReset();
    pgClose.mockReset();
    localForProject.mockClear();
    pgForProject.mockClear();
    localGetRun.mockReturnValue(null);
    pgGetRun.mockResolvedValue(null);
  });

  it("uses PostgresStore for registered fatal run-status updates", async () => {
    await updateFatalRunStatus({
      runId: "run-1",
      projectId: "proj-1",
      projectPath: "/tmp/local-project",
      completedAt: "2026-04-25T00:00:00.000Z",
    });

    expect(pgForProject).toHaveBeenCalledWith("proj-1");
    expect(localForProject).not.toHaveBeenCalled();
    expect(pgUpdateRun).toHaveBeenCalledWith("run-1", {
      status: "failed",
      completed_at: "2026-04-25T00:00:00.000Z",
    });
    expect(pgClose).toHaveBeenCalled();
  });

  it("preserves a registered pr-created run instead of downgrading it to failed", async () => {
    pgGetRun.mockResolvedValueOnce({ id: "run-pr", status: "pr-created" });

    await updateFatalRunStatus({
      runId: "run-pr",
      projectId: "proj-pr",
      projectPath: "/tmp/local-project",
      completedAt: "2026-04-25T00:00:30.000Z",
    });

    expect(pgUpdateRun).not.toHaveBeenCalled();
  });

  it("uses ForemanStore for local fatal run-status updates", async () => {
    await updateFatalRunStatus({
      runId: "run-2",
      projectPath: "/tmp/local-project",
      completedAt: "2026-04-25T00:01:00.000Z",
    });

    expect(localForProject).toHaveBeenCalledWith("/tmp/local-project");
    expect(pgForProject).not.toHaveBeenCalled();
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
