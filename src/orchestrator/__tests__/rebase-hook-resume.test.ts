/**
 * Unit tests for RebaseHook — pipeline resume after conflict resolution (TRD-009-TEST).
 *
 * Verifies:
 * - AC-T-009-1: rebase:resolved event triggers run status → running
 * - AC-T-009-2: EXPLORER_REPORT.md forwarded to developer-<seedId> on resume
 * - AC-T-009-3: phase:start re-dispatched for resumePhase
 * - AC-T-009-4: operator notification sent to "foreman" on resume
 * - AC-T-009-5: second resolution attempt transitions run to failed (single-attempt limit)
 */

import { describe, it, expect, vi } from "vitest";
import { writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { PipelineEventBus } from "../pipeline-events.js";
import type { PipelineEvent } from "../pipeline-events.js";
import { RebaseHook } from "../rebase-hook.js";
import type { RebaseHookConfig } from "../rebase-hook.js";
import type { VcsBackend } from "../../lib/vcs/index.js";
import type { ForemanStore } from "../../lib/store.js";
import type { SqliteMailClient } from "../../lib/sqlite-mail-client.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeVcs(): VcsBackend {
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
    diff: vi.fn().mockResolvedValue(""),
    getChangedFiles: vi.fn(),
    getRefCommitTimestamp: vi.fn(),
    getModifiedFiles: vi.fn(),
    getConflictingFiles: vi.fn().mockResolvedValue(["src/conflict.ts"]),
    status: vi.fn(),
    cleanWorkingTree: vi.fn(),
    getFinalizeCommands: vi.fn(),
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

function makeConfig(worktreePath: string, overrides: Partial<RebaseHookConfig> = {}): RebaseHookConfig {
  return {
    runId: "run-1",
    seedId: "seed-abc",
    worktreePath,
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

/** Trigger conflict path and wait for async completion. Returns capture of unhandled rejection. */
async function triggerAndWaitForConflict(config: RebaseHookConfig): Promise<void> {
  const rejectionHandler = (_reason: unknown) => {};
  process.on("unhandledRejection", rejectionHandler);
  config.eventBus.safeEmit({
    type: "phase:complete",
    runId: config.runId,
    phase: "developer",
    worktreePath: config.worktreePath,
    cost: 0,
  });
  await new Promise((r) => setTimeout(r, 50));
  process.off("unhandledRejection", rejectionHandler);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("RebaseHook — pipeline resume after conflict resolved", () => {
  it("AC-T-009-1: rebase:resolved triggers run status → running", async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "rebase-resume-"));
    try {
      const store = makeStore();
      const config = makeConfig(tmpDir, { store });
      const hook = new RebaseHook(config);
      hook.register();

      await triggerAndWaitForConflict(config);

      // Now emit rebase:resolved
      config.eventBus.safeEmit({ type: "rebase:resolved", runId: "run-1", resumePhase: "developer" });
      await new Promise((r) => setTimeout(r, 50));

      const calls = (store.updateRunStatus as ReturnType<typeof vi.fn>).mock.calls as [string, string][];
      const statuses = calls.map((c) => c[1]);
      // After resolution: status → running
      expect(statuses).toContain("running");
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("AC-T-009-2: EXPLORER_REPORT.md forwarded to developer-<seedId> when present", async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "rebase-resume-report-"));
    try {
      // Write a fake EXPLORER_REPORT.md
      writeFileSync(join(tmpDir, "EXPLORER_REPORT.md"), "# Explorer Report\nSome findings here.");

      const mailClient = makeMailClient();
      const config = makeConfig(tmpDir, { mailClient });
      const hook = new RebaseHook(config);
      hook.register();

      await triggerAndWaitForConflict(config);

      // Reset mail spy to isolate resume mails
      (mailClient.sendMessage as ReturnType<typeof vi.fn>).mockClear();

      config.eventBus.safeEmit({ type: "rebase:resolved", runId: "run-1", resumePhase: "developer" });
      await new Promise((r) => setTimeout(r, 50));

      const calls = (mailClient.sendMessage as ReturnType<typeof vi.fn>).mock.calls as [string, string, string][];
      const devMail = calls.find((c) => c[0] === "developer-seed-abc");
      expect(devMail).toBeDefined();
      expect(devMail![1]).toContain("[rebase-resolved]");
      expect(devMail![2]).toContain("# Explorer Report");
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("no developer mail when EXPLORER_REPORT.md absent", async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "rebase-resume-no-report-"));
    try {
      // No EXPLORER_REPORT.md written
      const mailClient = makeMailClient();
      const config = makeConfig(tmpDir, { mailClient });
      const hook = new RebaseHook(config);
      hook.register();

      await triggerAndWaitForConflict(config);
      (mailClient.sendMessage as ReturnType<typeof vi.fn>).mockClear();

      config.eventBus.safeEmit({ type: "rebase:resolved", runId: "run-1", resumePhase: "developer" });
      await new Promise((r) => setTimeout(r, 50));

      const calls = (mailClient.sendMessage as ReturnType<typeof vi.fn>).mock.calls as [string, string, string][];
      const devMail = calls.find((c) => c[0] === "developer-seed-abc");
      expect(devMail).toBeUndefined();
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("AC-T-009-3: phase:start re-dispatched for resumePhase", async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "rebase-resume-phase-"));
    try {
      const config = makeConfig(tmpDir);
      const hook = new RebaseHook(config);
      hook.register();

      const phaseStartEvents: PipelineEvent[] = [];
      config.eventBus.on("phase:start", (e) => { phaseStartEvents.push(e); });

      await triggerAndWaitForConflict(config);

      config.eventBus.safeEmit({ type: "rebase:resolved", runId: "run-1", resumePhase: "developer" });
      await new Promise((r) => setTimeout(r, 50));

      const resumeStart = phaseStartEvents.find(
        (e) => e.type === "phase:start" && (e as Extract<PipelineEvent, { type: "phase:start" }>).phase === "developer",
      );
      expect(resumeStart).toBeDefined();
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("AC-T-009-4: operator notification sent to 'foreman' on resume", async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "rebase-resume-notify-"));
    try {
      const mailClient = makeMailClient();
      const config = makeConfig(tmpDir, { mailClient });
      const hook = new RebaseHook(config);
      hook.register();

      await triggerAndWaitForConflict(config);
      (mailClient.sendMessage as ReturnType<typeof vi.fn>).mockClear();

      config.eventBus.safeEmit({ type: "rebase:resolved", runId: "run-1", resumePhase: "developer" });
      await new Promise((r) => setTimeout(r, 50));

      const calls = (mailClient.sendMessage as ReturnType<typeof vi.fn>).mock.calls as [string, string, string][];
      const foremanNotif = calls.find((c) => c[0] === "foreman");
      expect(foremanNotif).toBeDefined();
      expect(foremanNotif![1]).toContain("[rebase-resolved]");
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("AC-T-009-5: second resolution attempt transitions run to failed", async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "rebase-resume-limit-"));
    try {
      const store = makeStore();
      const config = makeConfig(tmpDir, { store });
      const hook = new RebaseHook(config);
      hook.register();

      await triggerAndWaitForConflict(config);

      // First resolution
      config.eventBus.safeEmit({ type: "rebase:resolved", runId: "run-1", resumePhase: "developer" });
      await new Promise((r) => setTimeout(r, 50));

      (store.updateRunStatus as ReturnType<typeof vi.fn>).mockClear();

      // Second resolution attempt — should be rejected
      config.eventBus.safeEmit({ type: "rebase:resolved", runId: "run-1", resumePhase: "developer" });
      await new Promise((r) => setTimeout(r, 50));

      const calls = (store.updateRunStatus as ReturnType<typeof vi.fn>).mock.calls as [string, string][];
      expect(calls.some((c) => c[1] === "failed")).toBe(true);
      // Should NOT transition to running again
      expect(calls.some((c) => c[1] === "running")).toBe(false);
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("resolved event for different runId is ignored", async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "rebase-resume-other-"));
    try {
      const store = makeStore();
      const config = makeConfig(tmpDir, { store, runId: "run-1" });
      const hook = new RebaseHook(config);
      hook.register();

      await triggerAndWaitForConflict(config);
      (store.updateRunStatus as ReturnType<typeof vi.fn>).mockClear();

      // Emit resolved for a DIFFERENT run
      config.eventBus.safeEmit({ type: "rebase:resolved", runId: "run-OTHER", resumePhase: "developer" });
      await new Promise((r) => setTimeout(r, 50));

      expect(store.updateRunStatus).not.toHaveBeenCalled();
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
