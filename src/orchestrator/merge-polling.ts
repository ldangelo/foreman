/**
 * merge-polling.ts
 *
 * Composable polling interface for GitHub PR merge detection.
 * Replaces the inline while-loop in runMergeBuiltinPhase so projects can
 * tune timeout / interval / backoff without forking the agent.
 */

/**
 * Matches the callback-style signature of node:child_process.execFile.
 * This is the shape that `promisify()` wraps into the Promise-based form.
 */
export type ExecFileFn = (
  command: string,
  args?: readonly string[] | null,
  options?: object,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  callback?: (error: any, stdout: any, stderr: any) => void,
) => unknown;

/** Promisified execFile: passes callback as 4th arg (matching real execFile API). */
type ExecFileAsync = (
  command: string,
  args?: readonly string[] | null,
  options?: object,
) => Promise<{ stdout: string; stderr: string }>;

/**
 * Wrap a callback-style execFile in a Promise, always passing the callback
 * as the 4th argument (the real node:child_process.execFile convention).
 *
 * NOTE: vi.fn() has length=0, so util.promisify misroutes a 3-arg call
 * by treating the 3rd arg as the callback. This explicit wrapper always
 * uses the 4th-slot convention regardless of the underlying fn.length.
 */
function makeExecAsync(execFile: ExecFileFn): ExecFileAsync {
  return (command, args, options) =>
    new Promise((resolve, reject) => {
      execFile(command, args ?? undefined, options as object, (err, stdout, stderr) =>
        err ? reject(err) : resolve({ stdout: stdout ?? "", stderr: stderr ?? "" }),
      );
    });
}

/** Callback invoked once per polling tick with the current PR state. */
export type MergeResolver = (ctx: {
  prNumber: number;
  cwd: string;
  execFile: ExecFileFn;
}) => Promise<void>;

// ── Options ──────────────────────────────────────────────────────────────────

export interface MergePollOptions {
  runId: string;
  taskId: string;
  projectId?: string;
  /** Injected execFile so tests can mock without touching node:child_process. */
  execFile: ExecFileFn;
  /**
   * Optional pre-promisified execFile for tests.
   * When provided, this is used directly instead of calling promisify(execFile).
   * This avoids the promisify+vi.fn() incompatibility in test environments.
   */
  execAsync?: ExecFileAsync;
  /** Working directory for gh commands. */
  cwd: string;
  /** PR number to poll. */
  prNumber: number;
  /** Base polling interval in ms. */
  pollIntervalMs: number;
  /** Hard timeout for the entire polling loop in ms. */
  pollTimeoutMs: number;
  /** Cap for exponential backoff (default: pollIntervalMs * 4). */
  maxIntervalMs?: number;
  /** Fractional jitter applied to each interval (default: 0 = disabled). */
  jitter?: number;
  /** Fallback resolver called on timeout before giving up. */
  resolver?: MergeResolver;
  /** AbortSignal to cancel polling early. */
  signal?: AbortSignal;
  /** Hook for observability — every state transition emits an event. */
  onEvent?: (e: MergePollEvent) => void;
}

// ── Event types ───────────────────────────────────────────────────────────────

export type MergePollEvent =
  | { type: "started"; prNumber: number; at: string }
  | { type: "tick"; prNumber: number; attempt: number; state: string; at: string }
  | { type: "merged"; prNumber: number; mergedAt: string }
  | { type: "closed"; prNumber: number; at: string }
  | { type: "timeout"; prNumber: number; attempts: number; at: string }
  | { type: "resolver-done"; prNumber: number; at: string }
  | { type: "error"; prNumber: number; attempt: number; error: string; at: string }
  | { type: "aborted"; prNumber: number; at: string };

// ── Result ────────────────────────────────────────────────────────────────────

