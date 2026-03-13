import { describe, it, expect, vi } from "vitest";
import { Monitor } from "../monitor.js";
import type { Run } from "../../lib/store.js";
import type { TmuxClient } from "../../lib/tmux.js";

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "seeds-001",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: "/tmp/wt",
    status: "running",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,
    tmux_session: null,
    ...overrides,
  };
}

function makeMocks() {
  const store = {
    getActiveRuns: vi.fn((): Run[] => []),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    getRunEvents: vi.fn((): unknown[] => []),
  };
  const seeds = {
    show: vi.fn(async () => ({ status: "open" })),
  };
  const tmux: { hasSession: ReturnType<typeof vi.fn> } = {
    hasSession: vi.fn(async () => true),
  };
  const monitor = new Monitor(
    store as unknown as Parameters<typeof Monitor.prototype.checkAll>[0] extends undefined ? never : any,
    seeds as any,
    "/tmp/project",
    tmux as unknown as TmuxClient,
  );
  return { store, seeds, tmux, monitor };
}

describe("Monitor — tmux liveness (AT-T031 / AT-T032)", () => {
  it("active run with live tmux session follows normal flow", async () => {
    const { store, seeds, tmux, monitor } = makeMocks();
    const run = makeRun({ tmux_session: "foreman-seeds-001" });
    store.getActiveRuns.mockReturnValue([run]);
    seeds.show.mockResolvedValue({ status: "open" });
    tmux.hasSession.mockResolvedValue(true);

    const report = await monitor.checkAll({ stuckTimeoutMinutes: 60 });

    // Should be active — tmux is alive and seed is open
    expect(report.active).toHaveLength(1);
    expect(report.stuck).toHaveLength(0);
    expect(tmux.hasSession).toHaveBeenCalledWith("foreman-seeds-001");
  });

  it("dead tmux session marks run as stuck immediately", async () => {
    const { store, seeds, tmux, monitor } = makeMocks();
    const run = makeRun({
      tmux_session: "foreman-seeds-001",
      started_at: new Date().toISOString(), // just started — would NOT be stuck by timeout
    });
    store.getActiveRuns.mockReturnValue([run]);
    seeds.show.mockResolvedValue({ status: "open" });
    tmux.hasSession.mockResolvedValue(false);

    const report = await monitor.checkAll({ stuckTimeoutMinutes: 60 });

    expect(report.stuck).toHaveLength(1);
    expect(report.stuck[0].status).toBe("stuck");
    expect(store.updateRun).toHaveBeenCalledWith(run.id, { status: "stuck" });
  });

  it("dead tmux session logs correct event details", async () => {
    const { store, seeds, tmux, monitor } = makeMocks();
    const run = makeRun({
      tmux_session: "foreman-seeds-001",
      started_at: new Date().toISOString(),
    });
    store.getActiveRuns.mockReturnValue([run]);
    seeds.show.mockResolvedValue({ status: "open" });
    tmux.hasSession.mockResolvedValue(false);

    await monitor.checkAll({ stuckTimeoutMinutes: 60 });

    expect(store.logEvent).toHaveBeenCalledWith(
      run.project_id,
      "stuck",
      expect.objectContaining({
        seedId: run.seed_id,
        detectedBy: "tmux-liveness",
        tmuxSession: "foreman-seeds-001",
      }),
      run.id,
    );
  });

  it("run without tmux_session falls back to existing timeout heuristic", async () => {
    const { store, seeds, tmux, monitor } = makeMocks();
    // Started 30 min ago — should be caught by 15 min timeout
    const thirtyMinAgo = new Date(Date.now() - 30 * 60 * 1000).toISOString();
    const run = makeRun({
      tmux_session: null,
      started_at: thirtyMinAgo,
    });
    store.getActiveRuns.mockReturnValue([run]);
    seeds.show.mockResolvedValue({ status: "open" });

    const report = await monitor.checkAll({ stuckTimeoutMinutes: 15 });

    expect(report.stuck).toHaveLength(1);
    // tmux.hasSession should NOT be called when no tmux_session
    expect(tmux.hasSession).not.toHaveBeenCalled();
  });

  it("tmux liveness check runs BEFORE seed-status check", async () => {
    const { store, seeds, tmux, monitor } = makeMocks();
    const run = makeRun({
      tmux_session: "foreman-seeds-001",
    });
    store.getActiveRuns.mockReturnValue([run]);
    tmux.hasSession.mockResolvedValue(false);
    // Even though seed says "closed", dead tmux should be caught first
    seeds.show.mockResolvedValue({ status: "closed" });

    const report = await monitor.checkAll({ stuckTimeoutMinutes: 60 });

    // Should be stuck (tmux dead), not completed (seed closed)
    expect(report.stuck).toHaveLength(1);
    expect(report.completed).toHaveLength(0);
  });

  it("monitor works without tmux client (backwards compatible)", async () => {
    const store = {
      getActiveRuns: vi.fn(() => [] as Run[]),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      getRunEvents: vi.fn((): unknown[] => []),
    };
    const seeds = {
      show: vi.fn(async () => ({ status: "open" })),
    };
    // No tmux client passed
    const monitor = new Monitor(store as any, seeds as any, "/tmp/project");

    const run = makeRun({ started_at: new Date().toISOString() });
    store.getActiveRuns.mockReturnValue([run]);

    const report = await monitor.checkAll({ stuckTimeoutMinutes: 60 });

    // Should work fine without tmux — normal active result
    expect(report.active).toHaveLength(1);
  });
});
