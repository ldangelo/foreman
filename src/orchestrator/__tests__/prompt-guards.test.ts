import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const EXPLORER_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "explorer.md");
const BUG_FIX_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "bug", "fix-issue.md");
const DEVELOPER_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "developer.md");
const CICD_DEVELOPER_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "cicd-developer.md");
const CR_DEVELOPER_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "cr-developer.md");
const QA_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "qa.md");
const FINALIZE_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "finalize.md");

describe("explorer prompt narrowing", () => {
  const prompt = readFileSync(EXPLORER_PROMPT, "utf-8");

  it("pushes localized tasks toward a small-file search first", () => {
    expect(prompt).toContain("1–3 most likely edit files");
    expect(prompt).toContain("Start narrow");
    expect(prompt).toContain("Stop after you can name likely edit files");
  });
});

describe("bug fix prompt guardrails", () => {
  const prompt = readFileSync(BUG_FIX_PROMPT, "utf-8");

  it("keeps fixes on the active task branch", () => {
    expect(prompt).toContain("Stay on the active task branch/worktree");
    expect(prompt).toContain("Do **not** create, check out, or switch to another branch");
    expect(prompt).toContain("branch management, commits, pushes, PRs, and task closure are owned by the pipeline");
  });
});

describe("developer prompt guardrails", () => {
  const prompt = readFileSync(DEVELOPER_PROMPT, "utf-8");

  it("warns against copying unrelated tests from the worktree", () => {
    expect(prompt).toContain("Do NOT copy tests from the worktree into the main codebase");
    expect(prompt).toContain("If tests appear necessary, document the gap for QA");
  });

  it("requires merge-conflict feedback to be resolved before normal implementation", () => {
    expect(prompt).toContain("Mergeable: CONFLICTING");
    expect(prompt).toContain("git rebase origin/{{baseBranch}}");
    expect(prompt).toContain("Do **not** decide “the task is already implemented”");
    expect(prompt).toContain("GIT_EDITOR=true git rebase --continue");
    expect(prompt).toContain("detached workers do not hang in an editor");
  });

  it("requires ci remediation to address failed checks", () => {
    expect(prompt).toContain("If your phase is `cicd-developer`");
    expect(prompt).toContain("Read `PR_WAIT_REPORT.md`");
    expect(prompt).toContain("## CI Findings Addressed");
    expect(prompt).toContain("same failed check remains unexplained");
  });

  it("keeps task implementation inside the active worktree", () => {
    expect(prompt).toContain("Run commands from the current worktree root");
    expect(prompt).toContain("Do not `cd` to the controller checkout");
    expect(prompt).toContain("target branch already contains the requested behavior");
    expect(prompt).toContain("{{reportDir}}/DEVELOPER_REPORT.md");
  });

  it("biases localized tasks toward the smallest diff", () => {
    expect(prompt).toContain("smallest viable diff");
    expect(prompt).toContain("fewest relevant files");
  });
});

describe("specialized remediation prompts", () => {
  const cicdPrompt = readFileSync(CICD_DEVELOPER_PROMPT, "utf-8");
  const crPrompt = readFileSync(CR_DEVELOPER_PROMPT, "utf-8");

  it("keeps ci remediation scoped to failed checks", () => {
    expect(cicdPrompt).toContain("CI/CD remediation developer");
    expect(cicdPrompt).toContain("PR_WAIT_REPORT.md");
    expect(cicdPrompt).toContain("Failed Checks Addressed");
    expect(cicdPrompt).toContain("same failed check remains unexplained");
    expect(cicdPrompt).toContain("rerun that exact test or package command first");
    expect(cicdPrompt).toContain("broader CI command at most once");
  });

  it("keeps ci remediation inside the active worktree", () => {
    expect(cicdPrompt).toContain("Run commands from the current worktree root");
    expect(cicdPrompt).toContain("Do not `cd` to the controller checkout");
    expect(cicdPrompt).toContain("failed check is already fixed on the target branch");
    expect(cicdPrompt).toContain("{{reportDir}}/DEVELOPER_REPORT.md");
  });

  it("keeps CodeRabbit remediation scoped to cited findings", () => {
    expect(crPrompt).toContain("CodeRabbit remediation developer");
    expect(crPrompt).toContain("PR_REVIEW_FINDINGS.md");
    expect(crPrompt).toContain("CodeRabbit Findings Addressed");
    expect(crPrompt).toContain("cited path first");
    expect(crPrompt).toContain("smallest observable acceptance check");
    expect(crPrompt).toContain("positive presence checks before ordering/position comparisons");
    expect(crPrompt).toContain("inspect the final diff against each cited finding");
  });

  it("keeps CodeRabbit remediation inside the active worktree", () => {
    expect(crPrompt).toContain("Run commands from the current worktree root");
    expect(crPrompt).toContain("Do not `cd` to the controller checkout");
    expect(crPrompt).toContain("blocking finding is already fixed on the target branch");
    expect(crPrompt).toContain("{{reportDir}}/DEVELOPER_REPORT.md");
  });
});

describe("qa prompt validation", () => {
  const prompt = readFileSync(QA_PROMPT, "utf-8");

  it("requires real command output evidence", () => {
    expect(prompt).toContain("Targeted command(s) run");
    expect(prompt).toContain("Raw summary");
    expect(prompt).toContain("without real test evidence are invalid");
  });

  it("tells QA to prefer targeted verification first", () => {
    expect(prompt).toContain("Choose the narrowest verification");
    expect(prompt).toContain("targeted verification");
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
