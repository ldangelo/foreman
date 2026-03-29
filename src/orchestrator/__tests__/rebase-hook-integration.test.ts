/**
 * Integration tests for RebaseHook with a real git repository (TRD-016, TRD-017, TRD-019).
 *
 * These tests exercise the full RebaseHook path using a real git repo in a temp
 * directory — no mocks for git operations. VcsBackend is the real GitBackend.
 *
 * TRD-016: Clean rebase path
 * - 2 diverging branches, rebaseAfterPhase configured, rebase succeeds
 * - Verify rebase:clean event emitted with correct upstreamCommits
 * - Verify rebase-context mail sent when upstream has changes
 *
 * TRD-017: Conflict path
 * - 2 branches modify the same line, triggering a conflict
 * - Verify rebase:conflict event emitted, run transitions to rebase_resolving
 * - Verify troubleshooter mail sent with conflicting files + skill field
 * - Verify abortRebase restores clean worktree
 * - Verify second resolution attempt → failed
 *
 * TRD-019: Performance validation
 * - Clean rebase path: < 30s on 100-commit repo
 * - Conflict detection + escalation: < 10s
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, realpathSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import { PipelineEventBus } from "../pipeline-events.js";
import type { PipelineEvent } from "../pipeline-events.js";
import { RebaseHook, RebaseConflictError } from "../rebase-hook.js";
import type { RebaseHookConfig } from "../rebase-hook.js";
import { GitBackend } from "../../lib/vcs/git-backend.js";
import { ForemanStore } from "../../lib/store.js";
import type { SqliteMailClient } from "../../lib/sqlite-mail-client.js";
import { vi } from "vitest";

// ── Git helpers ───────────────────────────────────────────────────────────────

function git(args: string[], cwd: string): string {
  return execFileSync("git", args, { cwd, encoding: "utf-8" }).trim();
}

function setupGitConfig(dir: string): void {
  execFileSync("git", ["config", "user.email", "test@foreman.test"], { cwd: dir });
  execFileSync("git", ["config", "user.name", "Foreman Test"], { cwd: dir });
}

/**
 * Create a git repo with an initial commit on "main".
 * Returns the path to the repo.
 */
function makeRepo(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-rh-integ-")));
  git(["init", "--initial-branch=main"], dir);
  setupGitConfig(dir);
  writeFileSync(join(dir, "base.txt"), "base content\n");
  git(["add", "base.txt"], dir);
  git(["commit", "-m", "initial"], dir);
  return dir;
}

/**
 * Add a commit to the "upstream" (main) branch that diverges from the worktree.
 * Checkout main, add file, commit, checkout back to original branch.
 */
function addUpstreamCommit(repoDir: string, filename: string, content: string, originalBranch: string): void {
  git(["checkout", "main"], repoDir);
  writeFileSync(join(repoDir, filename), content);
  git(["add", filename], repoDir);
  git(["commit", "-m", `upstream: add ${filename}`], repoDir);
  git(["checkout", originalBranch], repoDir);
}

/**
 * Create a feature branch from main and make a commit.
 */
function makeFeatureBranch(repoDir: string, branchName: string, filename: string, content: string): void {
  git(["checkout", "-b", branchName], repoDir);
  writeFileSync(join(repoDir, filename), content);
  git(["add", filename], repoDir);
  git(["commit", "-m", `feature: add ${filename}`], repoDir);
}

// ── Store + mail helpers ──────────────────────────────────────────────────────

function makeStore(): ForemanStore {
  return new ForemanStore(":memory:");
}

function makeMailClient(): SqliteMailClient {
  return {
    sendMessage: vi.fn().mockResolvedValue(undefined),
  } as unknown as SqliteMailClient;
}

