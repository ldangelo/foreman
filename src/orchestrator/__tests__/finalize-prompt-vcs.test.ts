/**
 * Tests for finalize prompt VCS command templating (TRD-026).
 *
 * Verifies that:
 *   AC-T-026-1: {{vcsStageCommand}} is rendered in finalize.md
 *   AC-T-026-2: All vcs* variables are substituted correctly for GitBackend
 *   AC-T-026-3: All vcs* variables are substituted correctly for JujutsuBackend
 */

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { buildPhasePrompt } from "../roles.js";
import { GitBackend } from "../../lib/vcs/git-backend.js";
import { JujutsuBackend } from "../../lib/vcs/jujutsu-backend.js";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const DEFAULT_FINALIZE_MD = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "finalize.md");

// ── AC-T-026-1: Template variables are present in finalize.md raw template ──

describe("finalize.md template: VCS placeholder variables (AC-T-026-1)", () => {
  it("raw template contains {{vcsStageCommand}} placeholder", () => {
    const content = readFileSync(DEFAULT_FINALIZE_MD, "utf-8");
    expect(content).toContain("{{vcsStageCommand}}");
  });

  it("raw template contains {{vcsCommitCommand}} placeholder", () => {
    const content = readFileSync(DEFAULT_FINALIZE_MD, "utf-8");
    expect(content).toContain("{{vcsCommitCommand}}");
  });

  it("raw template contains {{vcsPushCommand}} placeholder", () => {
    const content = readFileSync(DEFAULT_FINALIZE_MD, "utf-8");
    expect(content).toContain("{{vcsPushCommand}}");
  });

  it("raw template contains {{vcsRebaseCommand}} placeholder", () => {
    const content = readFileSync(DEFAULT_FINALIZE_MD, "utf-8");
    expect(content).toContain("{{vcsRebaseCommand}}");
  });

  it("raw template contains {{vcsBranchVerifyCommand}} placeholder", () => {
    const content = readFileSync(DEFAULT_FINALIZE_MD, "utf-8");
    expect(content).toContain("{{vcsBranchVerifyCommand}}");
  });

  it("raw template contains {{vcsRestoreTrackedStateCommand}} placeholder", () => {
    const content = readFileSync(DEFAULT_FINALIZE_MD, "utf-8");
    expect(content).toContain("{{vcsRestoreTrackedStateCommand}}");
  });

  it("raw template does NOT contain hardcoded 'git add -A' stage command", () => {
    const content = readFileSync(DEFAULT_FINALIZE_MD, "utf-8");
    // The stage command should be templated, not hardcoded
    expect(content).not.toContain("git add -A");
  });

  it("raw template does NOT contain hardcoded 'git push -u origin' push command", () => {
    const content = readFileSync(DEFAULT_FINALIZE_MD, "utf-8");
    // The push command should be templated, not hardcoded
    expect(content).not.toContain("git push -u origin");
  });

  it("raw template does NOT contain hardcoded 'git fetch origin && git rebase origin/' rebase command", () => {
    const content = readFileSync(DEFAULT_FINALIZE_MD, "utf-8");
    // The rebase command should be templated, not hardcoded
    expect(content).not.toContain("git fetch origin && git rebase origin/");
  });
});

// ── AC-T-026-2: GitBackend commands render correctly ─────────────────────────

