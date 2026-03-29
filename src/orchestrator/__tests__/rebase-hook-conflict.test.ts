/**
 * Unit tests for RebaseHook — conflict path and escalation (TRD-007-TEST, TRD-008-TEST, TRD-015-TEST).
 *
 * Verifies:
 * - AC-T-007-1: rebase:conflict event emitted with conflicting files
 * - AC-T-007-2: run status transitions to rebase_conflict then rebase_resolving
 * - AC-T-007-3: RebaseConflictError thrown to suspend phase loop
 * - AC-T-008-1: abortRebase called immediately after conflict detected
 * - AC-T-008-2: rebase-conflict mail sent to troubleshooter-<seedId> with skill field
 * - AC-T-015-1: operator notification sent to "foreman" mailbox on conflict
 */

import { describe, it, expect, vi } from "vitest";
import { PipelineEventBus } from "../pipeline-events.js";
import type { PipelineEvent } from "../pipeline-events.js";
import { RebaseHook, RebaseConflictError } from "../rebase-hook.js";
import type { RebaseHookConfig } from "../rebase-hook.js";
import type { VcsBackend } from "../../lib/vcs/index.js";
import type { ForemanStore } from "../../lib/store.js";
import type { SqliteMailClient } from "../../lib/sqlite-mail-client.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeVcs(overrides: Partial<VcsBackend> = {}): VcsBackend {
  return {
    name: "git",
    getRepoRoot: vi.fn(),
    getMainRepoRoot: vi.fn(),
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    getCurrentBranch: vi.fn(),
    checkoutBranch: vi.fn(),
    branchExists: vi.fn(),
    branchExistsOnRemote: vi.fn(),
    deleteBranch: vi.fn(),
    createWorkspace: vi.fn(),
    removeWorkspace: vi.fn(),
    listWorkspaces: vi.fn(),
    stageAll: vi.fn(),
    commit: vi.fn(),
    push: vi.fn(),
    pull: vi.fn(),
    rebase: vi.fn().mockResolvedValue({ hasConflicts: true }),
    abortRebase: vi.fn().mockResolvedValue(undefined),
    merge: vi.fn(),
    getHeadId: vi.fn(),
    resolveRef: vi.fn(),
    fetch: vi.fn(),
    diff: vi.fn().mockResolvedValue("(diff output)"),
    getChangedFiles: vi.fn(),
    getRefCommitTimestamp: vi.fn(),
    getModifiedFiles: vi.fn(),
    getConflictingFiles: vi.fn().mockResolvedValue(["src/a.ts", "src/b.ts"]),
    status: vi.fn(),
    cleanWorkingTree: vi.fn(),
    getFinalizeCommands: vi.fn(),
    ...overrides,
  } as unknown as VcsBackend;
}

function makeStore(): ForemanStore {
  return {
    updateRunStatus: vi.fn(),
  } as unknown as ForemanStore;
}

function makeMailClient(): SqliteMailClient {
  return {
    sendMessage: vi.fn().mockResolvedValue(undefined),
  } as unknown as SqliteMailClient;
}

function makeConfig(overrides: Partial<RebaseHookConfig> = {}): RebaseHookConfig {
  return {
    runId: "run-1",
    seedId: "seed-xyz",
    worktreePath: "/tmp/wt",
    workflow: {
      name: "test",
      phases: [{ name: "developer", prompt: "developer.md" }, { name: "qa", prompt: "qa.md" }],
      rebaseAfterPhase: "developer",
    },
    vcs: makeVcs(),
    store: makeStore(),
    mailClient: makeMailClient(),
    eventBus: new PipelineEventBus(),
    ...overrides,
  };
}

// ── Helper: trigger conflict path and capture error ───────────────────────────

