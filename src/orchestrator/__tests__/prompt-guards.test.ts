import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const DEVELOPER_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "developer.md");
const QA_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "qa.md");
const FINALIZE_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "finalize.md");

describe("developer prompt guardrails", () => {
  const prompt = readFileSync(DEVELOPER_PROMPT, "utf-8");

  it("warns against copying unrelated tests from the worktree", () => {
    expect(prompt).toContain("Do NOT copy tests from the worktree into the main codebase");
    expect(prompt).toContain("directly related to THIS task's requirements");
  });
});

describe("qa prompt validation", () => {
  const prompt = readFileSync(QA_PROMPT, "utf-8");

  it("requires npm test command output evidence", () => {
    expect(prompt).toContain("npm test -- --reporter=dot 2>&1");
    expect(prompt).toContain("Raw summary");
    expect(prompt).toContain("reports without real test evidence are invalid");
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
});
