import { afterEach, describe, expect, it, vi } from "vitest";
import type { Command } from "commander";

import { resetAction, type IShowUpdateClient } from "../commands/reset.js";
import type { ForemanStore, Run } from "../../lib/store.js";
import type { MergeQueue } from "../../orchestrator/merge-queue.js";

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "bd-123",
    agent_type: "claude-sonnet-4-6",
    session_key: null,
    worktree_path: "/tmp/wt",
    status: "failed",
    started_at: new Date().toISOString(),
    completed_at: new Date().toISOString(),
    created_at: new Date().toISOString(),
    progress: null,
    ...overrides,
  };
}

function makeCommand(args: string[]): { cmd: Command; opts: Record<string, unknown> } {
  const opts: Record<string, unknown> = {
    bead: undefined,
    all: false,
    detectStuck: false,
    timeout: "15",
    dryRun: false,
    forceReopenClosed: false,
  };
  let timeoutSource: "default" | "user" = "default";

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--bead") {
      opts.bead = args[i + 1];
      i++;
    } else if (arg === "--all") {
      opts.all = true;
    } else if (arg === "--detect-stuck") {
      opts.detectStuck = true;
    } else if (arg === "--timeout") {
      opts.timeout = args[i + 1];
      timeoutSource = "user";
      i++;
    } else if (arg === "--dry-run") {
      opts.dryRun = true;
    } else if (arg === "--force-reopen-closed") {
      opts.forceReopenClosed = true;
    }
  }

  return {
    cmd: {
      getOptionValueSource: (name: string) => (name === "timeout" ? timeoutSource : undefined),
    } as Command,
    opts,
  };
}

function makeStore(overrides: Partial<ForemanStore> = {}): ForemanStore {
  return {
    getProjectByPath: vi.fn(() => ({ id: "proj-1", path: "/repo" })),
    getRunsForSeed: vi.fn((): Run[] => []),
    getRunsByStatus: vi.fn((): Run[] => []),
    getActiveRuns: vi.fn((): Run[] => []),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    close: vi.fn(),
    getDb: vi.fn(() => ({})),
    ...overrides,
  } as unknown as ForemanStore;
}

function makeVcs() {
  return {
    getCurrentBranch: vi.fn(async () => "main"),
    checkoutBranch: vi.fn(async () => {}),
    deleteBranch: vi.fn(async () => ({ deleted: false })),
    removeWorkspace: vi.fn(async () => {}),
  };
}

function makeSeeds(): IShowUpdateClient {
  return {
    show: vi.fn(async () => ({ status: "open" })),
    update: vi.fn(async () => {}),
  };
}

function makeMergeQueue(): MergeQueue {
  return {
    list: vi.fn(() => []),
    remove: vi.fn(),
    missingFromQueue: vi.fn(() => []),
  } as unknown as MergeQueue;
}

describe("resetAction contract truthfulness", () => {
  const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
  const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
  const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

  afterEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    logSpy.mockClear();
    errorSpy.mockClear();
    warnSpy.mockClear();
  });

  it("fails when --timeout is supplied without --detect-stuck", async () => {
    const { cmd, opts } = makeCommand(["--timeout", "30"]);

    const exitCode = await resetAction(opts, cmd);

    expect(exitCode).toBe(1);
    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining("--timeout requires --detect-stuck"));
    expect(logSpy).not.toHaveBeenCalled();
  });

  it("refuses landed bead resets with non-zero exit and no follow-on scans", async () => {
    const { cmd, opts } = makeCommand(["--bead", "bd-123"]);
    const store = makeStore({
      getRunsForSeed: vi.fn(() => [makeRun({ status: "merged" })]),
    });
    const detectMismatch = vi.fn(async () => ({ mismatches: [], fixed: 0, errors: [] }));
    const detectStale = vi.fn(async () => ({ results: [], closed: 0, reset: 0, errors: [] }));

    const exitCode = await resetAction(opts, cmd, {
      resolveProjectPath: vi.fn(async () => "/repo"),
      createVcs: vi.fn(async () => makeVcs() as any),
      createSeeds: vi.fn(() => makeSeeds()),
      createStore: vi.fn(() => store),
      createMergeQueue: vi.fn(() => makeMergeQueue()),
      detectAndFixMismatches: detectMismatch,
      detectAndHandleStaleBranches: detectStale,
    });

    expect(exitCode).toBe(1);
    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining("Refusing to reopen"));
    expect(detectMismatch).not.toHaveBeenCalled();
    expect(detectStale).not.toHaveBeenCalled();
    expect(store.close).toHaveBeenCalledTimes(1);
  });

  it("treats bead-scoped no-run requests as truthful no-ops", async () => {
    const { cmd, opts } = makeCommand(["--bead", "bd-missing"]);
    const store = makeStore({
      getRunsForSeed: vi.fn(() => []),
    });
    const detectMismatch = vi.fn(async () => ({ mismatches: [], fixed: 0, errors: [] }));
    const detectStale = vi.fn(async () => ({ results: [], closed: 0, reset: 0, errors: [] }));

    const exitCode = await resetAction(opts, cmd, {
      resolveProjectPath: vi.fn(async () => "/repo"),
      createVcs: vi.fn(async () => makeVcs() as any),
      createSeeds: vi.fn(() => makeSeeds()),
      createStore: vi.fn(() => store),
      createMergeQueue: vi.fn(() => makeMergeQueue()),
      detectAndFixMismatches: detectMismatch,
      detectAndHandleStaleBranches: detectStale,
    });

    expect(exitCode).toBe(0);
    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining("No runs found for bead bd-missing."));
    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining("Nothing changed."));
    expect(detectMismatch).not.toHaveBeenCalled();
    expect(detectStale).not.toHaveBeenCalled();
  });

  it("returns non-zero when stuck detection reports errors", async () => {
    const { cmd, opts } = makeCommand(["--detect-stuck", "--dry-run"]);
    const store = makeStore();

    const exitCode = await resetAction(opts, cmd, {
      resolveProjectPath: vi.fn(async () => "/repo"),
      createVcs: vi.fn(async () => makeVcs() as any),
      createSeeds: vi.fn(() => makeSeeds()),
      createStore: vi.fn(() => store),
      createMergeQueue: vi.fn(() => makeMergeQueue()),
      detectStuckRuns: vi.fn(async () => ({
        stuck: [],
        errors: ["Could not check run bd-123: sqlite locked"],
      })),
      detectAndFixMismatches: vi.fn(async () => ({ mismatches: [], fixed: 0, errors: [] })),
      detectAndHandleStaleBranches: vi.fn(async () => ({ results: [], closed: 0, reset: 0, errors: [] })),
    });

    expect(exitCode).toBe(1);
    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining("sqlite locked"));
    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining("Errors (1):"));
  });
});
