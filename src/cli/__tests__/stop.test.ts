import { beforeEach, describe, expect, it, vi } from "vitest";
import { listActiveRuns, stopAction, stopCommand } from "../commands/stop.js";
import type { Run } from "../../lib/store.js";

describe("stop command", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  it("loads the production command", () => {
    expect(stopCommand.name()).toBe("stop");
  });

  it("resolves bead IDs without querying getRun as a UUID", async () => {
    const run = makeRun({ id: "550e8400-e29b-41d4-a716-446655440000", seed_id: "foreman-e59b5" });
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "project-1", path: "/repo" }),
      getActiveRuns: vi.fn().mockResolvedValue([]),
      getRun: vi.fn().mockRejectedValue(new Error("should not query getRun for non-UUID bead id")),
      getRunsForSeed: vi.fn().mockResolvedValue([run]),
      updateRun: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };

    const exitCode = await stopAction("foreman-e59b5", { force: false, dryRun: true }, store, "/repo");

    expect(exitCode).toBe(0);
    expect(store.getRun).not.toHaveBeenCalled();
    expect(store.getRunsForSeed).toHaveBeenCalledWith("foreman-e59b5", "project-1");
  });

  it("resolves UUID run IDs before falling back to seed lookup", async () => {
    const run = makeRun({ id: "550e8400-e29b-41d4-a716-446655440000" });
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "project-1", path: "/repo" }),
      getActiveRuns: vi.fn().mockResolvedValue([]),
      getRun: vi.fn().mockResolvedValue(run),
      getRunsForSeed: vi.fn().mockResolvedValue([]),
      updateRun: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };

    const exitCode = await stopAction(run.id, { force: false, dryRun: true }, store, "/repo");

    expect(exitCode).toBe(0);
    expect(store.getRun).toHaveBeenCalledWith(run.id);
    expect(store.getRunsForSeed).not.toHaveBeenCalled();
  });

  it("returns 1 when no project is registered for --list", async () => {
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue(null),
      getActiveRuns: vi.fn().mockResolvedValue([]),
      getRun: vi.fn().mockResolvedValue(null),
      getRunsForSeed: vi.fn().mockResolvedValue([]),
      updateRun: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };

    const exitCode = await stopAction(undefined, { list: true }, store, "/repo");

    expect(exitCode).toBe(1);
    expect(store.getActiveRuns).not.toHaveBeenCalled();
  });

  it("returns 1 when a requested run cannot be found", async () => {
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "project-1", path: "/repo" }),
      getActiveRuns: vi.fn().mockResolvedValue([]),
      getRun: vi.fn().mockResolvedValue(null),
      getRunsForSeed: vi.fn().mockResolvedValue([]),
      updateRun: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };

    const exitCode = await stopAction("missing", { dryRun: true }, store, "/repo");

    expect(exitCode).toBe(1);
  });

  it("returns 0 when there are no active runs", async () => {
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "project-1", path: "/repo" }),
      getActiveRuns: vi.fn().mockResolvedValue([]),
      getRun: vi.fn().mockResolvedValue(null),
      getRunsForSeed: vi.fn().mockResolvedValue([]),
      updateRun: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };

    const exitCode = await stopAction(undefined, { dryRun: true }, store, "/repo");

    expect(exitCode).toBe(0);
    expect(store.getActiveRuns).toHaveBeenCalledWith("project-1");
  });

  it("dry-run stop-all succeeds for active runs without mutating them", async () => {
    const runs = [makeRun({ id: "run-1", seed_id: "seed-1" }), makeRun({ id: "run-2", seed_id: "seed-2", session_key: "pid-123" })];
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "project-1", path: "/repo" }),
      getActiveRuns: vi.fn().mockResolvedValue(runs),
      getRun: vi.fn().mockResolvedValue(null),
      getRunsForSeed: vi.fn().mockResolvedValue([]),
      updateRun: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };

    const killSpy = vi.spyOn(process, "kill").mockImplementation(() => true as never);
    const exitCode = await stopAction(undefined, { dryRun: true }, store, "/repo");

    expect(exitCode).toBe(0);
    expect(store.updateRun).not.toHaveBeenCalled();
    expect(store.logEvent).not.toHaveBeenCalled();
    expect(killSpy).toHaveBeenCalledWith(123, 0);
  });

  it("stops a single active run and marks it stuck", async () => {
    const run = makeRun({ id: "run-1", seed_id: "seed-1", session_key: "pid-321", status: "running" });
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "project-1", path: "/repo" }),
      getActiveRuns: vi.fn().mockResolvedValue([]),
      getRun: vi.fn().mockResolvedValue(null),
      getRunsForSeed: vi.fn().mockResolvedValue([run]),
      updateRun: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };

    const killSpy = vi.spyOn(process, "kill").mockImplementation(() => true as never);
    const exitCode = await stopAction("seed-1", {}, store, "/repo");

    expect(exitCode).toBe(0);
    expect(killSpy).toHaveBeenCalledWith(321, 0);
    expect(killSpy).toHaveBeenCalledWith(321, "SIGTERM");
    expect(store.updateRun).toHaveBeenCalledWith("run-1", expect.objectContaining({ status: "stuck" }));
    expect(store.logEvent).toHaveBeenCalledWith("project-1", "stuck", { reason: "foreman stop" }, "run-1");
  });

  it("uses SIGKILL when --force is set", async () => {
    const run = makeRun({ id: "run-1", seed_id: "seed-1", session_key: "pid-654", status: "pending" });
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "project-1", path: "/repo" }),
      getActiveRuns: vi.fn().mockResolvedValue([]),
      getRun: vi.fn().mockResolvedValue(null),
      getRunsForSeed: vi.fn().mockResolvedValue([run]),
      updateRun: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };

    const killSpy = vi.spyOn(process, "kill").mockImplementation(() => true as never);
    const exitCode = await stopAction("seed-1", { force: true }, store, "/repo");

    expect(exitCode).toBe(0);
    expect(killSpy).toHaveBeenCalledWith(654, "SIGKILL");
  });

  it("marks runs stuck even when no pid is available", async () => {
    const run = makeRun({ id: "run-1", seed_id: "seed-1", session_key: null, status: "running" });
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "project-1", path: "/repo" }),
      getActiveRuns: vi.fn().mockResolvedValue([]),
      getRun: vi.fn().mockResolvedValue(null),
      getRunsForSeed: vi.fn().mockResolvedValue([run]),
      updateRun: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };

    const exitCode = await stopAction("seed-1", {}, store, "/repo");

    expect(exitCode).toBe(0);
    expect(store.updateRun).toHaveBeenCalledWith("run-1", expect.objectContaining({ status: "stuck" }));
    expect(vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("no pid found");
  });

  it("returns 1 and prints summary errors when killing a run fails", async () => {
    const run = makeRun({ id: "run-1", seed_id: "seed-1", session_key: "pid-777", status: "running" });
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "project-1", path: "/repo" }),
      getActiveRuns: vi.fn().mockResolvedValue([run]),
      getRun: vi.fn().mockResolvedValue(null),
      getRunsForSeed: vi.fn().mockResolvedValue([]),
      updateRun: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };

    const killSpy = vi.spyOn(process, "kill").mockImplementation((pid: number, signal?: string | number) => {
      if (signal === 0) return true as never;
      throw new Error(`cannot kill ${pid}`);
    });
    const exitCode = await stopAction(undefined, {}, store, "/repo");

    expect(exitCode).toBe(1);
    expect(killSpy).toHaveBeenCalled();
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Errors (1):");
    expect(rendered).toContain("cannot kill");
  });
});

