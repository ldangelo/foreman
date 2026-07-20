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
 * Returns a Promise for all calls (mimics the promisified execFile used by
 * the polling code). Non-gh-view calls succeed silently.
 */
function ghViewTimeline(entries: TimelineEntry[]) {
  let index = 0;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return async (cmd: string, args?: any, _opts?: any): Promise<{ stdout: string; stderr: string }> => {
    if (cmd === "gh" && args?.[0] === "pr" && args?.[1] === "view") {
      if (index >= entries.length) {
        return { stdout: JSON.stringify({ state: "OPEN" }), stderr: "" };
      }
      const entry = entries[index++];
      if (entry.kind === "open") return { stdout: JSON.stringify({ state: "OPEN" }), stderr: "" };
      if (entry.kind === "merged") return { stdout: JSON.stringify({ state: "MERGED", mergedAt: entry.mergedAt ?? null }), stderr: "" };
      if (entry.kind === "closed") return { stdout: JSON.stringify({ state: "CLOSED" }), stderr: "" };
      if (entry.kind === "error") throw new Error(entry.message);
    }
    return { stdout: "", stderr: "" };
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("pollForMerge", () => {
  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: false });
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

    // Only 1 sleep needed: tick 1 is immediate, tick 2 is after sleep
    await vi.advanceTimersByTimeAsync(30_000); // sleep between tick 1 and tick 2

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
    execFileMock.mockImplementation((async (cmd: string, args?: any, _opts?: any) => {
      if (cmd === "gh" && args?.[0] === "pr" && args?.[1] === "view") {
        ghViewCount++;
        return { stdout: JSON.stringify({ state: "OPEN" }), stderr: "" };
      }
      return { stdout: "Merge successful.", stderr: "" };
    }) as any);

    const resolver = vi.fn(async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      await execFile("gh", ["pr", "merge", "42", "--admin", "--squash"], { cwd: "/tmp/test-repo", timeout: 60_000 } as any);
    });

    const result = await pollForMerge({
      ...baseOpts({ pollTimeoutMs: 90_000, pollIntervalMs: 30_000, resolver }),
    });

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

    // Advance past 3 sleeps, then abort to terminate the poll
    await vi.advanceTimersByTimeAsync(30_000);
    await vi.advanceTimersByTimeAsync(30_000);
    await vi.advanceTimersByTimeAsync(30_000);
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
    execFileMock.mockImplementation((async (cmd: string, args?: any, _opts?: any) => {
      if (cmd === "gh" && args?.[0] === "pr" && args?.[1] === "view") {
        tick++;
        if (tick <= 2) throw new Error(`gh error ${tick}`);
        return { stdout: JSON.stringify({ state: "MERGED", mergedAt: "2024-01-01T00:00:00Z" }), stderr: "" };
      }
      return { stdout: "", stderr: "" };
    }) as any);

    const onEvent = vi.fn();

    const pollPromise = pollForMerge({ ...baseOpts({ onEvent }) });

    // Advance past 3 sleeps to get 3 ticks
    await vi.advanceTimersByTimeAsync(30_000);
    await vi.advanceTimersByTimeAsync(30_000);
    await vi.advanceTimersByTimeAsync(30_000);

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

    await pollPromise; // already resolved, but safe to await again
  });

  // ── PollFinalCheckRecoversFromLateMerge ────────────────────────────────

  it("PollFinalCheckRecoversFromLateMerge", async () => {
    // All poll checks return OPEN; timeout fires, resolver throws, final check returns MERGED.
    let ghViewCount = 0;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    execFileMock.mockImplementation((async (cmd: string, args?: any, _opts?: any) => {
      if (cmd === "gh" && args?.[0] === "pr" && args?.[1] === "view") {
        ghViewCount++;
        // Final check (after resolver) is the 4th view call
        if (ghViewCount > 3) {
          return { stdout: JSON.stringify({ state: "MERGED", mergedAt: "2024-01-01T00:00:00Z" }), stderr: "" };
        }
        return { stdout: JSON.stringify({ state: "OPEN" }), stderr: "" };
      }
      return { stdout: "", stderr: "" };
    }) as any);

    const resolver = vi.fn(async () => {
      throw new Error("resolver failed");
    });

    const pollPromise = pollForMerge({
      ...baseOpts({ pollTimeoutMs: 90_000, pollIntervalMs: 30_000, resolver }),
    });

    // Advance past 3 sleeps so timeout fires (90s elapsed) → final check returns MERGED
    await vi.advanceTimersByTimeAsync(30_000);
    await vi.advanceTimersByTimeAsync(30_000);
    await vi.advanceTimersByTimeAsync(30_000);

    const result = await pollPromise;

    // Final check returned MERGED → "merged" even though resolver threw
    expect(result.outcome).toBe("merged");
    expect(result.resolverFired).toBe(true);
  });

  // ── AdminMergeResolverCallsGhPrMergeWithAdminSquash ────────────────────

  it("AdminMergeResolverCallsGhPrMergeWithAdminSquash", async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    execFileMock.mockResolvedValue({
      stdout: "Merge successful.",
      stderr: "",
    } as any);

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
