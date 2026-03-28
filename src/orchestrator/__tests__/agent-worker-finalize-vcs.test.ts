/**
 * agent-worker-finalize-vcs.test.ts
 *
 * Verifies that the VCS backend abstraction migration (TRD-014) was applied
 * correctly to agent-worker.ts and agent-worker-finalize.ts.
 *
 * AC-T-014-1: agent-worker.ts correctly imports and uses VcsBackendFactory
 * AC-T-014-2: agent-worker-finalize.ts uses VcsBackend for all git operations
 * AC-T-014-3: finalize() correctly distinguishes retryable vs non-retryable failures
 *
 * These are structural/source-level tests that verify the wiring without
 * spawning real subprocesses or making API calls.
 */

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");
const FINALIZE_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker-finalize.ts");

// ── AC-T-014-1: agent-worker.ts VcsBackendFactory wiring ─────────────────────

describe("AC-T-014-1: agent-worker.ts — VcsBackendFactory import and usage", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("imports VcsBackendFactory from the VCS index module", () => {
    expect(source).toContain('VcsBackendFactory');
    expect(source).toContain('from "../lib/vcs/index.js"');
  });

  it("creates a VCS backend instance via VcsBackendFactory.fromEnv()", () => {
    expect(source).toContain("VcsBackendFactory.fromEnv(");
  });

  it("reads FOREMAN_VCS_BACKEND env var when constructing the backend", () => {
    expect(source).toContain("process.env.FOREMAN_VCS_BACKEND");
  });

  it("passes the vcsBackend to executePipeline via config spread", () => {
    // The vcs backend must be forwarded into the pipeline config so that
    // finalize can use it for VCS operations.
    const configIdx = source.indexOf("{ ...config, vcsBackend }");
    expect(configIdx).toBeGreaterThan(-1);
  });

  it("handles VCS backend init failure gracefully (non-fatal)", () => {
    // Failure to create the backend should not crash the worker — it falls
    // back to prompt defaults. Verify there is a try/catch wrapping the call.
    const initIdx = source.indexOf("VcsBackendFactory.fromEnv(");
    expect(initIdx).toBeGreaterThan(-1);
    // Check that a catch block exists near the init call
    const block = source.slice(initIdx - 50, initIdx + 400);
    expect(block).toContain("catch");
  });

  it("logs the VCS backend name after successful init", () => {
    expect(source).toContain("vcsBackend.name");
  });
});

// ── AC-T-014-2: agent-worker-finalize.ts VcsBackend method coverage ──────────