async function triggerConflict(config: RebaseHookConfig): Promise<{
  error: unknown;
  events: PipelineEvent[];
}> {
  const events: PipelineEvent[] = [];
  config.eventBus.on("rebase:start",    (e) => { events.push(e); });
  config.eventBus.on("rebase:conflict", (e) => { events.push(e); });
  config.eventBus.on("rebase:clean",    (e) => { events.push(e); });

  const hook = new RebaseHook(config);
  hook.register();

  let error: unknown = null;
  config.eventBus.on("pipeline:error", (e) => { error = e; });

  // The conflict path throws RebaseConflictError which gets caught by safeEmit
  // and re-emitted as pipeline:error. We need to check that directly.
  // Actually safeEmit wraps async handlers — the throw propagates through the async handler.
  // Let's manually invoke via emitting phase:complete and catching via pipeline:error.

  // We need to capture the error from the async handler. Since safeEmit catches thrown errors
  // from sync listeners but NOT from async listeners (void Promise), we need a different approach.
  // The RebaseHook handler is async and throws RebaseConflictError.
  // safeEmit doesn't await async handlers, so the error propagates as an unhandled rejection.
  //
  // We capture it via process.on('unhandledRejection') or use a different approach.
  // Let's use a Promise that resolves once the error occurs.

  let capturedError: unknown = null;
  const errorPromise = new Promise<void>((resolve) => {
    const originalHandler = (reason: unknown) => {
      capturedError = reason;
      process.off("unhandledRejection", originalHandler);
      resolve();
    };
    process.on("unhandledRejection", originalHandler);
  });

  config.eventBus.safeEmit({
    type: "phase:complete",
    runId: "run-1",
    phase: "developer",
    worktreePath: "/tmp/wt",
    cost: 0,
  });

  // Wait for async handler to complete (either resolve or throw)
  await Promise.race([
    errorPromise,
    new Promise((r) => setTimeout(r, 100)),
  ]);

  return { error: capturedError, events };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("RebaseHook — conflict path", () => {
  it("AC-T-007-1: rebase:conflict event emitted with conflicting files", async () => {
    const bus = new PipelineEventBus();
    const conflictEvents: PipelineEvent[] = [];
    bus.on("rebase:conflict", (e) => { conflictEvents.push(e); });

    const vcs = makeVcs({
      rebase: vi.fn().mockResolvedValue({ hasConflicts: true }),
      getConflictingFiles: vi.fn().mockResolvedValue(["src/a.ts", "src/b.ts"]),
      abortRebase: vi.fn().mockResolvedValue(undefined),
    });
    const store = makeStore();
    const config = makeConfig({ vcs, store, eventBus: bus });
    const hook = new RebaseHook(config);
    hook.register();

    // Catch unhandled rejection from RebaseConflictError
    const rejectionHandler = (_reason: unknown) => {};
    process.on("unhandledRejection", rejectionHandler);

    bus.safeEmit({ type: "phase:complete", runId: "run-1", phase: "developer", worktreePath: "/tmp/wt", cost: 0 });
    await new Promise((r) => setTimeout(r, 50));

    process.off("unhandledRejection", rejectionHandler);

    expect(conflictEvents).toHaveLength(1);
    const evt = conflictEvents[0] as Extract<PipelineEvent, { type: "rebase:conflict" }>;
    expect(evt.conflictingFiles).toEqual(["src/a.ts", "src/b.ts"]);
    expect(evt.runId).toBe("run-1");
  });

  it("AC-T-007-2: run status transitions to rebase_conflict then rebase_resolving", async () => {
    const bus = new PipelineEventBus();
    const vcs = makeVcs({
      rebase: vi.fn().mockResolvedValue({ hasConflicts: true }),
      getConflictingFiles: vi.fn().mockResolvedValue(["src/x.ts"]),
      abortRebase: vi.fn().mockResolvedValue(undefined),
    });
    const store = makeStore();
    const config = makeConfig({ vcs, store, eventBus: bus });
    const hook = new RebaseHook(config);
    hook.register();

    const rejectionHandler = (_reason: unknown) => {};
    process.on("unhandledRejection", rejectionHandler);

    bus.safeEmit({ type: "phase:complete", runId: "run-1", phase: "developer", worktreePath: "/tmp/wt", cost: 0 });
    await new Promise((r) => setTimeout(r, 50));

    process.off("unhandledRejection", rejectionHandler);

    const calls = (store.updateRunStatus as ReturnType<typeof vi.fn>).mock.calls as [string, string][];
    const statuses = calls.map((c) => c[1]);
    expect(statuses).toContain("rebase_conflict");
    expect(statuses).toContain("rebase_resolving");
    // rebase_conflict should come before rebase_resolving
    expect(statuses.indexOf("rebase_conflict")).toBeLessThan(statuses.indexOf("rebase_resolving"));
  });

  it("AC-T-008-1: abortRebase called immediately after conflict", async () => {
    const bus = new PipelineEventBus();
    const abortRebase = vi.fn().mockResolvedValue(undefined);
    const vcs = makeVcs({
      rebase: vi.fn().mockResolvedValue({ hasConflicts: true }),
      getConflictingFiles: vi.fn().mockResolvedValue(["src/conflict.ts"]),
      abortRebase,
    });
    const config = makeConfig({ vcs, eventBus: bus });
    const hook = new RebaseHook(config);
    hook.register();

    const rejectionHandler = (_reason: unknown) => {};
    process.on("unhandledRejection", rejectionHandler);

    bus.safeEmit({ type: "phase:complete", runId: "run-1", phase: "developer", worktreePath: "/tmp/wt", cost: 0 });
    await new Promise((r) => setTimeout(r, 50));

    process.off("unhandledRejection", rejectionHandler);

    expect(abortRebase).toHaveBeenCalledOnce();
    expect(abortRebase).toHaveBeenCalledWith("/tmp/wt");
  });

  it("AC-T-008-2: rebase-conflict mail sent to troubleshooter-<seedId> with skill field", async () => {
    const bus = new PipelineEventBus();
    const mailClient = makeMailClient();
    const vcs = makeVcs({
      rebase: vi.fn().mockResolvedValue({ hasConflicts: true }),
      getConflictingFiles: vi.fn().mockResolvedValue(["src/conflict.ts"]),
      abortRebase: vi.fn().mockResolvedValue(undefined),
      diff: vi.fn().mockResolvedValue("upstream diff content"),
    });
    const config = makeConfig({ vcs, mailClient, eventBus: bus, seedId: "seed-xyz" });
    const hook = new RebaseHook(config);
    hook.register();

    const rejectionHandler = (_reason: unknown) => {};
    process.on("unhandledRejection", rejectionHandler);

    bus.safeEmit({ type: "phase:complete", runId: "run-1", phase: "developer", worktreePath: "/tmp/wt", cost: 0 });
    await new Promise((r) => setTimeout(r, 50));

    process.off("unhandledRejection", rejectionHandler);

    const calls = (mailClient.sendMessage as ReturnType<typeof vi.fn>).mock.calls as [string, string, string][];
    // Find the troubleshooter mail
    const troubleshooterCall = calls.find((c) => c[0] === "troubleshooter-seed-xyz");
    expect(troubleshooterCall).toBeDefined();

    const [, subject, body] = troubleshooterCall!;
    expect(subject).toContain("[rebase-conflict]");

    const parsed = JSON.parse(body) as { skill: string; conflictingFiles: string[]; type: string };
    expect(parsed.skill).toBe("resolve-rebase-conflict");
    expect(parsed.type).toBe("rebase-conflict");
    expect(parsed.conflictingFiles).toContain("src/conflict.ts");
  });

  it("AC-T-015-1: operator notification sent to 'foreman' mailbox on conflict", async () => {
    const bus = new PipelineEventBus();
    const mailClient = makeMailClient();
    const vcs = makeVcs({
      rebase: vi.fn().mockResolvedValue({ hasConflicts: true }),
      getConflictingFiles: vi.fn().mockResolvedValue(["src/x.ts"]),
      abortRebase: vi.fn().mockResolvedValue(undefined),
    });
    const config = makeConfig({ vcs, mailClient, eventBus: bus });
    const hook = new RebaseHook(config);
    hook.register();

    const rejectionHandler = (_reason: unknown) => {};
    process.on("unhandledRejection", rejectionHandler);

    bus.safeEmit({ type: "phase:complete", runId: "run-1", phase: "developer", worktreePath: "/tmp/wt", cost: 0 });
    await new Promise((r) => setTimeout(r, 50));

    process.off("unhandledRejection", rejectionHandler);

    const calls = (mailClient.sendMessage as ReturnType<typeof vi.fn>).mock.calls as [string, string, string][];
    const foremanCall = calls.find((c) => c[0] === "foreman");
    expect(foremanCall).toBeDefined();
    expect(foremanCall![1]).toContain("[rebase-start]");
  });

  it("AC-T-007-3: RebaseConflictError is the cause of pipeline suspension", async () => {
    const bus = new PipelineEventBus();
    const vcs = makeVcs({
      rebase: vi.fn().mockResolvedValue({ hasConflicts: true }),
      getConflictingFiles: vi.fn().mockResolvedValue(["f.ts"]),
      abortRebase: vi.fn().mockResolvedValue(undefined),
    });
    const config = makeConfig({ vcs, eventBus: bus });
    const hook = new RebaseHook(config);
    hook.register();

    let capturedError: unknown = null;
    const errorPromise = new Promise<void>((resolve) => {
      const handler = (reason: unknown) => {
        capturedError = reason;
        process.off("unhandledRejection", handler);
        resolve();
      };
      process.on("unhandledRejection", handler);
    });

    bus.safeEmit({ type: "phase:complete", runId: "run-1", phase: "developer", worktreePath: "/tmp/wt", cost: 0 });
    await Promise.race([errorPromise, new Promise((r) => setTimeout(r, 100))]);

    expect(capturedError).toBeInstanceOf(RebaseConflictError);
    const err = capturedError as RebaseConflictError;
    expect(err.runId).toBe("run-1");
    expect(err.conflictingFiles).toContain("f.ts");
  });
});