describe("buildPhasePrompt finalize: GitBackend VCS command substitution (AC-T-026-2)", () => {
  const gitBackend = new GitBackend("/tmp/test-project");
  const finalizeCommands = gitBackend.getFinalizeCommands({
    seedId: "bd-test",
    seedTitle: "Fix authentication",
    baseBranch: "dev",
    worktreePath: "/tmp/worktrees/bd-test",
  });

  it("renders git stage command in finalize prompt", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "Fix auth token refresh",
      runId: "run-123",
      worktreePath: "/tmp/worktrees/bd-test",
      baseBranch: "dev",
      ...finalizeCommands.stageCommand && { vcsStageCommand: finalizeCommands.stageCommand },
      vcsCommitCommand: finalizeCommands.commitCommand,
      vcsPushCommand: finalizeCommands.pushCommand,
      vcsRebaseCommand: finalizeCommands.rebaseCommand,
      vcsBranchVerifyCommand: finalizeCommands.branchVerifyCommand,
      vcsCleanCommand: finalizeCommands.cleanCommand,
      vcsRestoreTrackedStateCommand: finalizeCommands.restoreTrackedStateCommand,
    });
    expect(prompt).toContain("git add -A");
    expect(prompt).not.toContain("{{vcsStageCommand}}");
  });

  it("renders git tracked-state restore command in finalize prompt", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "desc",
      worktreePath: "/tmp/worktrees/bd-test",
      vcsStageCommand: finalizeCommands.stageCommand,
      vcsCommitCommand: finalizeCommands.commitCommand,
      vcsPushCommand: finalizeCommands.pushCommand,
      vcsRebaseCommand: finalizeCommands.rebaseCommand,
      vcsBranchVerifyCommand: finalizeCommands.branchVerifyCommand,
      vcsCleanCommand: finalizeCommands.cleanCommand,
      vcsRestoreTrackedStateCommand: finalizeCommands.restoreTrackedStateCommand,
    });
    expect(prompt).toContain("git restore --source=HEAD --staged --worktree -- .beads/issues.jsonl");
    expect(prompt).not.toContain("{{vcsRestoreTrackedStateCommand}}");
  });

  it("renders git commit command in finalize prompt", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "desc",
      vcsCommitCommand: finalizeCommands.commitCommand,
      vcsPushCommand: finalizeCommands.pushCommand,
      vcsRebaseCommand: finalizeCommands.rebaseCommand,
      vcsBranchVerifyCommand: finalizeCommands.branchVerifyCommand,
      vcsCleanCommand: finalizeCommands.cleanCommand,
    });
    expect(prompt).toContain("git commit -m 'Fix authentication (bd-test)'");
    expect(prompt).not.toContain("{{vcsCommitCommand}}");
  });

  it("renders git push command in finalize prompt", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "desc",
      vcsStageCommand: finalizeCommands.stageCommand,
      vcsCommitCommand: finalizeCommands.commitCommand,
      vcsPushCommand: finalizeCommands.pushCommand,
      vcsRebaseCommand: finalizeCommands.rebaseCommand,
      vcsBranchVerifyCommand: finalizeCommands.branchVerifyCommand,
      vcsCleanCommand: finalizeCommands.cleanCommand,
    });
    expect(prompt).toContain("git push -u origin foreman/bd-test");
    expect(prompt).not.toContain("{{vcsPushCommand}}");
  });

  it("renders git rebase command in finalize prompt", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "desc",
      baseBranch: "dev",
      vcsStageCommand: finalizeCommands.stageCommand,
      vcsCommitCommand: finalizeCommands.commitCommand,
      vcsPushCommand: finalizeCommands.pushCommand,
      vcsRebaseCommand: finalizeCommands.rebaseCommand,
      vcsBranchVerifyCommand: finalizeCommands.branchVerifyCommand,
      vcsCleanCommand: finalizeCommands.cleanCommand,
    });
    expect(prompt).toContain("git fetch origin && git rebase origin/dev");
    expect(prompt).not.toContain("{{vcsRebaseCommand}}");
  });

  it("renders git branch verify command in finalize prompt", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "desc",
      vcsStageCommand: finalizeCommands.stageCommand,
      vcsCommitCommand: finalizeCommands.commitCommand,
      vcsPushCommand: finalizeCommands.pushCommand,
      vcsRebaseCommand: finalizeCommands.rebaseCommand,
      vcsBranchVerifyCommand: finalizeCommands.branchVerifyCommand,
      vcsCleanCommand: finalizeCommands.cleanCommand,
    });
    expect(prompt).toContain("git rev-parse --abbrev-ref HEAD");
    expect(prompt).not.toContain("{{vcsBranchVerifyCommand}}");
  });

  it("does not leave any unresolved vcs* placeholders in git-rendered prompt", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "desc",
      runId: "run-1",
      worktreePath: "/tmp/worktrees/bd-test",
      baseBranch: "dev",
      vcsStageCommand: finalizeCommands.stageCommand,
      vcsCommitCommand: finalizeCommands.commitCommand,
      vcsPushCommand: finalizeCommands.pushCommand,
      vcsRebaseCommand: finalizeCommands.rebaseCommand,
      vcsBranchVerifyCommand: finalizeCommands.branchVerifyCommand,
      vcsCleanCommand: finalizeCommands.cleanCommand,
    });
    expect(prompt).not.toContain("{{vcsStageCommand}}");
    expect(prompt).not.toContain("{{vcsCommitCommand}}");
    expect(prompt).not.toContain("{{vcsPushCommand}}");
    expect(prompt).not.toContain("{{vcsRebaseCommand}}");
    expect(prompt).not.toContain("{{vcsBranchVerifyCommand}}");
    expect(prompt).not.toContain("{{vcsCleanCommand}}");
  });
});

