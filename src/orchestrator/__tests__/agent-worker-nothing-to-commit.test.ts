/**
 * agent-worker-nothing-to-commit.test.ts
 *
 * Verifies that agent-worker.ts correctly handles "nothing to commit" as
 * success for verification/test tasks (bd-w8sj).
 *
 * When a developer agent validates existing code without making changes,
 * finalize sends agent-error with error="nothing_to_commit". For tasks with
 * type="test" or titles matching /verify|validate|test/i, this should be
 * treated as success — not as a failure that resets the task to open.
 *
 * These are structural/source-level tests that verify the wiring without
 * spawning real subprocesses or making API calls.
 */

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");
const FINALIZE_PROMPT = join(
  PROJECT_ROOT,
  "src",
  "defaults",
  "prompts",
  "default",
  "finalize.md",
);

describe("agent-worker.ts — nothing_to_commit for verification tasks (bd-w8sj)", () => {
  const source = readFileSync(WORKER_SRC, "utf-8");

  it("checks for nothing_to_commit error in finalize outcome handling", () => {
    expect(source).toContain('errorDetail === "nothing_to_commit"');
  });

  it("reads taskType from config to determine if task is a verification task", () => {
    expect(source).toContain("config.taskType");
    expect(source).toContain('taskType === "test"');
  });

  it("reads taskTitle from config for title-based verification task detection", () => {
    expect(source).toContain("config.taskTitle");
    expect(source).toContain("taskTitle");
  });

  it("uses case-insensitive regex to check for verify/validate/test in title", () => {
    expect(source).toContain("/verify|validate|test/i");
  });

  it("sets finalizeSucceeded=true for verification tasks with nothing_to_commit", () => {
    // Find the nothing_to_commit block and verify finalizeSucceeded is set to true
    const idx = source.indexOf('errorDetail === "nothing_to_commit"');
    expect(idx).toBeGreaterThan(-1);
    const block = source.slice(idx, idx + 2500);
    expect(block).toContain("finalizeSucceeded = true");
  });

  it("logs a descriptive message when treating nothing_to_commit as success", () => {
    expect(source).toContain(
      "nothing_to_commit on verification task",
    );
  });

  it("treats nothing_to_commit as success when branch has prior commits (reused worktree)", () => {
    const idx = source.indexOf('errorDetail === "nothing_to_commit"');
    const block = source.slice(idx, idx + 2500);
    // hasCommitsAhead check must exist and trigger success
    expect(block).toContain("hasCommitsAhead");
    expect(block).toContain("reused worktree");
  });


  it("only treats nothing_to_commit as success for verification tasks when no prior commits", () => {
    const idx = source.indexOf('errorDetail === "nothing_to_commit"');
    const block = source.slice(idx, idx + 2200);
    // Both hasCommitsAhead and isVerificationTask paths must exist
    expect(block).toContain("hasCommitsAhead");
    expect(block).toContain("isVerificationTask");
    // hasCommitsAhead success path runs first (before verification task fallback)
    const hasCommitsSuccessIdx = block.indexOf("reused worktree");
    const verifSuccessIdx = block.indexOf("verification task");
    expect(hasCommitsSuccessIdx).toBeGreaterThan(-1);
    expect(verifSuccessIdx).toBeGreaterThan(-1);
    expect(hasCommitsSuccessIdx).toBeLessThan(verifSuccessIdx);
  });
});

describe("finalize.md — nothing_to_commit verification task logic (bd-w8sj)", () => {
  const prompt = readFileSync(FINALIZE_PROMPT, "utf-8");

  it("contains conditional logic for nothing to commit", () => {
    expect(prompt).toContain("nothing to commit");
  });

  it("instructs agent to send phase-complete (not agent-error) for verification tasks", () => {
    expect(prompt).toContain("phase-complete");
    expect(prompt).toContain("nothing_to_commit_verification_task");
  });

  it("checks taskType for test type", () => {
    expect(prompt).toContain("{{taskType}}");
    expect(prompt).toContain('"test"');
  });

  it("checks taskTitle for verify/validate/test keywords", () => {
    expect(prompt).toContain("{{taskTitle}}");
    expect(prompt).toContain("verify");
    expect(prompt).toContain("validate");
  });

  it("still sends agent-error for non-verification tasks with nothing to commit", () => {
    expect(prompt).toContain("nothing_to_commit");
    // Should have both: nothing_to_commit_verification_task (success) and nothing_to_commit (error)
    const successNote = prompt.indexOf("nothing_to_commit_verification_task");
    const errorNote = prompt.indexOf('"nothing_to_commit"');
    expect(successNote).toBeGreaterThan(-1);
    expect(errorNote).toBeGreaterThan(-1);
  });
});

// ── Unit-level logic tests ────────────────────────────────────────────────────
// Test the detection logic in isolation using the same predicates as the source.

describe("verification task detection logic", () => {
  // Mirrors the logic in agent-worker.ts onPipelineComplete
  function isVerificationTask(taskType: string, taskTitle: string): boolean {
    return taskType === "test" || /verify|validate|test/i.test(taskTitle);
  }

  it("matches taskType=test", () => {
    expect(isVerificationTask("test", "Some task")).toBe(true);
  });

  it("matches title containing 'verify' (case-insensitive)", () => {
    expect(isVerificationTask("feature", "Verify login works")).toBe(true);
    expect(isVerificationTask("feature", "VERIFY login works")).toBe(true);
  });

  it("matches title containing 'validate' (case-insensitive)", () => {
    expect(isVerificationTask("task", "Validate API responses")).toBe(true);
    expect(isVerificationTask("task", "VALIDATE API responses")).toBe(true);
  });

  it("matches title containing 'test' (case-insensitive)", () => {
    expect(isVerificationTask("feature", "Test the checkout flow")).toBe(true);
    expect(isVerificationTask("feature", "Run TEST suite for auth")).toBe(true);
  });

  it("does NOT match non-verification tasks", () => {
    expect(isVerificationTask("feature", "Add dark mode support")).toBe(false);
    expect(isVerificationTask("bug", "Fix memory leak in worker")).toBe(false);
    expect(isVerificationTask("task", "Implement OAuth2 login")).toBe(false);
  });

  it("handles empty taskType gracefully", () => {
    expect(isVerificationTask("", "Verify user registration")).toBe(true);
    expect(isVerificationTask("", "Add new feature")).toBe(false);
  });
});