describe("listActiveRuns", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  it("errors when no project is registered", async () => {
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue(null),
      getActiveRuns: vi.fn().mockResolvedValue([]),
    } as any;

    await listActiveRuns(store, "/repo");

    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("No project registered for this directory");
  });

  it("prints a friendly message when there are no active runs", async () => {
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "project-1", path: "/repo" }),
      getActiveRuns: vi.fn().mockResolvedValue([]),
    } as any;

    await listActiveRuns(store, "/repo");

    expect(vi.mocked(console.log)).toHaveBeenCalledWith("No active runs found.");
  });

  it("renders active run rows with extracted pid information", async () => {
    const run = makeRun({
      seed_id: "seed-123",
      agent_type: "developer",
      session_key: "pid-4321",
      started_at: new Date().toISOString(),
    });
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "project-1", path: "/repo" }),
      getActiveRuns: vi.fn().mockResolvedValue([run]),
    } as any;

    await listActiveRuns(store, "/repo");

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Active runs:");
    expect(rendered).toContain("SEED");
    expect(rendered).toContain("AGENT");
    expect(rendered).toContain("PID");
    expect(rendered).toContain("seed-123");
    expect(rendered).toContain("4321");
  });
});

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "project-1",
    seed_id: "seed-1",
    agent_type: "minimax/MiniMax-M2.7",
    session_key: null,
    worktree_path: null,
    status: "running",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,
    ...overrides,
  };
}