// ── AC-T-026-3: JujutsuBackend commands render correctly ─────────────────────

describe("buildPhasePrompt finalize: JujutsuBackend VCS command substitution (AC-T-026-3)", () => {
  const jjBackend = new JujutsuBackend("/tmp/test-project");
  const finalizeCommands = jjBackend.getFinalizeCommands({
    seedId: "bd-test",
    seedTitle: "Fix authentication",
    baseBranch: "dev",
    worktreePath: "/tmp/worktrees/bd-test",
  });

  it("JujutsuBackend stageCommand is empty string (auto-staging)", () => {
    expect(finalizeCommands.stageCommand).toBe("");
  });

  it("renders jj commit command in finalize prompt", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "desc",
      vcsStageCommand: finalizeCommands.stageCommand,
      vcsCommitCommand: finalizeCommands.commitCommand,
      vcsPushCommand: finalizeCommands.pushCommand,
      vcsRebaseCommand: finalizeCommands.rebaseCommand,
      vcsBranchVerifyCommand: finalizeCommands.branchVerifyCommand,
      vcsCleanCommand: finalizeCommands.cleanCommand,
    });
    expect(prompt).toContain("jj describe -m 'Fix authentication (bd-test)'");
    expect(prompt).not.toContain("{{vcsCommitCommand}}");
  });

  it("renders jj push command in finalize prompt", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "desc",
      vcsStageCommand: finalizeCommands.stageCommand,
      vcsCommitCommand: finalizeCommands.commitCommand,
      vcsPushCommand: finalizeCommands.pushCommand,
      vcsRebaseCommand: finalizeCommands.rebaseCommand,
      vcsBranchVerifyCommand: finalizeCommands.branchVerifyCommand,
      vcsCleanCommand: finalizeCommands.cleanCommand,
    });
    expect(prompt).toContain("jj git push --bookmark foreman/bd-test --allow-new");
    expect(prompt).not.toContain("{{vcsPushCommand}}");
  });

  it("renders jj rebase command in finalize prompt", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "desc",
      baseBranch: "dev",
      vcsStageCommand: finalizeCommands.stageCommand,
      vcsCommitCommand: finalizeCommands.commitCommand,
      vcsPushCommand: finalizeCommands.pushCommand,
      vcsRebaseCommand: finalizeCommands.rebaseCommand,
      vcsBranchVerifyCommand: finalizeCommands.branchVerifyCommand,
      vcsCleanCommand: finalizeCommands.cleanCommand,
    });
    expect(prompt).toContain("jj git fetch && jj rebase -d");
    expect(prompt).not.toContain("{{vcsRebaseCommand}}");
  });

  it("renders jj branch verify command in finalize prompt", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "desc",
      vcsStageCommand: finalizeCommands.stageCommand,
      vcsCommitCommand: finalizeCommands.commitCommand,
      vcsPushCommand: finalizeCommands.pushCommand,
      vcsRebaseCommand: finalizeCommands.rebaseCommand,
      vcsBranchVerifyCommand: finalizeCommands.branchVerifyCommand,
      vcsCleanCommand: finalizeCommands.cleanCommand,
    });
    expect(prompt).toContain("jj bookmark list foreman/bd-test");
    expect(prompt).not.toContain("{{vcsBranchVerifyCommand}}");
  });

  it("does not leave any unresolved vcs* placeholders in jj-rendered prompt", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "desc",
      runId: "run-1",
      worktreePath: "/tmp/worktrees/bd-test",
      baseBranch: "dev",
      vcsStageCommand: finalizeCommands.stageCommand,
      vcsCommitCommand: finalizeCommands.commitCommand,
      vcsPushCommand: finalizeCommands.pushCommand,
      vcsRebaseCommand: finalizeCommands.rebaseCommand,
      vcsBranchVerifyCommand: finalizeCommands.branchVerifyCommand,
      vcsCleanCommand: finalizeCommands.cleanCommand,
    });
    expect(prompt).not.toContain("{{vcsStageCommand}}");
    expect(prompt).not.toContain("{{vcsCommitCommand}}");
    expect(prompt).not.toContain("{{vcsPushCommand}}");
    expect(prompt).not.toContain("{{vcsRebaseCommand}}");
    expect(prompt).not.toContain("{{vcsBranchVerifyCommand}}");
    expect(prompt).not.toContain("{{vcsCleanCommand}}");
  });

  it("empty jj stageCommand renders as empty (auto-staging context)", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-test",
      seedTitle: "Fix authentication",
      seedDescription: "desc",
      vcsStageCommand: finalizeCommands.stageCommand, // ""
      vcsCommitCommand: finalizeCommands.commitCommand,
      vcsPushCommand: finalizeCommands.pushCommand,
      vcsRebaseCommand: finalizeCommands.rebaseCommand,
      vcsBranchVerifyCommand: finalizeCommands.branchVerifyCommand,
      vcsCleanCommand: finalizeCommands.cleanCommand,
    });
    // Empty stageCommand means the template inserts an empty string — no "git add -A" in jj prompt
    expect(prompt).not.toContain("git add -A");
    // The prompt should still contain context about skipping if empty
    expect(prompt.toLowerCase()).toMatch(/skip|empty|auto.stag/i);
  });
});

