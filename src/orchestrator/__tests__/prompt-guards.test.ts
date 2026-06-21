import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const EXPLORER_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "explorer.md");
const DEVELOPER_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "developer.md");
const QA_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "qa.md");
const FINALIZE_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "finalize.md");

describe("explorer prompt narrowing", () => {
  const prompt = readFileSync(EXPLORER_PROMPT, "utf-8");

  it("pushes localized tasks toward a small-file search first", () => {
    expect(prompt).toContain("narrow/localized");
    expect(prompt).toContain("1–3 likely files");
    expect(prompt).toContain("Stop early once you can name the likely edit files");
  });

  it("requires an explicit acceptance contract handoff", () => {
    expect(prompt).toContain("## Acceptance Contract");
    expect(prompt).toContain("3–6 explicit, verifiable done criteria");
    expect(prompt).toContain("Carry the same acceptance contract through Developer, QA, review, and finalize phases");
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

  it("requires self-check evidence and artifact-backed file claims", () => {
    expect(prompt).toContain("## Required Self-Checks Before `DEVELOPER_REPORT.md`");
    expect(prompt).toContain("Run `git diff --name-only`");
    expect(prompt).toContain("Run `git diff --check`");
    expect(prompt).toContain("## Self-Check Evidence");
    expect(prompt).toContain("Do not claim files were created or edited unless");
  });

  it("keeps test execution out of Developer while allowing focused test edits", () => {
    expect(prompt).toContain("do not run tests during Developer");
    expect(prompt).toContain("Do not run tests; leave verification execution to QA/finalize");
    expect(prompt).toContain("**DO NOT** run the full test suite or targeted tests");
  });

  it("carries acceptance criteria through the developer report", () => {
    expect(prompt).toContain("## Acceptance Contract");
    expect(prompt).toContain("Validate your implementation against those criteria before reporting done");
    expect(prompt).toContain("Carry the same acceptance contract through to QA and finalize");
  });
});

describe("qa prompt validation", () => {
  const prompt = readFileSync(QA_PROMPT, "utf-8");

  it("requires real command output evidence", () => {
    expect(prompt).toContain("Targeted command(s) run");
    expect(prompt).toContain("npm test -- --reporter=dot 2>&1");
    expect(prompt).toContain("Raw summary");
    expect(prompt).toContain("reports without real test evidence are invalid");
  });

  it("tells QA to prefer targeted verification first", () => {
    expect(prompt).toContain("Choose the narrowest verification");
    expect(prompt).toContain("Prefer targeted verification first for narrow tasks");
  });

  it("includes environment readiness checks before running tests", () => {
    expect(prompt).toContain("Pre-flight: Environment Readiness Checks");
    expect(prompt).toContain("foreman doctor --json");
    expect(prompt).toContain("pg_isready");
    expect(prompt).toContain("backend_mode");
  });

  it("tells QA to write environment-blocked verdict when checks fail", () => {
    expect(prompt).toContain("environment-blocked");
    expect(prompt).toContain("Status: environment-blocked");
    expect(prompt).toContain("with evidence");
  });

  it("allows environment readiness check commands in overwatch", () => {
    expect(prompt).toContain("pg_isready");
    expect(prompt).toContain("curl");
    expect(prompt).toContain("foreman doctor");
  });

  it("preserves focused evidence requirements and full-suite guardrails", () => {
    expect(prompt).toContain("Choose the narrowest verification");
    expect(prompt).toContain("Do **not** run the full suite");
    expect(prompt).toContain("Command run:");
    expect(prompt).toContain("Test suite: X passed, Y failed");
    expect(prompt).toContain("reports without real test evidence are invalid");
  });

  it("validates against the acceptance contract", () => {
    expect(prompt).toContain("## Acceptance Contract");
    expect(prompt).toContain("Verify that the implementation satisfies those criteria before writing your report");
    expect(prompt).toContain("Carry the same acceptance contract through to review and finalize");
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

  it("only reruns broad validation when the target changed after QA", () => {
    expect(prompt).toContain("Finalize should rerun the full test suite only when the target branch moved after QA completed");
    expect(prompt).toContain("Should integrate target drift");
    expect(prompt).toContain("Do **not** rerun `npm test`");
    expect(prompt).toContain("QA already passed and the target branch did not move after QA");
  });

  it("requires final validation artifacts and acceptance confirmation", () => {
    expect(prompt).toContain("FINALIZE_VALIDATION.md");
    expect(prompt).toContain("## Verdict: PASS | FAIL");
    expect(prompt).toContain("## Acceptance Contract");
    expect(prompt).toContain("Confirm the implementation satisfies those criteria before finalizing");
  });
});
