/**
 * agent-worker-branch-drift-guard.test.ts
 *
 * Verifies that agent-worker.ts and agent-worker-finalize.ts fail fast when
 * the worktree is on a branch other than foreman/<taskId>.
 *
 * Background: Workers can switch from the canonical foreman/<taskId> branch
 * to an ad-hoc branch (e.g. via `git checkout -b fix/foo`), commit real work
 * there, then checkpoint/create-pr/finalize still push and inspect the computed
 * canonical branch. This has caused completed tasks with no PR while the actual
 * work remains on a different local/parent branch.
 *
 * Fix: All mutating phases must verify the current branch equals foreman/<taskId>
 * before committing, pushing, or closing. Fail-fast with expected/actual/worktree.
 */

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");
const FINALIZE_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker-finalize.ts");

describe("agent-worker.ts — requireCanonicalBranch helper", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("defines requireCanonicalBranch function", () => {
    expect(source).toContain("async function requireCanonicalBranch(");
  });

  it("requireCanonicalBranch checks current branch equals foreman/<taskId>", () => {
    const idx = source.indexOf("async function requireCanonicalBranch(");
    expect(idx).toBeGreaterThan(-1);
    const block = source.slice(idx, idx + 600);
    expect(block).toContain("foreman/${taskId}");
    expect(block).toContain("getCurrentBranch");
    expect(block).toContain("valid: actual === expected");
  });

  it("returns structured result with valid, expected, actual fields", () => {
    const idx = source.indexOf("async function requireCanonicalBranch(");
    const block = source.slice(idx, idx + 600);
    expect(block).toContain("valid: boolean");
    expect(block).toContain("expected: string");
    expect(block).toContain("actual: string");
  });

  it("returns valid=true when vcsBackend is undefined", () => {
    const idx = source.indexOf("async function requireCanonicalBranch(");
    const block = source.slice(idx, idx + 600);
    expect(block).toContain("if (!vcsBackend) return { valid: true");
  });
});

describe("agent-worker.ts — create-pr branch drift guard", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("runCreatePrBuiltinPhase calls requireCanonicalBranch", () => {
    expect(source).toContain("requireCanonicalBranch");
    // Should be in runCreatePrBuiltinPhase context
    const idx = source.indexOf("async function runCreatePrBuiltinPhase(");
    expect(idx).toBeGreaterThan(-1);
    const fnBlock = source.slice(idx, idx + 5000);
    expect(fnBlock).toContain("requireCanonicalBranch");
  });

  it("fails with BRANCH DRIFT error when current branch != foreman/<taskId>", () => {
    const idx = source.indexOf("BRANCH DRIFT");
    expect(idx).toBeGreaterThan(-1);
    const block = source.slice(Math.max(0, idx - 300), idx + 300);
    expect(block).toContain("expected");
    expect(block).toContain("actual");
    expect(block).toContain("worktreePath");
  });

  it("returns success: false when branch drift detected in create-pr", () => {
    const idx = source.indexOf("BRANCH DRIFT");
    // The return statement with success: false is ~300 chars after "BRANCH DRIFT"
    const block = source.slice(Math.max(0, idx - 50), idx + 700);
    expect(block).toContain("success: false");
    expect(block).toContain("stopPipelineSuccess: false");
  });

  it("logs error message with expected/actual/worktreePath in create-pr", () => {
    const idx = source.indexOf("[CREATE-PR] BRANCH DRIFT");
    expect(idx).toBeGreaterThan(-1);
    const block = source.slice(Math.max(0, idx - 50), idx + 400);
    expect(block).toContain("expected");
    expect(block).toContain("actual");
    expect(block).toContain("worktreePath");
  });

  it("sends agent-error mail when branch drift detected", () => {
    const idx = source.indexOf("BRANCH DRIFT");
    const block = source.slice(Math.max(0, idx - 200), idx + 500);
    expect(block).toContain('"agent-error"');
    expect(block).toContain('"branch_drift"');
  });

  it("branch drift check comes BEFORE no-change close block", () => {
    const driftIdx = source.indexOf("BRANCH DRIFT");
    const noChangeIdx = source.indexOf('reason: "no_changes_against_base"');
    expect(driftIdx).toBeGreaterThan(-1);
    expect(noChangeIdx).toBeGreaterThan(-1);
    // The branch drift check must appear before the no-change block
    expect(driftIdx).toBeLessThan(noChangeIdx);
  });
});

