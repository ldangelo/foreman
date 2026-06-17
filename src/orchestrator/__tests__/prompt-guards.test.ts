import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const EXPLORER_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "explorer.md");
const DEVELOPER_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "developer.md");
const QA_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "qa.md");
const FINALIZE_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "finalize.md");
const FINALIZE_BUG_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "finalize-bug.md");
const PR_REVIEW_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "pr-review.md");
const FIX_BUG_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "bug", "fix-issue.md");
const FIX_TASK_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "task", "fix-issue.md");
const FIX_CHORE_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "chore", "fix-issue.md");

describe("explorer prompt narrowing", () => {
  const prompt = readFileSync(EXPLORER_PROMPT, "utf-8");

  it("pushes localized tasks toward a small-file search first", () => {
    expect(prompt).toContain("narrow/localized");
    expect(prompt).toContain("1\u20133 likely files");
    expect(prompt).toContain("Stop early once you can name the likely edit files");
  });
});

describe("developer prompt guardrails", () => {
  const prompt = readFileSync(DEVELOPER_PROMPT, "utf-8");

  it("warns against copying unrelated tests from the worktree", () => {
    expect(prompt).toContain("Do NOT copy tests from the worktree into the main codebase");
    expect(prompt).toContain("directly related to THIS task's requirements");
  });

  it("requires merge-conflict feedback to be resolved before normal implementation", () => {
    expect(prompt).toContain("Mergeable: CONFLICTING");
    expect(prompt).toContain("git rebase origin/{{baseBranch}}");
    expect(prompt).toContain('Do **not** decide \u201cthe task is already implemented\u201d');
    expect(prompt).toContain("GIT_EDITOR=true git rebase --continue");
    expect(prompt).toContain("detached workers do not hang in an editor");
  });

  it("biases localized tasks toward the smallest diff", () => {
    expect(prompt).toContain("smallest viable diff");
    expect(prompt).toContain("fewest relevant files");
  });

  it("instructs developer to write validation ledger after targeted verification", () => {
    expect(prompt).toContain("Validation Ledger");
    expect(prompt).toContain("VALIDATION_LEDGER.md");
    expect(prompt).toContain("mkdir -p \"{{reportDir}}\"");
    expect(prompt).toContain("targeted");
  });
});

describe("qa prompt validation", () => {
  const prompt = readFileSync(QA_PROMPT, "utf-8");

  it("requires real command output evidence", () => {
    expect(prompt).toContain("Command(s) run");
    expect(prompt).toContain("npm test -- --reporter=dot 2>&1");
    expect(prompt).toContain("Test scope:");
    expect(prompt).toContain("reports without real test evidence are invalid");
  });

  it("tells QA to prefer targeted verification first", () => {
    expect(prompt).toContain("Choose the narrowest verification");
    expect(prompt).toContain("Prefer targeted verification first for narrow tasks");
  });

  it("requires justification for full suite runs", () => {
    expect(prompt).toContain("Test Scope Justification");
    expect(prompt).toContain("Full suite (requires explicit justification)");
    expect(prompt).toContain("Full suite runs require explicit justification");
  });

  it("includes validation ledger guidance", () => {
    expect(prompt).toContain("VALIDATION_LEDGER.md");
    expect(prompt).toContain("validation ledger");
  });
});

describe("finalize prompt failure handling", () => {
  const prompt = readFileSync(FINALIZE_PROMPT, "utf-8");

  it("classifies finalize failures by scope", () => {
    expect(prompt).toContain("Failure Scope");
    expect(prompt).toContain("MODIFIED_FILES");
    expect(prompt).toContain("UNRELATED_FILES");
  });

  it("marks unrelated pre-existing failures as failed without retry", () => {
    expect(prompt).toContain('"status":"failed"');
    expect(prompt).toContain("tests_failed_pre_existing_issues");
  });

  it("documents jj immutable fallback merge guidance", () => {
    expect(prompt).toContain("Jujutsu immutable commit protection");
    expect(prompt).toContain("git fetch origin && git merge --no-edit origin/{{baseBranch}}");
  });

  it("includes test execution policy statement", () => {
    expect(prompt).toContain("Test Execution Policy");
    expect(prompt).toContain("shouldRunFinalizeValidation");
  });

  it("enforces targeted-affected tests before full suite on drift", () => {
    expect(prompt).toContain("targeted-affected tests first");
    expect(prompt).toContain("prefer targeted-affected tests");
  });

  it("reads validation ledger before running tests", () => {
    expect(prompt).toContain("VALIDATION_LEDGER.md");
    expect(prompt).toContain("Read validation ledger");
  });
});

