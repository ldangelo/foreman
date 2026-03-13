import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore, type Run, type RunProgress } from "../../lib/store.js";

/**
 * AT-T040: Follow mode edge case tests
 *
 * Tests:
 * 1. Rapidly updating output (no duplicate lines)
 * 2. Session ends mid-poll (graceful exit)
 * 3. Multiple concurrent follow sessions (independent operation)
 * 4. Empty initial output (no crash)
 * 5. Follow interval respects FOREMAN_TMUX_FOLLOW_INTERVAL_MS env var
 */

// ── Mock child_process ────────────────────────────────────────────────

const mockSpawnSync = vi.fn();
const mockSpawn = vi.fn();

vi.mock("node:child_process", () => ({
  spawn: (...args: unknown[]) => mockSpawn(...args),
  spawnSync: (...args: unknown[]) => mockSpawnSync(...args),
}));

// ── Mock TmuxClient ──────────────────────────────────────────────────

const mockHasSession = vi.fn<(name: string) => Promise<boolean>>();
const mockCapturePaneOutput = vi.fn<(name: string) => Promise<string[]>>();
const mockKillSession = vi.fn<(name: string) => Promise<boolean>>();

vi.mock("../../lib/tmux.js", () => {
  class MockTmuxClient {
    hasSession = mockHasSession;
    capturePaneOutput = mockCapturePaneOutput;
    killSession = mockKillSession;
  }
  return {
    TmuxClient: MockTmuxClient,
    tmuxSessionName: (seedId: string) => `foreman-${seedId}`,
  };
});

// ── Helpers ──────────────────────────────────────────────────────────

function createTestRun(
  store: ForemanStore,
  projectId: string,
  overrides: Partial<{
    seedId: string;
    status: Run["status"];
    sessionKey: string | null;
    tmuxSession: string | null;
    worktreePath: string | null;
    progress: RunProgress | null;
  }> = {},
): Run {
  const seedId = overrides.seedId ?? "test-seed";
  const run = store.createRun(projectId, seedId, "claude-sonnet-4-6", overrides.worktreePath ?? "/tmp/wt");
  const updates: Record<string, unknown> = {};
  if (overrides.status) updates.status = overrides.status;
  if (overrides.sessionKey !== undefined) updates.session_key = overrides.sessionKey;
  if (overrides.tmuxSession !== undefined) updates.tmux_session = overrides.tmuxSession;
  if (Object.keys(updates).length > 0) store.updateRun(run.id, updates);
  if (overrides.progress) store.updateRunProgress(run.id, overrides.progress);
  return store.getRun(run.id)!;
}

// ── Test suite ──────────────────────────────────────────────────────