describe("agent-worker.ts — checkpointPr branch drift guard", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("checkpointWorktreeAndEnsureDraftPrAfterPhase calls requireCanonicalBranch", () => {
    const idx = source.indexOf("async function checkpointWorktreeAndEnsureDraftPrAfterPhase(");
    expect(idx).toBeGreaterThan(-1);
    const fnBlock = source.slice(idx, idx + 6000);
    expect(fnBlock).toContain("requireCanonicalBranch");
  });

  it("skips checkpoint (returns early) when branch drift detected", () => {
    const idx = source.indexOf("async function checkpointWorktreeAndEnsureDraftPrAfterPhase(");
    const fnBlock = source.slice(idx, idx + 6000);
    const driftIdx = fnBlock.indexOf("BRANCH DRIFT");
    expect(driftIdx).toBeGreaterThan(-1);
    // Should return early after drift detection, not commit/push
    const block = fnBlock.slice(Math.max(0, driftIdx - 50), driftIdx + 500);
    expect(block).toContain("return;");
    expect(block).not.toContain("vcsBackend.commit"); // Should not reach commit
  });

  it("logs error with expected/actual/worktreePath in checkpointPr", () => {
    const idx = source.indexOf("async function checkpointWorktreeAndEnsureDraftPrAfterPhase(");
    const fnBlock = source.slice(idx, idx + 6000);
    const driftIdx = fnBlock.indexOf("[CHECKPOINT] BRANCH DRIFT");
    expect(driftIdx).toBeGreaterThan(-1);
    const block = fnBlock.slice(Math.max(0, driftIdx - 50), driftIdx + 400);
    expect(block).toContain("expected");
    expect(block).toContain("actual");
    expect(block).toContain("worktreePath");
  });

  it("does NOT auto-checkout in checkpointPr when branch drift detected", () => {
    const idx = source.indexOf("async function checkpointWorktreeAndEnsureDraftPrAfterPhase(");
    const fnBlock = source.slice(idx, idx + 6000);
    const driftIdx = fnBlock.indexOf("BRANCH DRIFT");
    const block = fnBlock.slice(Math.max(0, driftIdx - 100), driftIdx + 600);
    // Should NOT attempt checkoutBranch
    expect(block).not.toContain("checkoutBranch");
  });
});

describe("agent-worker-finalize.ts — finalize branch drift guard", () => {
  const source = readFileSync(FINALIZE_SRC, "utf-8");

  it("finalize() checks current branch equals foreman/<taskId>", () => {
    expect(source).toContain("foreman/${taskId}");
    expect(source).toContain("getCurrentBranch");
  });

  it("fails with BRANCH DRIFT error instead of auto-recovering", () => {
    const idx = source.indexOf("BRANCH DRIFT");
    expect(idx).toBeGreaterThan(-1);
    // FAIL-FAST appears in the report.push() section ~740 chars after "BRANCH DRIFT"
    const block = source.slice(Math.max(0, idx - 50), idx + 1000);
    expect(block).toContain("FAIL-FAST");
    expect(block).toContain("no auto-checkout");
  });

  it("logs error message with expected/actual/worktreePath", () => {
    const idx = source.indexOf("[FINALIZE] BRANCH DRIFT");
    expect(idx).toBeGreaterThan(-1);
    // Finalize uses currentBranch variable (not actual) and worktreePath
    const block = source.slice(Math.max(0, idx - 50), idx + 400);
    expect(block).toContain("expected");
    expect(block).toContain("currentBranch");
    expect(block).toContain("worktreePath");
  });

  it("sets branchVerified = false when drift detected (no auto-checkout)", () => {
    const idx = source.indexOf("BRANCH DRIFT");
    // branchVerified = false is ~967 chars after "BRANCH DRIFT" in the log
    const block = source.slice(Math.max(0, idx - 50), idx + 1200);
    expect(block).toContain("branchVerified = false");
    // Should NOT call checkoutBranch
    expect(block).not.toContain("checkoutBranch");
  });

  it("includes branch drift info in report output", () => {
    const idx = source.indexOf("BRANCH DRIFT");
    const block = source.slice(Math.max(0, idx - 100), idx + 600);
    expect(block).toContain("Status: FAILED (branch drift detected)");
    expect(block).toContain("no auto-checkout");
  });

  it("does NOT call checkoutBranch to recover from branch mismatch", () => {
    // In the BRANCH DRIFT block, there should be no checkoutBranch call
    const driftIdx = source.indexOf("BRANCH DRIFT");
    const block = source.slice(Math.max(0, driftIdx - 50), driftIdx + 800);
    expect(block).not.toContain("checkoutBranch");
    expect(block).not.toContain("RECOVERED");
  });
});

describe("agent-worker.ts — hasChangesAgainstBase cannot close task on drift", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("hasChangesAgainstBase exists for external use", () => {
    expect(source).toContain("async function hasChangesAgainstBase(");
  });

  it("branch drift check prevents no-change task closure", () => {
    // The branch drift check must come BEFORE the no-change close block.
    // hasChangesAgainstBase can be called before or after requireCanonicalBranch;
    // what matters is that the branch drift check prevents closing when drifted.
    const createPrIdx = source.indexOf("async function runCreatePrBuiltinPhase(");
    const fnBlock = source.slice(createPrIdx, createPrIdx + 8000);

    // Both checks should exist in the function
    expect(fnBlock).toContain("requireCanonicalBranch");
    expect(fnBlock).toContain("hasChangesAgainstBase");

    // The branch drift check returns early BEFORE the no-change close block
    const branchInvariantIdx = fnBlock.indexOf("requireCanonicalBranch");
    const noChangeIdx = fnBlock.indexOf('reason: "no_changes_against_base"');
    const successReturnIdx = fnBlock.indexOf("success: true, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, outputText: \"no_changes_against_base\"");

    expect(branchInvariantIdx).toBeGreaterThan(-1);
    expect(noChangeIdx).toBeGreaterThan(-1);
    expect(successReturnIdx).toBeGreaterThan(-1);

    // The branch drift check returns false before reaching the no-change success
    // The fail-fast return comes between branchInvariant and noChange
    const failFastIdx = fnBlock.indexOf("success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, outputText: msg");

    expect(failFastIdx).toBeGreaterThan(-1);
    expect(failFastIdx).toBeLessThan(noChangeIdx);
  });
});
