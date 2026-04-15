import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

describe("agent-worker finalize mail status handling", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("parses status from finalize phase-complete mail bodies", () => {
    expect(source).toContain('const status = typeof body["status"] === "string" ? body["status"] : "complete"');
  });

  it("treats finalize phase-complete success/completed values as success", () => {
    expect(source).toContain('finalizeSucceeded = status === "complete" || status === "completed" || status === "success"');
  });

  it("prefers non-retryable finalize agent errors over later phase-complete mail", () => {
    expect(source).toContain('const nonRetryableError = finalizeMsgs.find');
    expect(source).toContain('if (nonRetryableError)');
    expect(source).toContain('finalizeSucceeded = false;');
    expect(source).toContain('non-retryable agent-error mail received');
  });

  it("marks deterministic finalize failures as failed without retry", () => {
    expect(source).toContain('const terminalStatus = finalizeRetryable ? "stuck" : "failed"');
    expect(source).toContain('enqueueMarkBeadFailed(store, seedId, "agent-worker-finalize")');
  });

  it("does not assume finalize success when finalize mail is missing", () => {
    expect(source).toContain('No finalize mail found — preserving pipeline success=');
    expect(source).not.toContain('No finalize mail found — assuming success');
  });

  it("skips branch-ready when troubleshooter recovery already landed the branch on target", () => {
    expect(source).toContain('if (troubleshooterResolved)');
    expect(source).toContain('skipMergeQueue = true;');
    expect(source).toContain('Branch already matches ${completionTargetBranch} after troubleshooter recovery');
    expect(source).toContain('enqueueCloseSeed(store, seedId, "agent-worker-finalize")');
  });

  it("treats non-retryable pre-existing test failures as merged when the branch already landed", () => {
    expect(source).toContain('finalizeFailureReason === "tests_failed_pre_existing_issues"');
    expect(source).toContain('store.updateRun(runId, { status: "merged", completed_at: now });');
    expect(source).toContain('Pre-existing test failures but branch already matches ${completionTargetBranch}');
    expect(source).toContain('enqueueCloseSeed(store, seedId, "agent-worker-finalize")');
  });

  it("skips troubleshooter for non-retryable pre-existing finalize test failures", () => {
    expect(source).toContain('const shouldSkipTroubleshooter =');
    expect(source).toContain('finalizeFailureReason === "tests_failed_pre_existing_issues"');
    expect(source).toContain('Skipping for non-retryable pre-existing finalize test failures');
    expect(source).toContain('!!workflowConfig.onFailure && !shouldSkipTroubleshooter');
  });
});
