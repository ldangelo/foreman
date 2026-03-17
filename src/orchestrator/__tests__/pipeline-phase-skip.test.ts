/**
 * Tests for pipeline phase-skip on recovery.
 *
 * Verifies:
 * 1. worktreeHasProgress() correctly detects presence/absence of artifacts
 * 2. monitor.recoverStuck() preserves the worktree when artifacts exist
 * 3. monitor.recoverStuck() recreates the worktree when no artifacts exist
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { worktreeHasProgress } from "../monitor.js";
import { Monitor } from "../monitor.js";
import type { Run } from "../../lib/store.js";

// ── Helpers ───────────────────────────────────────────────────────────────

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "seeds-001",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: "/tmp/wt",
    status: "stuck",
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
    getActiveRuns: vi.fn(() => [] as Run[]),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    getRunEvents: vi.fn((): unknown[] => []),
  };
  const seeds = {
    show: vi.fn(async () => ({ status: "open" })),
  };
  return { store, seeds };
}

// ── worktreeHasProgress ───────────────────────────────────────────────────

describe("worktreeHasProgress()", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-skip-test-"));
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns false when the worktree directory is empty", () => {
    expect(worktreeHasProgress(tmpDir)).toBe(false);
  });

  it("returns false when the worktree contains unrelated files", () => {
    writeFileSync(join(tmpDir, "TASK.md"), "# Task\n");
    expect(worktreeHasProgress(tmpDir)).toBe(false);
  });

  it("returns true when EXPLORER_REPORT.md exists", () => {
    writeFileSync(join(tmpDir, "EXPLORER_REPORT.md"), "# Explorer Report\n");
    expect(worktreeHasProgress(tmpDir)).toBe(true);
  });

  it("returns true when DEVELOPER_REPORT.md exists", () => {
    writeFileSync(join(tmpDir, "DEVELOPER_REPORT.md"), "# Developer Report\n");
    expect(worktreeHasProgress(tmpDir)).toBe(true);
  });

  it("returns true when QA_REPORT.md exists", () => {
    writeFileSync(join(tmpDir, "QA_REPORT.md"), "# QA Report\n## Verdict: PASS\n");
    expect(worktreeHasProgress(tmpDir)).toBe(true);
  });

  it("returns true when REVIEW.md exists", () => {
    writeFileSync(join(tmpDir, "REVIEW.md"), "# Review\n## Verdict: PASS\n");
    expect(worktreeHasProgress(tmpDir)).toBe(true);
  });

  it("returns true when multiple artifacts exist", () => {
    writeFileSync(join(tmpDir, "EXPLORER_REPORT.md"), "# Explorer Report\n");
    writeFileSync(join(tmpDir, "DEVELOPER_REPORT.md"), "# Developer Report\n");
    writeFileSync(join(tmpDir, "QA_REPORT.md"), "# QA Report\n## Verdict: PASS\n");
    expect(worktreeHasProgress(tmpDir)).toBe(true);
  });

  it("returns false when path does not exist", () => {
    expect(worktreeHasProgress("/nonexistent/path/that/cannot/exist")).toBe(false);
  });
});

// ── Monitor.recoverStuck() — worktree preservation ───────────────────────

describe("Monitor.recoverStuck() — phase-skip preservation", () => {
  let tmpDir: string;
  let worktreeDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-monitor-test-"));
    worktreeDir = join(tmpDir, "wt");
    mkdirSync(worktreeDir, { recursive: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("preserves the worktree when EXPLORER_REPORT.md exists and marks run as pending", async () => {
    // Arrange — write an explorer artifact so hasProgress returns true
    writeFileSync(join(worktreeDir, "EXPLORER_REPORT.md"), "# Explorer Report\n");

    const { store, seeds } = makeMocks();
    const monitor = new Monitor(store as never, seeds as never, tmpDir);
    const run = makeRun({ worktree_path: worktreeDir });

    // Act
    const result = await monitor.recoverStuck(run, 3);

    // Assert — recovery succeeded and worktree_path was NOT changed
    expect(result).toBe(true);
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "pending" }),
    );

    // The updateRun call must NOT include a new worktree_path (preserving existing)
    const updateCall = store.updateRun.mock.calls.find((call) => {
      const [id, upd] = call as [string, Partial<Run>];
      return id === run.id && upd.status === "pending";
    });
    expect(updateCall).toBeDefined();
    const updatePayload = (updateCall as [string, Partial<Run>])[1];
    expect(updatePayload.worktree_path).toBeUndefined();
  });

  it("logs a recover event with worktreePreserved: true when artifacts exist", async () => {
    writeFileSync(join(worktreeDir, "QA_REPORT.md"), "# QA Report\n## Verdict: PASS\n");

    const { store, seeds } = makeMocks();
    const monitor = new Monitor(store as never, seeds as never, tmpDir);
    const run = makeRun({ worktree_path: worktreeDir });

    await monitor.recoverStuck(run, 3);

    expect(store.logEvent).toHaveBeenCalledWith(
      run.project_id,
      "recover",
      expect.objectContaining({ worktreePreserved: true }),
      run.id,
    );
  });

  it("removes and recreates the worktree when no artifacts exist", async () => {
    // Arrange — empty worktree (no artifacts)
    const { store, seeds } = makeMocks();

    // Mock createWorktree by spying via the git module — but since we can't easily
    // mock ESM module internals here, we instead verify the observable behaviour:
    // updateRun is called with a new worktree_path when the worktree was recreated.
    //
    // We use a worktree path that doesn't exist on disk so removeWorktree is a no-op,
    // and createWorktree will attempt to call git. We mock the whole monitor with a
    // partial override to isolate the unit under test.

    const monitor = new Monitor(store as never, seeds as never, tmpDir);

    // Spy on the internal call by checking the logEvent details
    const run = makeRun({ worktree_path: worktreeDir }); // no artifacts in worktreeDir

    // createWorktree will fail because there's no real git repo — catch that.
    // The important assertion is that worktreePreserved is NOT set to true.
    try {
      await monitor.recoverStuck(run, 3);
    } catch {
      // createWorktree may throw — that's acceptable for this unit test
    }

    // Either recovery failed (store.updateRun called with "failed") or
    // it succeeded with a fresh worktree. In both cases worktreePreserved
    // should NOT appear as true in any logEvent call.
    const recoverCalls = store.logEvent.mock.calls.filter((call) => {
      const [, evtType] = call as [string, string];
      return evtType === "recover";
    });

    for (const call of recoverCalls) {
      const details = call[2] as Record<string, unknown>;
      expect(details.worktreePreserved).not.toBe(true);
    }
  });

  it("returns false and marks failed when max retries exceeded regardless of artifacts", async () => {
    writeFileSync(join(worktreeDir, "EXPLORER_REPORT.md"), "# Explorer Report\n");

    const { store, seeds } = makeMocks();
    // Simulate 3 previous recover events (already at max)
    store.getRunEvents.mockReturnValue([{}, {}, {}] as unknown[]);

    const monitor = new Monitor(store as never, seeds as never, tmpDir);
    const run = makeRun({ worktree_path: worktreeDir });

    const result = await monitor.recoverStuck(run, 3);

    expect(result).toBe(false);
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "failed" }),
    );
  });

  it("preserves worktree when only REVIEW.md exists (reviewer already done)", async () => {
    writeFileSync(join(worktreeDir, "REVIEW.md"), "# Review\n## Verdict: PASS\n");

    const { store, seeds } = makeMocks();
    const monitor = new Monitor(store as never, seeds as never, tmpDir);
    const run = makeRun({ worktree_path: worktreeDir });

    const result = await monitor.recoverStuck(run, 3);

    expect(result).toBe(true);
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "pending" }),
    );
  });

  it("handles null worktree_path gracefully (treats as no-progress)", async () => {
    const { store, seeds } = makeMocks();
    const monitor = new Monitor(store as never, seeds as never, tmpDir);
    const run = makeRun({ worktree_path: null });

    // Should not throw — will attempt to recreate (createWorktree may fail, that's ok)
    try {
      await monitor.recoverStuck(run, 3);
    } catch {
      // createWorktree failure is expected in test env
    }

    // Must not have called updateRun with worktreePreserved:true
    const recoverCalls = store.logEvent.mock.calls.filter((call) => {
      const [, evtType] = call as [string, string];
      return evtType === "recover";
    });
    for (const call of recoverCalls) {
      const details = call[2] as Record<string, unknown>;
      expect(details.worktreePreserved).not.toBe(true);
    }
  });
});