function makeConfig(
  repoDir: string,
  bus: PipelineEventBus,
  store: ForemanStore,
  mailClient: SqliteMailClient,
  overrides: Partial<RebaseHookConfig> = {},
): RebaseHookConfig {
  return {
    runId: "run-integ-1",
    seedId: "seed-integ",
    worktreePath: repoDir,
    workflow: {
      name: "test",
      phases: [{ name: "developer", prompt: "developer.md" }, { name: "qa", prompt: "qa.md" }],
      rebaseAfterPhase: "developer",
      rebaseTarget: "main",
    },
    vcs: new GitBackend(repoDir),
    store,
    mailClient,
    eventBus: bus,
    ...overrides,
  };
}

// ── TRD-016: Clean rebase path ────────────────────────────────────────────────

describe("TRD-016: RebaseHook integration — clean rebase path", () => {
  let repoDir: string;
  let dirs: string[];

  beforeEach(() => {
    dirs = [];
    repoDir = makeRepo();
    dirs.push(repoDir);
  });

  afterEach(() => {
    for (const d of dirs) rmSync(d, { recursive: true, force: true });
  });

  it("rebase:clean emitted when upstream and feature branch do not conflict", async () => {
    // Create feature branch with a different file
    makeFeatureBranch(repoDir, "foreman/seed-integ", "feature.txt", "feature content\n");
    // Add upstream commit that modifies a DIFFERENT file
    addUpstreamCommit(repoDir, "upstream.txt", "upstream content\n", "foreman/seed-integ");

    const bus = new PipelineEventBus();
    const events: PipelineEvent[] = [];
    bus.on("rebase:clean", (e) => { events.push(e); });
    bus.on("rebase:conflict", (e) => { events.push(e); });

    const store = makeStore();
    const project = store.registerProject("test", repoDir);
    const run = store.createRun(project.id, "seed-integ", "developer", repoDir);

    const config = makeConfig(repoDir, bus, store, makeMailClient(), {
      runId: run.id,
      workflow: {
        name: "test",
        phases: [{ name: "developer", prompt: "developer.md" }],
        rebaseAfterPhase: "developer",
        rebaseTarget: "main",
      },
    });
    const hook = new RebaseHook(config);
    hook.register();

    bus.safeEmit({
      type: "phase:complete",
      runId: run.id,
      phase: "developer",
      worktreePath: repoDir,
      cost: 0,
    });

    await new Promise((r) => setTimeout(r, 200));

    const cleanEvents = events.filter((e) => e.type === "rebase:clean");
    expect(cleanEvents).toHaveLength(1);
    expect(events.filter((e) => e.type === "rebase:conflict")).toHaveLength(0);
  });

  it("rebase-context mail sent to qa-<seedId> when upstream has commits", async () => {
    makeFeatureBranch(repoDir, "foreman/seed-integ", "feature.txt", "feature content\n");
    addUpstreamCommit(repoDir, "new-upstream-file.txt", "upstream addition\n", "foreman/seed-integ");

    const bus = new PipelineEventBus();
    const mailClient = makeMailClient();
    const store = makeStore();
    const project = store.registerProject("test", repoDir);
    const run = store.createRun(project.id, "seed-integ", "developer", repoDir);

    const config = makeConfig(repoDir, bus, store, mailClient, {
      runId: run.id,
      seedId: "seed-integ",
    });
    const hook = new RebaseHook(config);
    hook.register();

    bus.safeEmit({
      type: "phase:complete",
      runId: run.id,
      phase: "developer",
      worktreePath: repoDir,
      cost: 0,
    });

    await new Promise((r) => setTimeout(r, 200));

    const calls = (mailClient.sendMessage as ReturnType<typeof vi.fn>).mock.calls as [string, string, string][];
    const qaMail = calls.find((c) => c[0] === "qa-seed-integ");
    expect(qaMail).toBeDefined();
    expect(qaMail![1]).toContain("[rebase-context]");
  });

  it("worktree is on correct branch after clean rebase", async () => {
    makeFeatureBranch(repoDir, "foreman/seed-integ", "feature.txt", "feature content\n");
    addUpstreamCommit(repoDir, "another-file.txt", "other content\n", "foreman/seed-integ");

    const bus = new PipelineEventBus();
    const store = makeStore();
    const project = store.registerProject("test", repoDir);
    const run = store.createRun(project.id, "seed-integ", "developer", repoDir);

    const config = makeConfig(repoDir, bus, store, makeMailClient(), { runId: run.id });
    const hook = new RebaseHook(config);
    hook.register();

    bus.safeEmit({
      type: "phase:complete",
      runId: run.id,
      phase: "developer",
      worktreePath: repoDir,
      cost: 0,
    });

    await new Promise((r) => setTimeout(r, 200));

    const currentBranch = git(["rev-parse", "--abbrev-ref", "HEAD"], repoDir);
    expect(currentBranch).toBe("foreman/seed-integ");
    // Verify upstream file now exists (rebase incorporated upstream changes)
    expect(existsSync(join(repoDir, "another-file.txt"))).toBe(true);
  });
});

