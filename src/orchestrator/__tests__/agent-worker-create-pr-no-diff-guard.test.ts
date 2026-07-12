/**
 * agent-worker-create-pr-no-diff-guard.test.ts
 *
 * Verifies that agent-worker.ts does NOT close tasks when there's no diff
 * against the base branch in the create-pr phase.
 *
 * Background: Previously, when a worktree drifted from main (e.g., was rebased
 * by another process), the create-pr phase would detect zero diff and close
 * the task directly. This bypasses PR review and can mask "branch drift" issues.
 *
 * Fix: Tasks should NOT be closed without a PR. Instead, PR creation is
 * skipped and the pipeline succeeds, but the task remains open for operator triage.
 */

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

describe("agent-worker.ts — no-diff guardrail: DO NOT close tasks without PR", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("checks for zero diff against base branch before PR creation", () => {
    expect(source).toContain("branchHasChanges");
    expect(source).toContain("hasChangesAgainstBase");
  });

  it("skips PR creation when there's no diff (no_changes_against_base)", () => {
    const idx = source.indexOf('reason: "no_changes_against_base"');
    expect(idx).toBeGreaterThan(-1);
    // Verify the context shows skipped: true
    const block = source.slice(Math.max(0, idx - 200), idx + 200);
    expect(block).toContain('skipped: true');
  });

  it("DOES NOT call runtimeTaskClient.close when there's no diff", () => {
    // Find the no_changes_against_base block
    const idx = source.indexOf('reason: "no_changes_against_base"');
    expect(idx).toBeGreaterThan(-1);
    // Extract the block that handles no_changes_against_base - need wider context
    const block = source.slice(Math.max(0, idx - 700), idx + 500);
    
    // The guardrail comment should be present
    expect(block).toContain("DO NOT close the task");
    expect(block).toContain("branch drift");
    
    // runtimeTaskClient.close should NOT be called in this block
    expect(block).not.toContain("runtimeTaskClient.close");
    expect(block).not.toContain("task close");
  });

  it("adds note to PR metadata explaining task was NOT closed", () => {
    const idx = source.indexOf('reason: "no_changes_against_base"');
    expect(idx).toBeGreaterThan(-1);
    const block = source.slice(Math.max(0, idx - 300), idx + 500);
    expect(block).toContain("Task NOT closed");
    expect(block).toContain("zero diff");
    expect(block).toContain("operator triage");
  });

  it("logs message indicating task remains open for triage", () => {
    const idx = source.indexOf('reason: "no_changes_against_base"');
    expect(idx).toBeGreaterThan(-1);
    const block = source.slice(Math.max(0, idx - 300), idx + 500);
    expect(block).toContain("skipping PR creation. Task remains open for operator triage");
  });

  it("still returns stopPipelineSuccess: true for successful skip", () => {
    const idx = source.indexOf('reason: "no_changes_against_base"');
    expect(idx).toBeGreaterThan(-1);
    // Need wider context to include the return statement
    const block = source.slice(Math.max(0, idx - 50), idx + 800);
    expect(block).toContain("stopPipelineSuccess: true");
  });

  it("sends phase-complete mail even when skipping PR", () => {
    const idx = source.indexOf('reason: "no_changes_against_base"');
    expect(idx).toBeGreaterThan(-1);
    const block = source.slice(Math.max(0, idx - 100), idx + 600);
    expect(block).toContain("sendMail");
    expect(block).toContain('"phase-complete"');
    expect(block).toContain('status: "skipped"');
  });
});

describe("agent-worker.ts — prior PR/metadata preserves PR creation path", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("proceeds to PR creation if priorPrUrl exists even with no diff", () => {
    // The condition is: if (!branchHasChanges && !priorPrUrl && !hasPriorPrMetadata)
    // So if priorPrUrl OR hasPriorPrMetadata exists, PR creation proceeds
    const idx = source.indexOf("!branchHasChanges && !priorPrUrl && !hasPriorPrMetadata");
    expect(idx).toBeGreaterThan(-1);
  });

  it("checks for prior PR metadata path", () => {
    expect(source).toContain("priorPrUrl");
    expect(source).toContain("hasPriorPrMetadata");
    expect(source).toContain("PR_METADATA.json");
  });
});
