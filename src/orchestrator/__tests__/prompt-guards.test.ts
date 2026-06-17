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

describe("explorer prompt narrowing", () => {
  const prompt = readFileSync(EXPLORER_PROMPT, "utf-8");

  it("pushes localized tasks toward a small-file search first", () => {
    expect(prompt).toContain("narrow/localized");
    expect(prompt).toContain("1–3 likely files");
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
    expect(prompt).toContain("Do **not** decide “the task is already implemented”");
    expect(prompt).toContain("GIT_EDITOR=true git rebase --continue");
    expect(prompt).toContain("detached workers do not hang in an editor");
  });

  it("biases localized tasks toward the smallest diff", () => {
    expect(prompt).toContain("smallest viable diff");
    expect(prompt).toContain("fewest relevant files");
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
