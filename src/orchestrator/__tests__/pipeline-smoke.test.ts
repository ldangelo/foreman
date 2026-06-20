/**
 * Smoke workflow: structural and configuration invariants (bd-vfn6)
 *
 * Validates that the smoke workflow infrastructure is correctly wired:
 *   - smoke/*.md prompt files exist and contain the right content
 *   - smoke.yaml workflow config is valid
 *   - agent-worker.ts has NO FOREMAN_SMOKE_TEST bypass (it was removed)
 *   - The smoke workflow runs through Pi (prompt-driven), not via TypeScript bypass
 *   - loadPrompt() resolves smoke prompts correctly
 *
 * The smoke workflow works by:
 *   1. Detecting seedType === "smoke" → resolvedWorkflow === "smoke"
 *   2. Loading smoke.yaml which references smoke/*.md prompts
 *   3. Each phase runs through Pi with the minimal smoke prompt
 *   4. Pi writes the report files and sends mail as instructed by the prompt
 *
 * No real Pi/API calls are made here. No subprocesses are spawned.
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import {
  mkdtempSync,
  rmSync,
  readFileSync,
  existsSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { installBundledPrompts } from "../../lib/prompt-loader.js";

// ── Constants ─────────────────────────────────────────────────────────────────

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");

// ── Smoke workflow: structural invariants ─────────────────────────────────────
// Verify the smoke infrastructure (prompts + workflow config) without spawning
// subprocesses or making API calls.

describe("default/finalize.md: worktree cwd fix", () => {
  const DEFAULT_FINALIZE = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "finalize.md");

  it("default/finalize.md contains {{worktreePath}} placeholder", () => {
    const content = readFileSync(DEFAULT_FINALIZE, "utf-8");
    expect(content).toContain("{{worktreePath}}");
  });

  it("default/finalize.md instructs agent to cd to worktree before git commands", () => {
    const content = readFileSync(DEFAULT_FINALIZE, "utf-8");
    // Must have an explicit cd instruction referencing the worktreePath placeholder
    expect(content).toContain("cd {{worktreePath}}");
  });

  it("default/finalize.md has a working directory verification step before Step 1", () => {
    const content = readFileSync(DEFAULT_FINALIZE, "utf-8");
    // Step 0 (or equivalent) must come before the stage command step
    // Stage command is now a VCS template variable (TRD-026)
    const cdPos = content.indexOf("cd {{worktreePath}}");
    const vcsStagePos = content.indexOf("{{vcsStageCommand}}");
    expect(cdPos).toBeGreaterThan(-1);
    expect(vcsStagePos).toBeGreaterThan(-1);
    expect(cdPos).toBeLessThan(vcsStagePos);
  });
});

describe("smoke workflow: structural invariants", () => {
  const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");
  const SMOKE_PROMPTS_DIR = join(PROJECT_ROOT, "src", "defaults", "prompts", "smoke");
  const SMOKE_WORKFLOW = join(PROJECT_ROOT, "src", "defaults", "workflows", "smoke.yaml");

  it("agent-worker.ts does NOT contain FOREMAN_SMOKE_TEST bypass (bypass was removed)", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    expect(source).not.toContain('FOREMAN_SMOKE_TEST === "true"');
    expect(source).not.toContain("SMOKE NOOP");
    expect(source).not.toContain("SMOKE TEST BYPASS");
  });

  it("agent-worker.ts uses the explicit phase-runner seam for phase execution (not a TypeScript bypass)", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    expect(source).toContain("runPhaseSession(");
  });

  it("smoke defaults directory contains all five phase prompt files", () => {
    expect(existsSync(join(SMOKE_PROMPTS_DIR, "explorer.md")), "smoke/explorer.md must exist").toBe(true);
    expect(existsSync(join(SMOKE_PROMPTS_DIR, "developer.md")), "smoke/developer.md must exist").toBe(true);
    expect(existsSync(join(SMOKE_PROMPTS_DIR, "qa.md")), "smoke/qa.md must exist").toBe(true);
    expect(existsSync(join(SMOKE_PROMPTS_DIR, "reviewer.md")), "smoke/reviewer.md must exist").toBe(true);
    expect(existsSync(join(SMOKE_PROMPTS_DIR, "finalize.md")), "smoke/finalize.md must exist").toBe(true);
  });

  it("smoke.yaml workflow config exists", () => {
    expect(existsSync(SMOKE_WORKFLOW), "smoke.yaml must exist").toBe(true);
  });

  it("smoke.yaml defines all five pipeline phases", () => {
    const content = readFileSync(SMOKE_WORKFLOW, "utf-8");
    expect(content).toContain("explorer");
    expect(content).toContain("developer");
    expect(content).toContain("qa");
    expect(content).toContain("reviewer");
    expect(content).toContain("finalize");
  });

  it("smoke/explorer.md instructs Pi to write EXPLORER_REPORT.md with PASS verdict", () => {
    const content = readFileSync(join(SMOKE_PROMPTS_DIR, "explorer.md"), "utf-8");
    expect(content).toContain("EXPLORER_REPORT.md");
    expect(content).toContain("PASS");
    expect(content).toContain("Smoke test noop");
  });

  it("smoke/developer.md instructs Pi to write DEVELOPER_REPORT.md", () => {
    const content = readFileSync(join(SMOKE_PROMPTS_DIR, "developer.md"), "utf-8");
    expect(content).toContain("DEVELOPER_REPORT.md");
    expect(content).toContain("Smoke test noop");
  });

  it("smoke/qa.md instructs Pi to write QA_REPORT.md with PASS verdict", () => {
    const content = readFileSync(join(SMOKE_PROMPTS_DIR, "qa.md"), "utf-8");
    expect(content).toContain("QA_REPORT.md");
    expect(content).toContain("PASS");
  });

  it("smoke/reviewer.md instructs Pi to write REVIEW.md with PASS verdict", () => {
    const content = readFileSync(join(SMOKE_PROMPTS_DIR, "reviewer.md"), "utf-8");
    expect(content).toContain("REVIEW.md");
    expect(content).toContain("PASS");
  });

  it("smoke/finalize.md instructs Pi to write FINALIZE_VALIDATION.md with PASS verdict and run commit (not git push)", () => {
    const content = readFileSync(join(SMOKE_PROMPTS_DIR, "finalize.md"), "utf-8");
    expect(content).toContain("FINALIZE_VALIDATION.md");
    expect(content).toContain("## Verdict: PASS");
    // Commit command is now a VCS template variable (TRD-026)
    expect(content).toContain("{{vcsCommitCommand}}");
    // Must explicitly NOT push in smoke mode
    expect(content).toContain("git push");
    expect(content.toLowerCase()).toContain("do not run");
  });

  it("smoke/finalize.md contains worktreePath placeholder for cwd verification", () => {
    const content = readFileSync(join(SMOKE_PROMPTS_DIR, "finalize.md"), "utf-8");
    // Template must reference {{worktreePath}} so the agent can cd to the correct dir
    expect(content).toContain("{{worktreePath}}");
  });

  it("smoke workflow finalize phase has artifact/verdict/retry wiring", () => {
    const content = readFileSync(SMOKE_WORKFLOW, "utf-8");
    expect(content).toContain('artifact: "{task.projectReportsDir}/FINALIZE_VALIDATION.md"');
    expect(content).toContain("verdict: true");
    expect(content).toContain("retryWith: developer");
    expect(content).toContain("retryOnFail: 1");
    expect(content).toContain("onFail: developer");
  });

  it("smoke prompts include error reporting instructions (lifecycle mail handled by executor)", () => {
    const phases = ["explorer", "developer", "qa", "reviewer", "finalize"];
    for (const phase of phases) {
      const content = readFileSync(join(SMOKE_PROMPTS_DIR, `${phase}.md`), "utf-8");
      expect(content, `smoke/${phase}.md should reference agent-error`).toContain("agent-error");
      expect(content, `smoke/${phase}.md should reference send_mail tool`).toContain("send_mail");
    }
  });

  it("dispatcher.ts does NOT inject FOREMAN_SMOKE_TEST into env (no-op env var removed)", () => {
    const dispatcherSrc = readFileSync(
      join(PROJECT_ROOT, "src", "orchestrator", "dispatcher.ts"),
      "utf-8",
    );
    expect(dispatcherSrc).not.toContain("FOREMAN_SMOKE_TEST");
  });
});

// ── loadPrompt(): unified resolution chain ────────────────────────────────────

// ── auto-smoke phase: structural invariants ───────────────────────────────────

describe("auto-smoke phase: structural invariants", () => {
  const DEFAULT_WORKFLOW = join(PROJECT_ROOT, "src", "defaults", "workflows", "default.yaml");
  const TYPES_SRC = join(PROJECT_ROOT, "src", "orchestrator", "types.ts");
  const ROLES_SRC = join(PROJECT_ROOT, "src", "orchestrator", "roles.ts");
  const AUTO_SMOKE_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "auto-smoke.md");

  it("default.yaml defines auto-smoke phase between developer and qa", () => {
    const content = readFileSync(DEFAULT_WORKFLOW, "utf-8");
    // auto-smoke must be present
    expect(content).toContain("- name: auto-smoke");
    // Must be between developer and qa phases
    const devPos = content.indexOf("- name: developer");
    const smokePos = content.indexOf("- name: auto-smoke");
    const qaPos = content.indexOf("- name: qa");
    expect(devPos).toBeGreaterThan(-1);
    expect(smokePos).toBeGreaterThan(-1);
    expect(qaPos).toBeGreaterThan(-1);
    expect(smokePos).toBeGreaterThan(devPos);
    expect(smokePos).toBeLessThan(qaPos);
  });

  it("default.yaml auto-smoke phase has bash command with required checks", () => {
    const content = readFileSync(DEFAULT_WORKFLOW, "utf-8");
    // git diff --check
    expect(content).toContain("git diff --check");
    // conflict-marker scan
    expect(content).toContain("<<<<<<");
    expect(content).toContain("======");
    expect(content).toContain(">>>>>>");
    // DEVELOPER_REPORT.md existence
    expect(content).toContain("DEVELOPER_REPORT.md");
    // verdict artifact
    expect(content).toContain('artifact: "{task.projectReportsDir}/AUTO_SMOKE_REPORT.md"');
    expect(content).toContain("verdict: true");
    expect(content).toContain("retryWith: developer");
    expect(content).toContain("retryOnFail:");
  });

  it("default.yaml auto-smoke phase has timeout of 120 seconds", () => {
    const content = readFileSync(DEFAULT_WORKFLOW, "utf-8");
    const autoSmokeSection = content.substring(content.indexOf("- name: auto-smoke"), content.indexOf("- name: qa"));
    expect(autoSmokeSection).toContain("timeoutSecs: 120");
  });

  it("default.yaml auto-smoke phase has mail onStart/onComplete/onFail", () => {
    const content = readFileSync(DEFAULT_WORKFLOW, "utf-8");
    const autoSmokeSection = content.substring(content.indexOf("- name: auto-smoke"), content.indexOf("- name: qa"));
    expect(autoSmokeSection).toContain("onStart: true");
    expect(autoSmokeSection).toContain("onComplete: true");
    expect(autoSmokeSection).toContain("onFail: developer");
  });

  it('types.ts includes "auto-smoke" in AgentRole union', () => {
    const content = readFileSync(TYPES_SRC, "utf-8");
    expect(content).toMatch(/export type AgentRole = "lead" \| "explorer" \| "developer" \| "auto-smoke" \|/);
  });

  it("roles.ts includes auto-smoke in DEFAULT_MODELS", () => {
    const content = readFileSync(ROLES_SRC, "utf-8");
    expect(content).toContain('"auto-smoke": getDefaultModel()');
  });

  it("roles.ts buildRoleConfigs() includes auto-smoke entry", () => {
    const content = readFileSync(ROLES_SRC, "utf-8");
    // The entry must appear in buildRoleConfigs() output
    expect(content).toMatch(/"auto-smoke":\s*\{[^}]*role:\s*"auto-smoke"/);
  });

  it("roles.ts ROLE_CONFIGS fallback includes auto-smoke entry", () => {
    const content = readFileSync(ROLES_SRC, "utf-8");
    // The try/catch fallback must also have the entry
    expect(content).toMatch(/"auto-smoke":\s*\{[^}]*role:\s*"auto-smoke"[^}]*maxBudgetUsd:\s*0\.50/);
  });

  it("roles.ts auto-smoke config has correct constraints", () => {
    const content = readFileSync(ROLES_SRC, "utf-8");
    // Extract the auto-smoke config from buildRoleConfigs
    const configMatch = content.match(/"auto-smoke":\s*\{([^}]+)\}/);
    expect(configMatch).toBeTruthy();
    const configBlock = configMatch![1];
    expect(configBlock).toContain('permissionMode: "plan"');
    expect(configBlock).toContain('reportFile: "AUTO_SMOKE_REPORT.md"');
    expect(configBlock).toContain('allowedTools: ["Bash", "Glob", "Grep", "Read"]');
  });

  it("auto-smoke.md prompt template exists", () => {
    expect(existsSync(AUTO_SMOKE_PROMPT), "auto-smoke.md must exist in src/defaults/prompts/default/").toBe(true);
  });

  it("auto-smoke.md describes all five checks", () => {
    const content = readFileSync(AUTO_SMOKE_PROMPT, "utf-8");
    expect(content).toContain("git diff --check");
    expect(content.toLowerCase()).toContain("conflict");
    expect(content).toContain("DEVELOPER_REPORT.md");
    expect(content).toContain("typecheck");
    expect(content).toContain("CLI --help");
  });

  it("auto-smoke.md documents verdict PASS/FAIL and timeout", () => {
    const content = readFileSync(AUTO_SMOKE_PROMPT, "utf-8");
    expect(content).toContain("## Verdict");
    expect(content).toContain("120");
    expect(content).toContain("Retry with `developer`");
  });
});

// ── loadPrompt(): unified resolution chain ───────────────────────────────────

describe("loadPrompt(): unified resolution chain", () => {
  let tmpProject: string;

  beforeEach(() => {
    tmpProject = mkdtempSync(join(tmpdir(), "foreman-promptloader-test-"));
    process.env["FOREMAN_HOME"] = tmpProject;
    // Install bundled prompts so the loader can find them
    installBundledPrompts(tmpProject, true);
  });

  afterEach(() => {
    rmSync(tmpProject, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
  });

  it("loadPrompt resolves smoke explorer prompt when installed", async () => {
    const { loadPrompt } = await import("../../lib/prompt-loader.js");
    const result = loadPrompt("explorer", { seedId: "x", seedTitle: "y" }, "smoke", tmpProject);
    expect(typeof result).toBe("string");
    expect(result.length).toBeGreaterThan(0);
  });

  it("loadPrompt resolves default explorer prompt when installed", async () => {
    const { loadPrompt } = await import("../../lib/prompt-loader.js");
    const result = loadPrompt("explorer", { seedId: "x", seedTitle: "y" }, "default", tmpProject);
    expect(typeof result).toBe("string");
    expect(result).toContain("x"); // seedId interpolated
  });

  it("loadPrompt global override takes precedence over bundled installed", async () => {
    const { loadPrompt } = await import("../../lib/prompt-loader.js");
    // Write a custom override
    const overridePath = join(tmpProject, "prompts", "default", "explorer.md");
    const { writeFileSync, mkdirSync } = await import("node:fs");
    mkdirSync(join(tmpProject, "prompts", "default"), { recursive: true });
    writeFileSync(overridePath, "# Custom override: {{seedId}}");
    const result = loadPrompt("explorer", { seedId: "override-test" }, "default", tmpProject);
    expect(result).toBe("# Custom override: override-test");
  });

  it("loadPrompt throws PromptNotFoundError when prompt file is missing", async () => {
    const { loadPrompt, PromptNotFoundError } = await import("../../lib/prompt-loader.js");
    const emptyDir = mkdtempSync(join(tmpdir(), "foreman-empty-"));
    // Use a phase name that definitely won't exist anywhere (not in project, not in HOME).
    try {
      expect(() =>
        loadPrompt("nonexistent-phase-xyz-12345", { seedId: "x" }, "default", emptyDir),
      ).toThrow(PromptNotFoundError);
    } finally {
      rmSync(emptyDir, { recursive: true, force: true });
    }
  });

  it("loadPrompt error message suggests foreman init", async () => {
    const { loadPrompt } = await import("../../lib/prompt-loader.js");
    const emptyDir = mkdtempSync(join(tmpdir(), "foreman-empty2-"));
    try {
      expect(() =>
        loadPrompt("nonexistent-phase-abc-99999", { seedId: "x" }, "default", emptyDir),
      ).toThrow(/foreman init/);
    } finally {
      rmSync(emptyDir, { recursive: true, force: true });
    }
  });
});
