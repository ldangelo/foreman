/**
 * merge-polling.test.ts
 *
 * Behavioral tests for the merge polling module.
 * All tests use vi.useFakeTimers + injectable execFile so they run fast
 * and deterministically without spawning real processes.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

vi.mock("node:child_process", () => ({
  execFile: vi.fn(),
}));

// Must import after vi.mock
import { execFile } from "node:child_process";
import { pollForMerge, adminMergeResolver, _resetSleepDurations, _getSleepDurations, type MergePollOptions } from "../merge-polling.js";

const execFileMock = vi.mocked(execFile);

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Builds a minimal MergePollOptions object with safe defaults. */
function baseOpts(overrides: Partial<MergePollOptions> = {}): MergePollOptions {
  return {
    runId: "run-1",
    taskId: "task-1",
    projectId: "proj-1",
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    execFile: execFile as any,
    cwd: "/tmp/test-repo",
    prNumber: 42,
    pollIntervalMs: 30_000,
    pollTimeoutMs: 300_000, // 5 min — tests advance fake clock explicitly
    maxIntervalMs: 120_000,
    jitter: 0,
    signal: undefined,
    onEvent: vi.fn(),
    ...overrides,
  };
}

/**
 * A timeline entry describes what `gh pr view` should return at a given
 * "tick" (poll cycle). Tick 1 is the first check after the initial sleep.
 */
type TimelineEntry =
  | { kind: "open" }
  | { kind: "merged"; mergedAt?: string }
  | { kind: "closed" }
  | { kind: "error"; message: string };

/**
 * Build a mock execFile implementation that follows a gh-pr-view timeline.
 * Callback-based so it works with promisify(execFile).
 * Non-gh-view calls succeed silently.
 */