describe("AC-T-014-2: agent-worker-finalize.ts — VcsBackend method usage", () => {
  const source = readFileSync(FINALIZE_SRC, "utf-8");

  it("accepts a VcsBackend parameter (dependency injection)", () => {
    // finalize() signature must include vcs: VcsBackend
    expect(source).toContain("vcs: VcsBackend");
  });

  it("imports VcsBackend type from the VCS index module", () => {
    expect(source).toContain("VcsBackend");
    expect(source).toContain('from "../lib/vcs/index.js"');
  });

  it("uses vcs.stageAll() to stage changes", () => {
    expect(source).toContain("await vcs.stageAll(");
  });

  it("uses vcs.commit() to create the commit", () => {
    expect(source).toContain("await vcs.commit(");
  });

  it("uses vcs.getHeadId() to capture the commit hash", () => {
    expect(source).toContain("await vcs.getHeadId(");
  });

  it("uses vcs.getCurrentBranch() for branch verification", () => {
    expect(source).toContain("await vcs.getCurrentBranch(");
  });

  it("uses vcs.checkoutBranch() to recover from branch mismatch", () => {
    expect(source).toContain("await vcs.checkoutBranch(");
  });

  it("uses vcs.push() to push the branch to origin", () => {
    expect(source).toContain("await vcs.push(");
  });

  it("uses vcs.fetch() before attempting rebase", () => {
    expect(source).toContain("await vcs.fetch(");
  });

  it("uses vcs.rebase() for non-fast-forward recovery", () => {
    expect(source).toContain("await vcs.rebase(");
  });

  it("uses vcs.abortRebase() to clean up after rebase failure", () => {
    expect(source).toContain("await vcs.abortRebase(");
  });

  it("uses vcs.diff() to compute modified files list", () => {
    expect(source).toContain("await vcs.diff(");
  });

  it("does NOT use execFileSync for git operations (only tsc is permitted)", () => {
    // The only execFileSync call allowed is for `npx tsc --noEmit`.
    // All git operations must be delegated to the VcsBackend.
    const execMatches = [...source.matchAll(/execFileSync\s*\(/g)];
    // Find each execFileSync call and verify none are raw git calls
    for (const match of execMatches) {
      const callSite = source.slice(match.index ?? 0, (match.index ?? 0) + 200);
      // Allowed: tsc type check
      const isTsc = callSite.includes('"npx"') || callSite.includes("'npx'") ||
                    callSite.includes('"tsc"') || callSite.includes("'tsc'");
      expect(isTsc).toBe(true);
    }
  });

  it("constructs the commit message from seedTitle and seedId", () => {
    // Commit message should include both fields for traceability
    expect(source).toContain("seedTitle");
    expect(source).toContain("seedId");
    // The combined commit message pattern
    expect(source).toContain("`${seedTitle} (${seedId})`");
  });

  it("verifies the expected branch name follows the foreman/<seedId> convention", () => {
    expect(source).toContain("`foreman/${seedId}`");
  });
});

// ── AC-T-014-3: Retryable vs non-retryable failure distinction ────────────────

describe("AC-T-014-3: agent-worker-finalize.ts — retryable vs non-retryable failure logic", () => {
  const source = readFileSync(FINALIZE_SRC, "utf-8");

  it("declares pushRetryable flag defaulting to true (transient failures are retryable)", () => {
    expect(source).toContain("pushRetryable = true");
  });

  it("sets pushRetryable = false when rebase fails (deterministic/non-retryable)", () => {
    // A rebase conflict means the branch has diverged in an unresolvable way.
    // Retrying would loop forever, so retryable must be false.
    expect(source).toContain("pushRetryable = false");
  });

  it("returns { success: false, retryable: false } for rebase conflict path", () => {
    // Verify that after rebase failure, retryable=false is set.
    // The rebase failure branch contains this comment about preventing infinite loop.
    const markerText = "Deterministic failure — do NOT reset seed to open (prevents infinite loop)";
    const markerIdx = source.indexOf(markerText);
    expect(markerIdx).toBeGreaterThan(-1);
    // pushRetryable = false must appear within the deterministic failure block
    const afterMarker = source.slice(markerIdx, markerIdx + 200);
    expect(afterMarker).toContain("pushRetryable = false");
  });

  it("detects non-fast-forward rejection by message content", () => {
    // Two common phrasings that must both trigger rebase recovery
    expect(source).toContain('"non-fast-forward"');
    expect(source).toContain('"fetch first"');
  });

  it("sets pushSucceeded = true only on successful push", () => {
    // This flag controls whether the bead is enqueued for merge
    expect(source).toContain("pushSucceeded = true");
  });

  it("keeps pushRetryable = true for non-classification push failures", () => {
    // Network errors, permission errors, etc. are treated as transient
    const nonFfIdx = source.indexOf("// Non-classification failures");
    expect(nonFfIdx).toBeGreaterThan(-1);
    const block = source.slice(nonFfIdx, nonFfIdx + 200);
    expect(block).toContain("pushRetryable = true");
  });

  it("returns FinalizeResult with success and retryable fields", () => {
    expect(source).toContain("return { success: pushSucceeded, retryable: pushRetryable }");
  });

  it("enqueues to merge queue BEFORE push attempt (pre-push enqueue pattern)", () => {
    // Pre-push enqueue ensures the queue entry exists even if agent crashes
    // after push but before normal enqueue. Enqueue must precede push call.
    const enqueueIdx = source.indexOf("enqueueToMergeQueue(");
    const pushIdx = source.indexOf("await vcs.push(");
    expect(enqueueIdx).toBeGreaterThan(-1);
    expect(pushIdx).toBeGreaterThan(-1);
    // Enqueue appears before the push attempt
    expect(enqueueIdx).toBeLessThan(pushIdx);
  });

  it("only updates bead status to review when push succeeds", () => {
    // Bead status update should be gated on pushSucceeded
    const statusUpdateIdx = source.indexOf('enqueueSetBeadStatus(statusStore, seedId, "review"');
    expect(statusUpdateIdx).toBeGreaterThan(-1);
    // The pushSucceeded guard must appear before the status update
    const pushSucceededGuardIdx = source.indexOf("if (pushSucceeded)");
    expect(pushSucceededGuardIdx).toBeGreaterThan(-1);
    expect(pushSucceededGuardIdx).toBeLessThan(statusUpdateIdx);
  });

  it("calls abortRebase() when rebase fails to clean up working tree", () => {
    // Must abort to avoid leaving worktree in a broken rebase state.
    // The rebase failure path contains a comment about this cleanup intent.
    const markerText = "Abort any partial rebase to leave the worktree clean";
    const markerIdx = source.indexOf(markerText);
    expect(markerIdx).toBeGreaterThan(-1);
    const afterMarker = source.slice(markerIdx, markerIdx + 200);
    expect(afterMarker).toContain("vcs.abortRebase(");
  });

  it("handles rebase exceptions by catching and setting deterministic failure", () => {
    // An exception during rebase is also treated as deterministic (non-retryable).
    // The rebase error catch block shares the same "Abort any partial rebase" comment.
    // Verify pushRetryable = false appears in multiple places (both rebase-fail paths).
    const allOccurrences = [...source.matchAll(/pushRetryable = false/g)];
    // Should appear at least twice: once for rebaseResult.success=false, once for catch
    expect(allOccurrences.length).toBeGreaterThanOrEqual(2);
  });
});

// ── Module structure invariants ───────────────────────────────────────────────

describe("agent-worker-finalize.ts — module structure", () => {
  const source = readFileSync(FINALIZE_SRC, "utf-8");

  it("exports the finalize() function", () => {
    expect(source).toContain("export async function finalize(");
  });

  it("exports the FinalizeConfig interface", () => {
    expect(source).toContain("export interface FinalizeConfig");
  });

  it("exports the FinalizeResult interface", () => {
    expect(source).toContain("export interface FinalizeResult");
  });

  it("exports the rotateReport() utility function", () => {
    expect(source).toContain("export function rotateReport(");
  });

  it("finalize() accepts config, logFile, and vcs parameters in that order", () => {
    const sig = source.match(/export async function finalize\(([^)]+)\)/)?.[1] ?? "";
    expect(sig).toContain("config");
    expect(sig).toContain("logFile");
    expect(sig).toContain("vcs");
    // Verify ordering
    const configPos = sig.indexOf("config");
    const logFilePos = sig.indexOf("logFile");
    const vcsPos = sig.indexOf("vcs");
    expect(configPos).toBeLessThan(logFilePos);
    expect(logFilePos).toBeLessThan(vcsPos);
  });
});