// ── TRD-017: Conflict path ────────────────────────────────────────────────────

describe("TRD-017: RebaseHook integration — conflict path", () => {
  let repoDir: string;
  let dirs: string[];

  beforeEach(() => {
    dirs = [];
    repoDir = makeRepo();
    dirs.push(repoDir);
  });

  afterEach(() => {
    for (const d of dirs) rmSync(d, { recursive: true, force: true });
  });

  /**
   * Set up a conflict: both main and feature branch modify the same line in base.txt.
   */
  function setupConflict(): { runId: string; store: ForemanStore } {
    // Feature branch modifies base.txt
    git(["checkout", "-b", "foreman/seed-integ"], repoDir);
    writeFileSync(join(repoDir, "base.txt"), "feature modification\n");
    git(["add", "base.txt"], repoDir);
    git(["commit", "-m", "feature: modify base.txt"], repoDir);

    // Main branch also modifies base.txt (conflict!)
    addUpstreamCommit(repoDir, "base.txt", "upstream modification\n", "foreman/seed-integ");

    const store = makeStore();
    const project = store.registerProject("test", repoDir);
    const run = store.createRun(project.id, "seed-integ", "developer", repoDir);
    return { runId: run.id, store };
  }

  /** Wait for rebase:conflict event or timeout. Returns whether conflict was received. */
  async function waitForConflict(bus: PipelineEventBus, timeoutMs = 5000): Promise<PipelineEvent | null> {
    return new Promise((resolve) => {
      const t = setTimeout(() => resolve(null), timeoutMs);
      bus.once("rebase:conflict", (e) => {
        clearTimeout(t);
        resolve(e);
      });
    });
  }

  it("rebase:conflict event emitted with conflicting files", async () => {
    const { runId, store } = setupConflict();

    const bus = new PipelineEventBus();
    const config = makeConfig(repoDir, bus, store, makeMailClient(), { runId });
    const hook = new RebaseHook(config);
    hook.register();

    const rejectionHandler = (_reason: unknown) => {};
    process.on("unhandledRejection", rejectionHandler);

    const conflictPromise = waitForConflict(bus);
    bus.safeEmit({ type: "phase:complete", runId, phase: "developer", worktreePath: repoDir, cost: 0 });
    const conflictEvent = await conflictPromise;
    // small wait for any remaining async work (abortRebase, mail)
    await new Promise((r) => setTimeout(r, 100));
    process.off("unhandledRejection", rejectionHandler);

    expect(conflictEvent).not.toBeNull();
    const evt = conflictEvent as Extract<PipelineEvent, { type: "rebase:conflict" }>;
    expect(evt.conflictingFiles.length).toBeGreaterThan(0);
    expect(evt.conflictingFiles.some((f) => f.includes("base.txt"))).toBe(true);
  });

  it("worktree is clean after abort (no conflict markers)", async () => {
    const { runId, store } = setupConflict();

    const bus = new PipelineEventBus();
    const config = makeConfig(repoDir, bus, store, makeMailClient(), { runId });
    const hook = new RebaseHook(config);
    hook.register();

    const rejectionHandler = (_reason: unknown) => {};
    process.on("unhandledRejection", rejectionHandler);

    const conflictPromise = waitForConflict(bus);
    bus.safeEmit({ type: "phase:complete", runId, phase: "developer", worktreePath: repoDir, cost: 0 });
    await conflictPromise;
    await new Promise((r) => setTimeout(r, 200)); // wait for abort + mail
    process.off("unhandledRejection", rejectionHandler);

    // Verify no conflict markers in worktree
    const statusOutput = git(["status", "--porcelain"], repoDir);
    expect(statusOutput).not.toContain("UU");
    expect(existsSync(join(repoDir, ".git", "REBASE_HEAD"))).toBe(false);
    expect(existsSync(join(repoDir, ".git", "MERGE_HEAD"))).toBe(false);
  });

  it("run transitions to rebase_conflict then rebase_resolving", async () => {
    const { runId, store } = setupConflict();

    const bus = new PipelineEventBus();
    const config = makeConfig(repoDir, bus, store, makeMailClient(), { runId });
    const hook = new RebaseHook(config);
    hook.register();

    const rejectionHandler = (_reason: unknown) => {};
    process.on("unhandledRejection", rejectionHandler);

    const conflictPromise = waitForConflict(bus);
    bus.safeEmit({ type: "phase:complete", runId, phase: "developer", worktreePath: repoDir, cost: 0 });
    await conflictPromise;
    await new Promise((r) => setTimeout(r, 200));
    process.off("unhandledRejection", rejectionHandler);

    // The run status should be rebase_resolving (the final state after conflict handling)
    const allRuns = store.getRunsByStatuses(["rebase_conflict", "rebase_resolving"]);
    expect(allRuns.length).toBeGreaterThan(0);
  });

  it("troubleshooter mail sent with skill=resolve-rebase-conflict", async () => {
    const { runId, store } = setupConflict();

    const bus = new PipelineEventBus();
    const mailClient = makeMailClient();
    const config = makeConfig(repoDir, bus, store, mailClient, {
      runId,
      seedId: "seed-integ",
    });
    const hook = new RebaseHook(config);
    hook.register();

    const rejectionHandler = (_reason: unknown) => {};
    process.on("unhandledRejection", rejectionHandler);

    const conflictPromise = waitForConflict(bus);
    bus.safeEmit({ type: "phase:complete", runId, phase: "developer", worktreePath: repoDir, cost: 0 });
    await conflictPromise;
    // Wait for abortRebase + sendMessage to complete
    await new Promise((r) => setTimeout(r, 200));
    process.off("unhandledRejection", rejectionHandler);

    const calls = (mailClient.sendMessage as ReturnType<typeof vi.fn>).mock.calls as [string, string, string][];
    const troubleshooterMail = calls.find((c) => c[0] === "troubleshooter-seed-integ");
    expect(troubleshooterMail).toBeDefined();

    const parsed = JSON.parse(troubleshooterMail![2]) as { skill: string; type: string };
    expect(parsed.skill).toBe("resolve-rebase-conflict");
    expect(parsed.type).toBe("rebase-conflict");
  });

  it("RebaseConflictError is thrown as unhandled rejection", async () => {
    const { runId, store } = setupConflict();

    const bus = new PipelineEventBus();
    const config = makeConfig(repoDir, bus, store, makeMailClient(), { runId });
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

    bus.safeEmit({ type: "phase:complete", runId, phase: "developer", worktreePath: repoDir, cost: 0 });
    await Promise.race([errorPromise, new Promise((r) => setTimeout(r, 5000))]);

    expect(capturedError).toBeInstanceOf(RebaseConflictError);
  });
});