describe("finalize-bug prompt guardrails", () => {
  const prompt = readFileSync(FINALIZE_BUG_PROMPT, "utf-8");

  it("includes test execution policy statement", () => {
    expect(prompt).toContain("Test Execution Policy");
    expect(prompt).toContain("shouldRunFinalizeValidation");
  });

  it("skips target integration and tests when no drift", () => {
    expect(prompt).toContain("shouldRunFinalizeValidation");
    expect(prompt).toContain("do not run target integration");
    expect(prompt).toContain("Do not run `npm ci`");
  });

  it("reads validation ledger before running tests", () => {
    expect(prompt).toContain("VALIDATION_LEDGER.md");
    expect(prompt).toContain("Read validation ledger");
  });

  it("prefers targeted-affected tests before full suite on drift", () => {
    expect(prompt).toContain("targeted-affected tests first");
  });

  it("classifies failures by scope", () => {
    expect(prompt).toContain("Failure Scope");
    expect(prompt).toContain("MODIFIED_FILES");
    expect(prompt).toContain("UNRELATED_FILES");
  });
});

describe("pr-review prompt guardrails", () => {
  const prompt = readFileSync(PR_REVIEW_PROMPT, "utf-8");

  it("forbids local test execution", () => {
    expect(prompt).toContain("Test Execution Policy");
    expect(prompt).toContain("GitHub CI is the source of truth");
    expect(prompt).toContain("run local tests");
    expect(prompt).toContain("Forbidden Actions");
    expect(prompt).toContain("DO NOT run `npm test`");
  });

  it("specifies read-only triage behavior", () => {
    expect(prompt).toContain("Allowed git actions");
    expect(prompt).toContain("Read-only");
    expect(prompt).toContain("Do not fix files");
    expect(prompt).toContain("Do not commit");
    expect(prompt).toContain("Do not push");
  });
});

describe("fix-issue prompt guardrails", () => {
  const bugPrompt = readFileSync(FIX_BUG_PROMPT, "utf-8");
  const taskPrompt = readFileSync(FIX_TASK_PROMPT, "utf-8");
  const chorePrompt = readFileSync(FIX_CHORE_PROMPT, "utf-8");

  it("bug fix-issue instructs validation ledger writes after targeted verification", () => {
    expect(bugPrompt).toContain("Validation Ledger");
    expect(bugPrompt).toContain("VALIDATION_LEDGER.md");
    expect(bugPrompt).toContain("mkdir -p \"{{reportDir}}\"");
    expect(bugPrompt).toContain("fix");
  });

  it("task fix-issue instructs validation ledger writes after targeted verification", () => {
    expect(taskPrompt).toContain("Validation Ledger");
    expect(taskPrompt).toContain("VALIDATION_LEDGER.md");
    expect(taskPrompt).toContain("mkdir -p \"{{reportDir}}\"");
    expect(taskPrompt).toContain("fix");
  });

  it("chore fix-issue instructs validation ledger writes after targeted verification", () => {
    expect(chorePrompt).toContain("Validation Ledger");
    expect(chorePrompt).toContain("VALIDATION_LEDGER.md");
    expect(chorePrompt).toContain("mkdir -p \"{{reportDir}}\"");
    expect(chorePrompt).toContain("fix");
  });

  it("bug fix-issue runs targeted verification for bug path", () => {
    expect(bugPrompt).toContain("Run targeted verification for the bug path");
  });

  it("task fix-issue runs targeted verification for changed files", () => {
    expect(taskPrompt).toContain("Run targeted verification for the files or behavior you changed");
  });

  it("chore fix-issue references workflow test phase for broader suite", () => {
    expect(chorePrompt).toContain("workflow test phase");
    expect(chorePrompt).toContain("npm run test:unit");
  });
});