export interface MergePollResult {
  /** What ended the poll. */
  outcome: "merged" | "closed" | "resolved" | "aborted";
  /** ISO timestamp of the merge, if outcome is "merged". */
  mergedAt?: string;
  /** Whether the timeout resolver fired. */
  resolverFired?: boolean;
  /** Number of gh pr view calls made. */
  attempts: number;
  /** Wall-clock elapsed time in ms. */
  elapsedMs: number;
  /** Full tick history for observability. */
  pollHistory: Array<{ attempt: number; state: string; errored: boolean }>;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function isoNow(): string {
  return new Date().toISOString();
}

/** Returns a jittered interval in ms. factor is multiplied by (1 ± jitter). */
function jitteredInterval(factor: number, jitter: number): number {
  if (jitter <= 0) return factor;
  const delta = factor * jitter;
  return factor + (Math.random() * 2 - 1) * delta;
}

/** Parse gh pr view JSON output, tolerating unexpected shapes. */
interface GhPrView {
  state?: string;
  mergedAt?: string | null;
}

function parseGhPrView(stdout: string): GhPrView {
  try {
    return JSON.parse(stdout) as GhPrView;
  } catch {
    return {};
  }
}

// ── Public API ─────────────────────────────────────────────────────────────────

/**
 * Poll `gh pr view <prNumber> --json state,mergedAt` with exponential backoff
 * + jitter until the PR is MERGED, CLOSED, times out, or the signal fires.
 *
 * Respects AbortSignal on every sleep and every gh invocation.
 */
export async function pollForMerge(opts: MergePollOptions): Promise<MergePollResult> {
  const {
    execFile,
    cwd,
    prNumber,
    pollIntervalMs,
    pollTimeoutMs,
    maxIntervalMs = pollIntervalMs * 4,
    jitter = 0,
    resolver,
    signal,
    onEvent,
  } = opts;

  const execAsync: ExecFileAsync = opts.execAsync ?? makeExecAsync(execFile);

  onEvent?.({ type: "started", prNumber, at: isoNow() });

  const start = Date.now();
  let currentInterval = pollIntervalMs;
  let attempts = 0;
  let resolverFired = false;

  const pollHistory: Array<{ attempt: number; state: string; errored: boolean }> = [];

  // ── Bounded polling loop ──────────────────────────────────────────────────
  while (true) {
    // ── Abort check ────────────────────────────────────────────────────────
    if (signal?.aborted) {
      onEvent?.({ type: "aborted", prNumber, at: isoNow() });
      return {
        outcome: "aborted",
        attempts,
        elapsedMs: Date.now() - start,
        pollHistory,
      };
    }

    // ── Timeout check ──────────────────────────────────────────────────────
    const elapsed = Date.now() - start;
    if (elapsed >= pollTimeoutMs) {
      onEvent?.({ type: "timeout", prNumber, attempts, at: isoNow() });

      // ── Call resolver as last resort ────────────────────────────────────
      if (resolver) {
        try {
          await resolver({ prNumber, cwd, execFile });
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          onEvent?.({
            type: "error",
            prNumber,
            attempt: attempts,
            error: `resolver threw: ${msg}`,
            at: isoNow(),
          });
        }
        resolverFired = true;
        onEvent?.({ type: "resolver-done", prNumber, at: isoNow() });
      }

      // ── Final state check: did the resolver succeed? ─────────────────────
      // This recovers the "just-after-timeout" race from PR #364.
      const finalCheck = await checkPrState(execAsync, signal, cwd, prNumber, attempts, onEvent);
      attempts++;
      pollHistory.push({ attempt: attempts, state: finalCheck.state ?? "unknown", errored: finalCheck.errored });

      if (finalCheck.state === "MERGED") {
        onEvent?.({ type: "merged", prNumber, mergedAt: finalCheck.mergedAt ?? isoNow() });
        return {
          outcome: "merged",
          mergedAt: finalCheck.mergedAt,
          resolverFired,
          attempts,
          elapsedMs: Date.now() - start,
          pollHistory,
        };
      }

      // Timeout and PR is still not merged → give up.
      return {
        outcome: "resolved",
        resolverFired,
        attempts,
        elapsedMs: Date.now() - start,
        pollHistory,
      };
    }

    // ── Check PR state (immediate on first tick, after sleep thereafter) ─────
    if (attempts > 0) {
      // Sleep with exponential backoff + jitter before subsequent checks.
      const sleepMs = jitteredInterval(currentInterval, jitter);
      await sleep(sleepMs, signal);

      if (signal?.aborted) {
        onEvent?.({ type: "aborted", prNumber, at: isoNow() });
        return {
          outcome: "aborted",
          attempts,
          elapsedMs: Date.now() - start,
          pollHistory,
        };
      }
    }

    const result = await checkPrState(execAsync, signal, cwd, prNumber, attempts + 1, onEvent);
    attempts++;
    pollHistory.push({ attempt: attempts, state: result.state ?? "unknown", errored: result.errored });

    if (result.state === "MERGED") {
      onEvent?.({ type: "merged", prNumber, mergedAt: result.mergedAt ?? isoNow() });
      return {
        outcome: "merged",
        mergedAt: result.mergedAt,
        attempts,
        elapsedMs: Date.now() - start,
        pollHistory,
      };
    }

    if (result.state === "CLOSED") {
      onEvent?.({ type: "closed", prNumber, at: isoNow() });
      return {
        outcome: "closed",
        attempts,
        elapsedMs: Date.now() - start,
        pollHistory,
      };
    }

    // OPEN → advance backoff for next iteration.
    currentInterval = Math.min(currentInterval * 1.5, maxIntervalMs);
  }
}

// ── Internal helpers ───────────────────────────────────────────────────────────

interface PrStateResult {
  state?: string;
  mergedAt?: string;
  errored: boolean;
}

async function checkPrState(
  execAsync: ExecFileAsync,
  signal: AbortSignal | undefined,
  cwd: string,
  prNumber: number,
  attempt: number,
  onEvent: ((e: MergePollEvent) => void) | undefined,
): Promise<PrStateResult> {
  if (signal?.aborted) {
    return { errored: false };
  }
  try {
    const { stdout } = await execAsync(
      "gh",
      ["pr", "view", String(prNumber), "--json", "state,mergedAt"],
      { cwd, timeout: 30_000, signal },
    );
    const parsed = parseGhPrView(stdout);
    const state = parsed.state?.toUpperCase() ?? "UNKNOWN";
    onEvent?.({ type: "tick", prNumber, attempt, state, at: isoNow() });
    return { state, mergedAt: parsed.mergedAt ?? undefined, errored: false };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    onEvent?.({ type: "error", prNumber, attempt, error: msg, at: isoNow() });
    return { errored: true };
  }
}

// Tracks the duration of each sleep call — consumed by the PollBacksOffWithJitter test.
const _sleepDurations: number[] = [];
export function _resetSleepDurations(): void {
  _sleepDurations.length = 0;
}
export function _getSleepDurations(): readonly number[] {
  return _sleepDurations;
}

async function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) return;
  _sleepDurations.push(ms);
  await new Promise<void>((resolve) => {
    const tick = setTimeout(resolve, ms);
    signal?.addEventListener("abort", () => {
      clearTimeout(tick);
      resolve();
    });
  });
}

// ── Built-in resolvers ─────────────────────────────────────────────────────────

/**
 * Default resolver: calls `gh pr merge <prNumber> --admin --squash`.
 * Used as the last-resort fallback when polling times out.
 */
export const adminMergeResolver: MergeResolver = async ({ prNumber, cwd, execFile }) => {
  const execAsync: ExecFileAsync = makeExecAsync(execFile);
  await execAsync(
    "gh",
    ["pr", "merge", String(prNumber), "--admin", "--squash"],
    { cwd, timeout: 60_000 },
  );
};
