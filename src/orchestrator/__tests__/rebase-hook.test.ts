/**
 * Unit tests for RebaseHook — clean path and no-op cases (TRD-006-TEST, TRD-010-TEST, TRD-011-TEST).
 *
 * Verifies:
 * - AC-T-006-1: RebaseHook fires only when phase matches rebaseAfterPhase
 * - AC-T-006-2: No rebase events emitted when phase does not match
 * - AC-T-010-1: upstreamCommits=0 → no mail sent
 * - AC-T-010-2: upstreamCommits>0 → rebase-context mail sent to qa-<seedId>
 * - AC-T-011-1: Changed file list parsed from diff output
 * - AC-T-011-2: File list truncated at MAX_CHANGED_FILES with truncated=true
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import { PipelineEventBus } from "../pipeline-events.js";
import type { PipelineEvent } from "../pipeline-events.js";
import { RebaseHook } from "../rebase-hook.js";
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
    rebase: vi.fn().mockResolvedValue({ hasConflicts: false }),
    abortRebase: vi.fn(),
    merge: vi.fn(),
    getHeadId: vi.fn(),
    resolveRef: vi.fn(),
    fetch: vi.fn(),
    diff: vi.fn().mockResolvedValue(""),
    getChangedFiles: vi.fn(),
    getRefCommitTimestamp: vi.fn(),
    getModifiedFiles: vi.fn(),
    getConflictingFiles: vi.fn().mockResolvedValue([]),
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
    seedId: "seed-abc",
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

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("RebaseHook — phase mismatch (no-op)", () => {
  it("AC-T-006-2: no rebase events when phase does not match rebaseAfterPhase", async () => {
    const bus = new PipelineEventBus();
    const rebaseEvents: PipelineEvent[] = [];
    bus.on("rebase:start", (e) => { rebaseEvents.push(e); });
    bus.on("rebase:clean", (e) => { rebaseEvents.push(e); });
    bus.on("rebase:conflict", (e) => { rebaseEvents.push(e); });

    const vcs = makeVcs();
    const config = makeConfig({ vcs, eventBus: bus });
    const hook = new RebaseHook(config);
    hook.register();

    // Fire phase:complete for a phase that does NOT match rebaseAfterPhase
    bus.safeEmit({ type: "phase:complete", runId: "run-1", phase: "explorer", worktreePath: "/tmp/wt", cost: 0 });

    // Allow any pending promises to settle
    await new Promise((r) => setImmediate(r));

    expect(rebaseEvents).toHaveLength(0);
    expect(vcs.rebase).not.toHaveBeenCalled();
  });

  it("no-op when rebaseAfterPhase is not configured in workflow", async () => {
    const bus = new PipelineEventBus();
    const rebaseEvents: PipelineEvent[] = [];
    bus.on("rebase:start", (e) => { rebaseEvents.push(e); });

    const vcs = makeVcs();
    const config = makeConfig({
      vcs,
      eventBus: bus,
      workflow: {
        name: "test",
        phases: [{ name: "developer", prompt: "developer.md" }],
        // No rebaseAfterPhase
      },
    });
    const hook = new RebaseHook(config);
    hook.register();

    bus.safeEmit({ type: "phase:complete", runId: "run-1", phase: "developer", worktreePath: "/tmp/wt", cost: 0 });
    await new Promise((r) => setImmediate(r));

    expect(rebaseEvents).toHaveLength(0);
    expect(vcs.rebase).not.toHaveBeenCalled();
  });
});

describe("RebaseHook — clean path", () => {
  it("AC-T-006-1: rebase:start and rebase:clean emitted on clean rebase", async () => {
    const bus = new PipelineEventBus();
    const events: PipelineEvent[] = [];
    bus.on("rebase:start", (e) => { events.push(e); });
    bus.on("rebase:clean", (e) => { events.push(e); });

    const vcs = makeVcs({
      rebase: vi.fn().mockResolvedValue({ hasConflicts: false }),
      diff: vi.fn().mockResolvedValue(""),
    });
    const config = makeConfig({ vcs, eventBus: bus });
    const hook = new RebaseHook(config);
    hook.register();

    bus.safeEmit({ type: "phase:complete", runId: "run-1", phase: "developer", worktreePath: "/tmp/wt", cost: 0 });
    await new Promise((r) => setImmediate(r));

    expect(events.map((e) => e.type)).toEqual(["rebase:start", "rebase:clean"]);
    const startEvent = events[0] as Extract<PipelineEvent, { type: "rebase:start" }>;
    expect(startEvent.runId).toBe("run-1");
    expect(startEvent.phase).toBe("developer");
    expect(startEvent.target).toContain("origin/");
  });

  it("AC-T-010-1: no mail sent when upstreamCommits=0", async () => {
    const bus = new PipelineEventBus();
    const mailClient = makeMailClient();
    const vcs = makeVcs({
      rebase: vi.fn().mockResolvedValue({ hasConflicts: false }),
      diff: vi.fn().mockResolvedValue(""), // empty diff = 0 changed files
    });
    const config = makeConfig({ vcs, mailClient, eventBus: bus });
    const hook = new RebaseHook(config);
    hook.register();

    bus.safeEmit({ type: "phase:complete", runId: "run-1", phase: "developer", worktreePath: "/tmp/wt", cost: 0 });
    await new Promise((r) => setImmediate(r));

    expect(mailClient.sendMessage).not.toHaveBeenCalled();
  });

  it("AC-T-010-2: rebase-context mail sent to qa-<seedId> when upstreamCommits>0", async () => {
    const bus = new PipelineEventBus();
    const mailClient = makeMailClient();
    const diffWithFiles = [
      "diff --git a/src/foo.ts b/src/foo.ts",
      "--- a/src/foo.ts",
      "+++ b/src/foo.ts",
      "@@ -1 +1 @@",
      "-old",
      "+new",
    ].join("\n");
    const vcs = makeVcs({
      rebase: vi.fn().mockResolvedValue({ hasConflicts: false }),
      diff: vi.fn().mockResolvedValue(diffWithFiles),
    });
    const config = makeConfig({ vcs, mailClient, eventBus: bus, seedId: "seed-abc" });
    const hook = new RebaseHook(config);
    hook.register();

    bus.safeEmit({ type: "phase:complete", runId: "run-1", phase: "developer", worktreePath: "/tmp/wt", cost: 0 });
    await new Promise((r) => setImmediate(r));

    expect(mailClient.sendMessage).toHaveBeenCalledOnce();
    const [to, subject, body] = (mailClient.sendMessage as ReturnType<typeof vi.fn>).mock.calls[0] as [string, string, string];
    expect(to).toBe("qa-seed-abc");
    expect(subject).toContain("[rebase-context]");
    const parsed = JSON.parse(body) as { type: string; changedFiles: string[] };
    expect(parsed.type).toBe("rebase-context");
    expect(parsed.changedFiles).toContain("src/foo.ts");
  });

  it("AC-T-011-1: parseDiffFiles extracts unique file paths", async () => {
    const bus = new PipelineEventBus();
    const events: PipelineEvent[] = [];
    bus.on("rebase:clean", (e) => { events.push(e); });

    const diffOutput = [
      "diff --git a/src/a.ts b/src/a.ts",
      "--- a/src/a.ts",
      "+++ b/src/a.ts",
      "diff --git a/src/b.ts b/src/b.ts",
      "--- a/src/b.ts",
      "+++ b/src/b.ts",
      "diff --git a/src/a.ts b/src/a.ts", // duplicate
      "--- a/src/a.ts",
      "+++ b/src/a.ts",
    ].join("\n");

    const vcs = makeVcs({
      rebase: vi.fn().mockResolvedValue({ hasConflicts: false }),
      diff: vi.fn().mockResolvedValue(diffOutput),
    });
    const config = makeConfig({ vcs, eventBus: bus });
    const hook = new RebaseHook(config);
    hook.register();

    bus.safeEmit({ type: "phase:complete", runId: "run-1", phase: "developer", worktreePath: "/tmp/wt", cost: 0 });
    await new Promise((r) => setImmediate(r));

    const cleanEvent = events[0] as Extract<PipelineEvent, { type: "rebase:clean" }>;
    // Unique files: src/a.ts, src/b.ts
    expect(cleanEvent.changedFiles).toHaveLength(2);
    expect(cleanEvent.changedFiles).toContain("src/a.ts");
    expect(cleanEvent.changedFiles).toContain("src/b.ts");
  });

  it("AC-T-011-2: file list truncated at 100 files with truncated=true in mail", async () => {
    const bus = new PipelineEventBus();
    const mailClient = makeMailClient();

    // Generate diff with 105 unique files
    const lines: string[] = [];
    for (let i = 0; i < 105; i++) {
      lines.push(`diff --git a/src/file${i}.ts b/src/file${i}.ts`);
      lines.push(`--- a/src/file${i}.ts`);
      lines.push(`+++ b/src/file${i}.ts`);
    }

    const vcs = makeVcs({
      rebase: vi.fn().mockResolvedValue({ hasConflicts: false }),
      diff: vi.fn().mockResolvedValue(lines.join("\n")),
    });
    const config = makeConfig({ vcs, mailClient, eventBus: bus });
    const hook = new RebaseHook(config);
    hook.register();

    bus.safeEmit({ type: "phase:complete", runId: "run-1", phase: "developer", worktreePath: "/tmp/wt", cost: 0 });
    await new Promise((r) => setImmediate(r));

    expect(mailClient.sendMessage).toHaveBeenCalledOnce();
    const body = (mailClient.sendMessage as ReturnType<typeof vi.fn>).mock.calls[0]?.[2] as string;
    const parsed = JSON.parse(body) as { truncated: boolean; changedFiles: string[]; upstreamCommits: number };
    expect(parsed.truncated).toBe(true);
    expect(parsed.changedFiles).toHaveLength(100);
    expect(parsed.upstreamCommits).toBe(105); // actual count when truncated
  });
});

describe("RebaseHook — rebase target resolution", () => {
  it("uses workflow.rebaseTarget when provided", async () => {
    const bus = new PipelineEventBus();
    const events: PipelineEvent[] = [];
    bus.on("rebase:start", (e) => { events.push(e); });

    const vcs = makeVcs({
      rebase: vi.fn().mockResolvedValue({ hasConflicts: false }),
    });
    const config = makeConfig({
      vcs,
      eventBus: bus,
      workflow: {
        name: "test",
        phases: [{ name: "developer", prompt: "developer.md" }],
        rebaseAfterPhase: "developer",
        rebaseTarget: "origin/release",
      },
    });
    const hook = new RebaseHook(config);
    hook.register();

    bus.safeEmit({ type: "phase:complete", runId: "run-1", phase: "developer", worktreePath: "/tmp/wt", cost: 0 });
    await new Promise((r) => setImmediate(r));

    const startEvent = events[0] as Extract<PipelineEvent, { type: "rebase:start" }>;
    expect(startEvent.target).toBe("origin/release");
  });

  it("defaults to origin/<defaultBranch> when rebaseTarget absent", async () => {
    const bus = new PipelineEventBus();
    const events: PipelineEvent[] = [];
    bus.on("rebase:start", (e) => { events.push(e); });

    const vcs = makeVcs({
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
      rebase: vi.fn().mockResolvedValue({ hasConflicts: false }),
    });
    const config = makeConfig({ vcs, eventBus: bus });
    const hook = new RebaseHook(config);
    hook.register();

    bus.safeEmit({ type: "phase:complete", runId: "run-1", phase: "developer", worktreePath: "/tmp/wt", cost: 0 });
    await new Promise((r) => setImmediate(r));

    const startEvent = events[0] as Extract<PipelineEvent, { type: "rebase:start" }>;
    expect(startEvent.target).toBe("origin/main");
  });
});