// ── buildPhasePrompt defaults: git commands used when no VCS vars provided ───

describe("buildPhasePrompt finalize: default git commands when VCS vars omitted", () => {
  it("defaults to git add -A when vcsStageCommand not provided", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-def",
      seedTitle: "Default test",
      seedDescription: "desc",
    });
    expect(prompt).toContain("git add -A");
  });

  it("defaults to git commit when vcsCommitCommand not provided", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-def",
      seedTitle: "Default test",
      seedDescription: "desc",
    });
    expect(prompt).toContain("git commit");
  });

  it("defaults to git push when vcsPushCommand not provided", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-def",
      seedTitle: "Default test",
      seedDescription: "desc",
    });
    expect(prompt).toContain("git push");
  });

  it("defaults to git rebase when vcsRebaseCommand not provided", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-def",
      seedTitle: "Default test",
      seedDescription: "desc",
      baseBranch: "main",
    });
    expect(prompt).toContain("git fetch origin && git rebase origin/main");
  });

  it("does not leave unresolved placeholders with default git vars", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-def",
      seedTitle: "Default test",
      seedDescription: "desc",
      worktreePath: "/tmp/wt/bd-def",
      baseBranch: "main",
    });
    expect(prompt).not.toContain("{{vcsStageCommand}}");
    expect(prompt).not.toContain("{{vcsCommitCommand}}");
    expect(prompt).not.toContain("{{vcsPushCommand}}");
    expect(prompt).not.toContain("{{vcsRebaseCommand}}");
    expect(prompt).not.toContain("{{vcsBranchVerifyCommand}}");
    expect(prompt).not.toContain("{{vcsCleanCommand}}");
  });
});