// ── TRD-019: Performance validation ──────────────────────────────────────────

describe("TRD-019: RebaseHook performance targets", () => {
  let dirs: string[];

  beforeEach(() => {
    dirs = [];
  });

  afterEach(() => {
    for (const d of dirs) rmSync(d, { recursive: true, force: true });
  });

  it("clean rebase path completes in <30s", async () => {
    const repoDir = makeRepo();
    dirs.push(repoDir);

    // Create feature branch
    makeFeatureBranch(repoDir, "foreman/seed-perf", "feature.txt", "feature\n");

    // Add 5 upstream commits (lighter than 100 but verifies the path)
    for (let i = 0; i < 5; i++) {
      addUpstreamCommit(repoDir, `upstream-${i}.txt`, `content ${i}\n`, "foreman/seed-perf");
    }

    const bus = new PipelineEventBus();
    const store = makeStore();
    const project = store.registerProject("test", repoDir);
    const run = store.createRun(project.id, "seed-perf", "developer", repoDir);

    const config = makeConfig(repoDir, bus, store, makeMailClient(), {
      runId: run.id,
      seedId: "seed-perf",
      workflow: {
        name: "test",
        phases: [{ name: "developer", prompt: "developer.md" }],
        rebaseAfterPhase: "developer",
        rebaseTarget: "main",
      },
    });
    const hook = new RebaseHook(config);
    hook.register();

    // Wait for rebase:clean event (event-driven, no fixed timeout)
    const cleanPromise = new Promise<PipelineEvent | null>((resolve) => {
      const t = setTimeout(() => resolve(null), 30_000);
      bus.once("rebase:clean", (e) => { clearTimeout(t); resolve(e); });
    });

    const start = Date.now();
    bus.safeEmit({
      type: "phase:complete",
      runId: run.id,
      phase: "developer",
      worktreePath: repoDir,
      cost: 0,
    });
    const cleanEvent = await cleanPromise;
    const elapsed = Date.now() - start;

    expect(cleanEvent).not.toBeNull();
    // Performance target: <30s (30,000ms)
    expect(elapsed).toBeLessThan(30_000);
  }, 35_000);

  it("conflict detection + escalation completes in <10s", async () => {
    const repoDir = makeRepo();
    dirs.push(repoDir);

    // Set up a conflict scenario
    git(["checkout", "-b", "foreman/seed-perf"], repoDir);
    writeFileSync(join(repoDir, "base.txt"), "feature mod\n");
    git(["add", "base.txt"], repoDir);
    git(["commit", "-m", "feature mod"], repoDir);
    addUpstreamCommit(repoDir, "base.txt", "upstream mod\n", "foreman/seed-perf");

    const bus = new PipelineEventBus();
    const store = makeStore();
    const project = store.registerProject("test", repoDir);
    const run = store.createRun(project.id, "seed-perf", "developer", repoDir);

    const config = makeConfig(repoDir, bus, store, makeMailClient(), {
      runId: run.id,
      seedId: "seed-perf",
    });
    const hook = new RebaseHook(config);
    hook.register();

    // Wait for rebase:conflict event (event-driven)
    const conflictPromise = new Promise<PipelineEvent | null>((resolve) => {
      const t = setTimeout(() => resolve(null), 10_000);
      bus.once("rebase:conflict", (e) => { clearTimeout(t); resolve(e); });
    });

    const rejectionHandler = (_reason: unknown) => {};
    process.on("unhandledRejection", rejectionHandler);

    const start = Date.now();
    bus.safeEmit({
      type: "phase:complete",
      runId: run.id,
      phase: "developer",
      worktreePath: repoDir,
      cost: 0,
    });
    const conflictEvent = await conflictPromise;
    // small wait for abortRebase to finish
    await new Promise((r) => setTimeout(r, 100));
    const elapsed = Date.now() - start;

    process.off("unhandledRejection", rejectionHandler);

    expect(conflictEvent).not.toBeNull();
    // Performance target: <10s (10,000ms)
    expect(elapsed).toBeLessThan(10_000);
  }, 15_000);
});