describe("AT-T040: follow mode edge cases", () => {
  let tmpDir: string;
  let store: ForemanStore;
  let projectId: string;
  const originalEnv = { ...process.env };

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-follow-edge-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
    const project = store.registerProject("test-project", tmpDir);
    projectId = project.id;

    mockSpawn.mockReset();
    mockSpawnSync.mockReset();
    mockHasSession.mockReset();
    mockCapturePaneOutput.mockReset();
    mockKillSession.mockReset();

    process.env.FOREMAN_TMUX_FOLLOW_INTERVAL_MS = "20";
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
    process.env = { ...originalEnv };
  });

  it("rapidly updating output produces no duplicate lines", async () => {
    const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

    createTestRun(store, projectId, {
      seedId: "rapid-output",
      status: "running",
      tmuxSession: "foreman-rapid-output",
    });

    // Simulate rapidly growing output: each poll adds more lines
    let pollCount = 0;
    mockHasSession.mockImplementation(async () => {
      pollCount++;
      return pollCount <= 5; // Session alive for 5 polls, then dies
    });

    mockCapturePaneOutput.mockImplementation(async () => {
      // Each call returns increasingly more lines
      const totalLines = Math.min(pollCount * 3, 15);
      return Array.from({ length: totalLines }, (_, i) => `output-line-${i + 1}`);
    });

    const { attachAction } = await import("../commands/attach.js");
    const exitCode = await attachAction("rapid-output", { follow: true }, store, tmpDir);

    // Collect all output lines (excluding header and "Session ended" messages)
    const logCalls = consoleSpy.mock.calls.map((c) => String(c[0]));
    const outputLines = logCalls.filter((l) => l.startsWith("output-line-"));

    // Verify no duplicates
    const seen = new Set<string>();
    for (const line of outputLines) {
      expect(seen.has(line)).toBe(false);
      seen.add(line);
    }

    // Verify we got some output
    expect(outputLines.length).toBeGreaterThan(0);
    expect(exitCode).toBe(0);

    consoleSpy.mockRestore();
  });

  it("session ends mid-poll with graceful exit", async () => {
    const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

    createTestRun(store, projectId, {
      seedId: "mid-poll-end",
      status: "running",
      tmuxSession: "foreman-mid-poll-end",
    });

    // Session alive for first poll, gone on second
    mockHasSession
      .mockResolvedValueOnce(true)  // initial hasSession check in handleFollow
      .mockResolvedValueOnce(true)  // poll 1
      .mockResolvedValueOnce(false); // poll 2 -> session ended

    mockCapturePaneOutput
      .mockResolvedValueOnce(["working..."])
      .mockResolvedValueOnce(["working...", "done!"]);

    const { attachAction } = await import("../commands/attach.js");
    const exitCode = await attachAction("mid-poll-end", { follow: true }, store, tmpDir);

    expect(exitCode).toBe(0);

    const logCalls = consoleSpy.mock.calls.map((c) => String(c[0]));
    expect(logCalls).toContain("Session ended.");

    consoleSpy.mockRestore();
  });

  it("multiple concurrent follow sessions operate independently", async () => {
    const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

    createTestRun(store, projectId, {
      seedId: "concurrent-1",
      status: "running",
      tmuxSession: "foreman-concurrent-1",
    });

    createTestRun(store, projectId, {
      seedId: "concurrent-2",
      status: "running",
      tmuxSession: "foreman-concurrent-2",
    });

    // Session 1: alive for 2 polls, then dies
    // Session 2: alive for 3 polls, then dies
    // Track which session is being checked
    const session1Polls = { has: 0, capture: 0 };
    const session2Polls = { has: 0, capture: 0 };

    mockHasSession.mockImplementation(async (name: string) => {
      if (name === "foreman-concurrent-1") {
        session1Polls.has++;
        return session1Polls.has <= 3; // first call + 2 polls
      }
      if (name === "foreman-concurrent-2") {
        session2Polls.has++;
        return session2Polls.has <= 4; // first call + 3 polls
      }
      return false;
    });

    mockCapturePaneOutput.mockImplementation(async (name: string) => {
      if (name === "foreman-concurrent-1") {
        session1Polls.capture++;
        return [`session1-line-${session1Polls.capture}`];
      }
      if (name === "foreman-concurrent-2") {
        session2Polls.capture++;
        return [`session2-line-${session2Polls.capture}`];
      }
      return [];
    });

    const { attachAction } = await import("../commands/attach.js");

    // Run both follow sessions concurrently
    const [exit1, exit2] = await Promise.all([
      attachAction("concurrent-1", { follow: true }, store, tmpDir),
      attachAction("concurrent-2", { follow: true }, store, tmpDir),
    ]);

    expect(exit1).toBe(0);
    expect(exit2).toBe(0);

    // Both sessions should have produced output
    const logCalls = consoleSpy.mock.calls.map((c) => String(c[0]));
    const s1Lines = logCalls.filter((l) => l.startsWith("session1-"));
    const s2Lines = logCalls.filter((l) => l.startsWith("session2-"));

    expect(s1Lines.length).toBeGreaterThan(0);
    expect(s2Lines.length).toBeGreaterThan(0);

    consoleSpy.mockRestore();
  });

  it("empty initial output does not crash", async () => {
    const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

    createTestRun(store, projectId, {
      seedId: "empty-output",
      status: "running",
      tmuxSession: "foreman-empty-output",
    });

    // Session alive for 2 polls, empty output initially
    mockHasSession
      .mockResolvedValueOnce(true) // initial check
      .mockResolvedValueOnce(true) // poll 1 (empty)
      .mockResolvedValueOnce(true) // poll 2 (has content)
      .mockResolvedValueOnce(false); // poll 3 -> session ended

    mockCapturePaneOutput
      .mockResolvedValueOnce([]) // empty initial output
      .mockResolvedValueOnce(["finally some output"]);

    const { attachAction } = await import("../commands/attach.js");
    const exitCode = await attachAction("empty-output", { follow: true }, store, tmpDir);

    expect(exitCode).toBe(0);

    const logCalls = consoleSpy.mock.calls.map((c) => String(c[0]));
    expect(logCalls).toContain("finally some output");
    expect(logCalls).toContain("Session ended.");

    consoleSpy.mockRestore();
  });

  it("follow interval respects FOREMAN_TMUX_FOLLOW_INTERVAL_MS env var", async () => {
    const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

    createTestRun(store, projectId, {
      seedId: "interval-test",
      status: "running",
      tmuxSession: "foreman-interval-test",
    });

    // Use a custom interval via env var
    process.env.FOREMAN_TMUX_FOLLOW_INTERVAL_MS = "100";

    const pollTimestamps: number[] = [];

    mockHasSession.mockImplementation(async () => {
      pollTimestamps.push(Date.now());
      return pollTimestamps.length <= 3; // 3 polls then die
    });

    mockCapturePaneOutput.mockResolvedValue(["output"]);

    const { attachAction } = await import("../commands/attach.js");

    const start = Date.now();
    await attachAction("interval-test", { follow: true }, store, tmpDir);
    const elapsed = Date.now() - start;

    // With 100ms interval and ~3 poll cycles, total should be >= 200ms
    // (first poll is immediate, then 2 waits of 100ms)
    // Be generous with timing tolerance for CI
    expect(elapsed).toBeGreaterThanOrEqual(150);

    consoleSpy.mockRestore();
  });

  it("follow with AbortSignal exits cleanly between polls", async () => {
    const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

    createTestRun(store, projectId, {
      seedId: "abort-between",
      status: "running",
      tmuxSession: "foreman-abort-between",
    });

    mockHasSession.mockResolvedValue(true);
    mockCapturePaneOutput.mockResolvedValue(["running..."]);

    const { attachAction } = await import("../commands/attach.js");

    const controller = new AbortController();

    // Start follow then abort after some polls
    const resultPromise = attachAction(
      "abort-between",
      { follow: true, _signal: controller.signal },
      store,
      tmpDir,
    );

    // Wait for at least one poll
    await new Promise((r) => setTimeout(r, 80));
    controller.abort();

    const exitCode = await resultPromise;
    expect(exitCode).toBe(0);

    const logCalls = consoleSpy.mock.calls.map((c) => String(c[0]));
    expect(logCalls.some((l) => l.includes("Stopped following"))).toBe(true);
    expect(logCalls.some((l) => l.includes("Agent continues running"))).toBe(true);

    consoleSpy.mockRestore();
  });
});
