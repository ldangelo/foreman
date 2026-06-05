import { describe, expect, it, vi } from "vitest";
import { stopAction, stopCommand } from "../commands/stop.js";
import type { Run } from "../../lib/store.js";

describe("stop command", () => {
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