function ghViewTimeline(entries: TimelineEntry[]) {
  let index = 0;
  return (
    cmd: string,
    args: readonly string[] | null | undefined,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    _opts: any,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    cb: (err: any, stdout: any, stderr: any) => void,
  ): void => {
    if (cmd === "gh" && args?.[0] === "pr" && args?.[1] === "view") {
      if (index >= entries.length) {
        cb(null, { stdout: JSON.stringify({ state: "OPEN" }), stderr: "" }, null);
        return;
      }
      const entry = entries[index++];
      if (entry.kind === "open") { cb(null, JSON.stringify({ state: "OPEN" }), ""); return; }
      if (entry.kind === "merged") { cb(null, JSON.stringify({ state: "MERGED", mergedAt: entry.mergedAt ?? null }), ""); return; }
      if (entry.kind === "closed") { cb(null, JSON.stringify({ state: "CLOSED" }), ""); return; }
      if (entry.kind === "error") { cb(new Error(entry.message), null, ""); return; }
    }
    // Non-gh calls: succeed silently
    cb(null, "", "");
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("pollForMerge", () => {
  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    _resetSleepDurations();
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  // ── PollReturnsMergedWhenGhReportsMerged ──────────────────────────────

  it("PollReturnsMergedWhenGhReportsMerged", async () => {
    // Tick 1: OPEN (immediate, no sleep), tick 2: MERGED (after 1 sleep)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    execFileMock.mockImplementation(ghViewTimeline([
      { kind: "open" },
      { kind: "merged", mergedAt: "2024-01-01T00:00:00Z" },
    ]) as any);

    const onEvent = vi.fn();
    const pollPromise = pollForMerge({ ...baseOpts(), onEvent });

    // Advance past 1 sleep (30s) so tick 2 fires and returns MERGED
    await vi.advanceTimersByTimeAsync(30_000);

    const result = await pollPromise;

    expect(result.outcome).toBe("merged");
    expect(result.mergedAt).toBe("2024-01-01T00:00:00Z");
    expect(result.attempts).toBe(2);
    expect(result.pollHistory).toHaveLength(2);
    expect(result.pollHistory[0].state).toBe("OPEN");
    expect(result.pollHistory[1].state).toBe("MERGED");

    expect(onEvent).toHaveBeenCalledWith(
      expect.objectContaining({ type: "started", prNumber: 42 }),
    );
    expect(onEvent).toHaveBeenCalledWith(
      expect.objectContaining({ type: "tick", prNumber: 42, attempt: 1, state: "OPEN" }),
    );
    expect(onEvent).toHaveBeenCalledWith(
      expect.objectContaining({ type: "tick", prNumber: 42, attempt: 2, state: "MERGED" }),
    );
    expect(onEvent).toHaveBeenCalledWith(
      expect.objectContaining({ type: "merged", prNumber: 42 }),
    );
  });

  // ── PollReturnsClosedWhenGhReportsClosed ───────────────────────────────

  it("PollReturnsClosedWhenGhReportsClosed", async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    execFileMock.mockImplementation(ghViewTimeline([{ kind: "closed" }]) as any);

    const resolver = vi.fn();
    const result = await pollForMerge({ ...baseOpts(), resolver });

    expect(result.outcome).toBe("closed");
    expect(result.attempts).toBe(1);
    expect(resolver).not.toHaveBeenCalled();
    expect(result.pollHistory[0].state).toBe("CLOSED");
  });

  // ── PollFiresResolverOnTimeout ─────────────────────────────────────────

  it("PollFiresResolverOnTimeout", async () => {
    // All ticks return OPEN so we hit the timeout path.
    // Use a short timeout (2 intervals) to keep test fast.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    execFileMock.mockImplementation(ghViewTimeline([
      { kind: "open" },
      { kind: "open" },
      { kind: "open" },
    ]) as any);

    const resolver = vi.fn();
    // Advance past 3 sleeps (30s + 45s + 67.5s = 142.5s) so timeout fires at 90s
    await vi.advanceTimersByTimeAsync(135_000);

    const result = await pollForMerge({
      ...baseOpts({
        pollTimeoutMs: 90_000,
        pollIntervalMs: 30_000,
        resolver,
      }),
    });

    expect(result.outcome).toBe("resolved");
    expect(result.resolverFired).toBe(true);
    expect(resolver).toHaveBeenCalledTimes(1);
    expect(resolver).toHaveBeenCalledWith({
      prNumber: 42,
      cwd: "/tmp/test-repo",
      execFile: expect.any(Function),
    });
  });

  // ── PollMarksResolvedWhenResolverMergesAnyway ──────────────────────────

  it("PollMarksResolvedWhenResolverMergesAnyway", async () => {
    // All 4 gh view calls (3 polls + final) return OPEN → resolved.
    // Resolver is called and its merge call succeeds silently.
    let ghViewCount = 0;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    execFileMock.mockImplementation(((cmd: string, args: any, _opts: any, cb: any) => {
      if (cmd === "gh" && args?.[0] === "pr" && args?.[1] === "view") {
        ghViewCount++;
        cb(null, JSON.stringify({ state: "OPEN" }), "");
        return;
      }
      cb(null, "Merge successful.", "");
    }) as any);

    const resolver = vi.fn(async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      await (execFile as any)("gh", ["pr", "merge", "42", "--admin", "--squash"], { cwd: "/tmp/test-repo", timeout: 60_000 });
    });

    const pollPromise = pollForMerge({
      ...baseOpts({ pollTimeoutMs: 90_000, pollIntervalMs: 30_000, resolver }),
    });

    // Advance past 3 sleeps (30s + 45s + 67.5s = 142.5s) so timeout fires at 90s
    await vi.advanceTimersByTimeAsync(135_000);

    const result = await pollPromise;

    expect(result.outcome).toBe("resolved");
    expect(result.resolverFired).toBe(true);
    expect(resolver).toHaveBeenCalledTimes(1);
    expect(ghViewCount).toBe(4); // 3 polls + 1 final
  });

  // ── PollAbortsViaSignal ────────────────────────────────────────────────

  it("PollAbortsViaSignal", async () => {
    // gh returns OPEN; we abort mid-sleep
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    execFileMock.mockImplementation(ghViewTimeline([{ kind: "open" }, { kind: "merged" }]) as any);

    const resolver = vi.fn();
    const abortController = new AbortController();

    const pollPromise = pollForMerge({
      ...baseOpts({ resolver, signal: abortController.signal }),
    });

    // Abort after 10ms (before the first 30s sleep completes)
    setTimeout(() => abortController.abort(), 10);
    await vi.advanceTimersByTimeAsync(10); // trigger the abort

    const result = await pollPromise;

    expect(result.outcome).toBe("aborted");
    expect(resolver).not.toHaveBeenCalled();
  });

  // ── PollBacksOffWithJitter ─────────────────────────────────────────────

  it("PollBacksOffWithJitter", async () => {
    // gh always returns OPEN → polling continues indefinitely
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    execFileMock.mockImplementation(ghViewTimeline([
      { kind: "open" },
      { kind: "open" },
      { kind: "open" },
    ]) as any);

    const abortController = new AbortController();

    const pollPromise = pollForMerge({
      ...baseOpts({
        pollIntervalMs: 30_000,
        jitter: 0.5, // ±50%
        pollTimeoutMs: 300_000,
        maxIntervalMs: 120_000,
        signal: abortController.signal,
      }),
    });

    // Advance past 3 sleeps (30s + 45s + 67.5s = 142.5s) so tick 4 fires, then abort
    await vi.advanceTimersByTimeAsync(145_000);
    setTimeout(() => abortController.abort(), 0);
    await vi.advanceTimersByTimeAsync(0);
    await pollPromise.catch(() => {/* aborted */});

    // 3 sleeps should have been scheduled (tracked by _sleepDurations in production code).
    const sleepDurations = _getSleepDurations();
    expect(sleepDurations.length).toBeGreaterThanOrEqual(3);

    // Each interval is capped at maxIntervalMs (120 000)
    for (const ms of sleepDurations.slice(0, 3)) {
      expect(ms).toBeLessThanOrEqual(120_000);
    }
  });

  // ── PollSurfacesGhErrorsAsErrorEvents ─────────────────────────────────

  it("PollSurfacesGhErrorsAsErrorEvents", async () => {
    let tick = 0;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    execFileMock.mockImplementation(((cmd: string, args: any, _opts: any, cb: any) => {
      if (cmd === "gh" && args?.[0] === "pr" && args?.[1] === "view") {
        tick++;
        if (tick <= 2) { cb(new Error(`gh error ${tick}`), null, ""); return; }
        cb(null, JSON.stringify({ state: "MERGED", mergedAt: "2024-01-01T00:00:00Z" }), "");
        return;
      }
      cb(null, "", "");
    }) as any);

    const onEvent = vi.fn();

    const pollPromise = pollForMerge({ ...baseOpts({ onEvent }) });

    // Advance past 3 sleeps (30s + 45s + 67.5s = 142.5s with jitter=0, capped at maxIntervalMs=120_000)
    // First sleep = 30_000ms, second = 45_000ms, third = 67_500ms. Total = 75 000ms. Advance 80 000ms.
    // Timeout at 90s fires after tick 3 → gh returns MERGED → loop exits.
    await vi.advanceTimersByTimeAsync(80_000);

    const result = await pollPromise;

    expect(result.outcome).toBe("merged");
    expect(result.attempts).toBe(3);

    const errorEvents = onEvent.mock.calls.filter(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (call: unknown[]) => (call[0] as { type: string }).type === "error",
    );
    expect(errorEvents).toHaveLength(2);
    expect((errorEvents[0][0] as { error: string }).error).toBe("gh error 1");
    expect((errorEvents[1][0] as { error: string }).error).toBe("gh error 2");
  });

  // ── PollFinalCheckRecoversFromLateMerge ────────────────────────────────

  it("PollFinalCheckRecoversFromLateMerge", async () => {
    // All poll checks return OPEN; timeout fires, resolver throws, final check returns MERGED.
    let ghViewCount = 0;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    execFileMock.mockImplementation(((cmd: string, args: any, _opts: any, cb: any) => {
      if (cmd === "gh" && args?.[0] === "pr" && args?.[1] === "view") {
        ghViewCount++;
        // Final check (after resolver) is the 4th view call
        if (ghViewCount > 3) {
          cb(null, JSON.stringify({ state: "MERGED", mergedAt: "2024-01-01T00:00:00Z" }), "");
          return;
        }
        cb(null, JSON.stringify({ state: "OPEN" }), "");
        return;
      }
      cb(null, "", "");
    }) as any);

    const resolver = vi.fn(async () => {
      throw new Error("resolver failed");
    });

    const pollPromise = pollForMerge({
      ...baseOpts({ pollTimeoutMs: 90_000, pollIntervalMs: 30_000, resolver }),
    });

    // Advance past 3 sleeps (30s + 45s + 67.5s = 142.5s) so timeout fires at 90s
    await vi.advanceTimersByTimeAsync(135_000);

    const result = await pollPromise;

    // Final check returned MERGED → "merged" even though resolver threw
    expect(result.outcome).toBe("merged");
    expect(result.resolverFired).toBe(true);
  });

  // ── AdminMergeResolverCallsGhPrMergeWithAdminSquash ────────────────────

  it("AdminMergeResolverCallsGhPrMergeWithAdminSquash", async () => {
    // Callback-style mock so promisify(execFile) works correctly.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    execFileMock.mockImplementation(((_cmd: any, _args: any, _opts: any, cb: any) => {
      cb(null, "Merge successful.", "");
    }) as any);

    await adminMergeResolver({
      prNumber: 42,
      cwd: "/tmp/test-repo",
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      execFile: execFile as any,
    });

    expect(execFile).toHaveBeenCalledTimes(1);
    expect(execFile).toHaveBeenCalledWith(
      "gh",
      ["pr", "merge", "42", "--admin", "--squash"],
      expect.objectContaining({ cwd: "/tmp/test-repo", timeout: 60_000 }),
    );
  });
});
