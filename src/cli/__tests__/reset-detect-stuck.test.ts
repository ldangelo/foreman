import { describe, it, expect, vi } from "vitest";
import { detectStuckRuns } from "../commands/reset.js";
import type { Run } from "../../lib/store.js";

// ── Helpers ──────────────────────────────────────────────────────────────────

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "seed-abc",
    agent_type: "claude-sonnet-4-6",
    session_key: null,
    worktree_path: "/tmp/wt",
    status: "running",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,    ...overrides,
  };
}

function makeMocks() {
  const store = {
    getActiveRuns: vi.fn((): Run[] => []),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
  };
  return { store };
}

// ── detectStuckRuns tests ─────────────────────────────────────────────────────

describe("detectStuckRuns", () => {
  it("returns empty result when there are no running runs", async () => {
    const { store } = makeMocks();
    store.getActiveRuns.mockReturnValue([]);

    const result = await detectStuckRuns(store as any, "proj-1");

    expect(result.stuck).toHaveLength(0);
    expect(result.errors).toHaveLength(0);
  });

  it("skips runs that are not in 'running' status", async () => {
    const { store } = makeMocks();
    const pendingRun = makeRun({ status: "pending" });
    const failedRun = makeRun({ status: "failed", id: "run-failed" });
    store.getActiveRuns.mockReturnValue([pendingRun, failedRun]);

    const result = await detectStuckRuns(store as any, "proj-1");

    expect(result.stuck).toHaveLength(0);
    expect(store.updateRun).not.toHaveBeenCalled();
  });

  it("detects stuck run when elapsed time exceeds timeout", async () => {
    const { store } = makeMocks();
    const thirtyMinAgo = new Date(Date.now() - 30 * 60 * 1000).toISOString();
    const run = makeRun({ started_at: thirtyMinAgo });
    store.getActiveRuns.mockReturnValue([run]);

    const result = await detectStuckRuns(store as any, "proj-1", {
      stuckTimeoutMinutes: 15,
    });

    expect(result.stuck).toHaveLength(1);
    expect(result.stuck[0].status).toBe("stuck");
    expect(store.updateRun).toHaveBeenCalledWith(run.id, { status: "stuck" });
    expect(store.logEvent).toHaveBeenCalledWith(
      run.project_id,
      "stuck",
      expect.objectContaining({ seedId: run.seed_id, detectedBy: "timeout" }),
      run.id,
    );
  });

  it("keeps recently-started run as active (not stuck)", async () => {
    const { store } = makeMocks();
    const run = makeRun({ started_at: new Date().toISOString() });
    store.getActiveRuns.mockReturnValue([run]);

    const result = await detectStuckRuns(store as any, "proj-1", {
      stuckTimeoutMinutes: 15,
    });

    expect(result.stuck).toHaveLength(0);
    expect(store.updateRun).not.toHaveBeenCalled();
  });

  it("does not update store in dry-run mode", async () => {
    const { store } = makeMocks();
    const thirtyMinAgo = new Date(Date.now() - 30 * 60 * 1000).toISOString();
    const run = makeRun({ started_at: thirtyMinAgo });
    store.getActiveRuns.mockReturnValue([run]);

    const result = await detectStuckRuns(store as any, "proj-1", {
      stuckTimeoutMinutes: 15,
      dryRun: true,
    });

    // Should report stuck, but not modify store
    expect(result.stuck).toHaveLength(1);
    expect(store.updateRun).not.toHaveBeenCalled();
    expect(store.logEvent).not.toHaveBeenCalled();
  });

  it("handles multiple runs: some stuck, some active", async () => {
    const { store } = makeMocks();
    const longAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const stuckRun = makeRun({ id: "run-stuck", seed_id: "seed-stuck", started_at: longAgo });
    const activeRun = makeRun({
      id: "run-active",
      seed_id: "seed-active",
      started_at: new Date().toISOString(),
    });
    store.getActiveRuns.mockReturnValue([stuckRun, activeRun]);

    const result = await detectStuckRuns(store as any, "proj-1", { stuckTimeoutMinutes: 15 });

    expect(result.stuck).toHaveLength(1);
    expect(result.stuck[0].seed_id).toBe("seed-stuck");
    expect(store.updateRun).toHaveBeenCalledTimes(1);
    expect(store.updateRun).toHaveBeenCalledWith("run-stuck", { status: "stuck" });
  });

  it("uses PIPELINE_LIMITS.stuckDetectionMinutes as default timeout", async () => {
    const { store } = makeMocks();
    // Started 16 minutes ago — should be stuck with default 15 min timeout
    const sixteenMinAgo = new Date(Date.now() - 16 * 60 * 1000).toISOString();
    const run = makeRun({ started_at: sixteenMinAgo });
    store.getActiveRuns.mockReturnValue([run]);

    // No timeout option — should use default (15 min)
    const result = await detectStuckRuns(store as any, "proj-1");

    expect(result.stuck).toHaveLength(1);
  });
});
