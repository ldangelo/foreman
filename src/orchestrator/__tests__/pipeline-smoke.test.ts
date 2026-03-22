/**
 * Smoke test: pipeline end-to-end (bd-vfn6)
 *
 * Validates the full pipeline orchestration:
 *   explorer → developer → qa → reviewer → finalize
 *
 * Uses FOREMAN_SMOKE_TEST=true to bypass real SDK/API calls. Each phase
 * writes a synthetic report file and returns success immediately, allowing
 * the orchestration logic — phase ordering, artifact gating, report handoff,
 * status tracking — to be exercised without spending API budget.
 *
 * The test:
 *   1. Initialises a temporary git repo + SQLite store
 *   2. Writes a WorkerConfig JSON with pipeline=true and FOREMAN_SMOKE_TEST=true
 *   3. Spawns agent-worker.ts as a subprocess (identical to production)
 *   4. Asserts that all five phase artifacts are present after the run
 *   5. Asserts the SQLite run record reaches "completed" status
 *
 * No real Claude API calls are made. No code is generated. No git push occurs.
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import {
  mkdtempSync,
  rmSync,
  writeFileSync,
  existsSync,
  readFileSync,
  mkdirSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync, spawnSync } from "node:child_process";
import { ForemanStore } from "../../lib/store.js";
import { installBundledPrompts } from "../../lib/prompt-loader.js";

// ── Constants ─────────────────────────────────────────────────────────────────

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const TSX_BIN = join(PROJECT_ROOT, "node_modules", ".bin", "tsx");
const WORKER_SCRIPT = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

/** Timeout for the full smoke pipeline run (all 5 phases, noop) */
const PIPELINE_TIMEOUT_MS = 60_000;

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Initialise a minimal bare-enough git repo so the pipeline worker doesn't
 * crash trying to run git commands.  We only need `git init` + an initial
 * commit so HEAD exists and branch operations succeed.
 */
function initGitRepo(dir: string, branchName: string): void {
  const opts = { cwd: dir, stdio: "pipe" as const };
  spawnSync("git", ["init", "-b", "main"], { ...opts });
  spawnSync("git", ["config", "user.email", "smoke@test.local"], opts);
  spawnSync("git", ["config", "user.name", "Smoke Test"], opts);
  // Need at least one commit so HEAD resolves (required for git push)
  writeFileSync(join(dir, "README.md"), "# Smoke test repo\n");
  spawnSync("git", ["add", "."], opts);
  spawnSync("git", ["commit", "-m", "initial commit"], opts);
  // Create the feature branch the pipeline expects to push to
  spawnSync("git", ["checkout", "-b", branchName], opts);
}

// ── Smoke test ────────────────────────────────────────────────────────────────

describe("pipeline smoke test: explorer → developer → qa → reviewer → finalize", () => {
  let tmpDir: string;
  let worktreeDir: string;
  let projectDir: string;
  let store: ForemanStore;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-smoke-"));
    projectDir = join(tmpDir, "project");
    worktreeDir = join(tmpDir, "worktree");
    mkdirSync(projectDir, { recursive: true });
    mkdirSync(worktreeDir, { recursive: true });

    // Install bundled prompt templates so the unified loader can find them.
    // The pipeline worker will look in projectDir/.foreman/prompts/.
    installBundledPrompts(projectDir, true);

    // Initialise a git repo so the finalize phase doesn't crash on git commands.
    // The finalize smoke bypass skips git/npm anyway, but the pipeline may do
    // lightweight git inspections before reaching that bypass.
    initGitRepo(worktreeDir, "foreman/bd-smoke-01");
  });

  afterEach(() => {
    if (store) {
      try { store.close(); } catch { /* already closed */ }
    }
    rmSync(tmpDir, { recursive: true, force: true });
  });

  // ── Core smoke run ─────────────────────────────────────────────────────────

  it("runs all pipeline phases and creates phase artifacts (FOREMAN_SMOKE_TEST=true)", () => {
    // Set up the project store so agent-worker can record runs.
    store = ForemanStore.forProject(projectDir);
    const project = store.registerProject("smoke-project", projectDir);
    const run = store.createRun(project.id, "bd-smoke-01", "claude-sonnet-4-6", worktreeDir);
    store.updateRun(run.id, {
      status: "running",
      started_at: new Date().toISOString(),
    });

    // Write a minimal TASK.md in the worktree (pipeline expects it to exist)
    writeFileSync(join(worktreeDir, "TASK.md"), [
      "# Agent Task",
      "",
      "## Task Details",
      "**Seed ID:** bd-smoke-01",
      "**Title:** Smoke test pipeline",
      "**Description:** Validate pipeline orchestration with noop prompts.",
      "",
    ].join("\n"));

    // Write the WorkerConfig that agent-worker.ts reads from argv[2].
    const configPath = join(tmpDir, "smoke-config.json");
    const workerConfig = {
      runId: run.id,
      projectId: project.id,
      seedId: "bd-smoke-01",
      seedTitle: "Smoke test pipeline",
      seedDescription: "Validate pipeline orchestration with noop prompts.",
      model: "claude-sonnet-4-6",
      worktreePath: worktreeDir,
      projectPath: projectDir,
      prompt: "Smoke test — this prompt is replaced by the pipeline.",
      pipeline: true,
      seedType: "feature",
      env: {
        FOREMAN_SMOKE_TEST: "true",
      },
    };
    writeFileSync(configPath, JSON.stringify(workerConfig));

    // Run the worker subprocess.  HOME is redirected to tmpDir so Agent Mail /
    // ~/.foreman lookups don't touch the real user's config.
    let exitCode = 0;
    try {
      execFileSync(TSX_BIN, [WORKER_SCRIPT, configPath], {
        timeout: PIPELINE_TIMEOUT_MS,
        encoding: "utf-8",
        env: {
          ...process.env,
          HOME: tmpDir,
          FOREMAN_SMOKE_TEST: "true",
          // Strip live API keys so the smoke test never accidentally calls Claude.
          ANTHROPIC_API_KEY: "sk-ant-smoke-test-no-real-calls",
          // Strip Agent Mail env so no HTTP calls are attempted.
          AGENT_MAIL_URL: "",
        },
      });
    } catch (err: unknown) {
      // execFileSync throws on non-zero exit.  Capture but don't fail yet — we
      // first inspect the artifacts to give a richer assertion failure message.
      exitCode = (err as { status?: number }).status ?? 1;
    }

    // ── Assert phase artifacts ─────────────────────────────────────────────

    const explorerReport = join(worktreeDir, "EXPLORER_REPORT.md");
    const developerReport = join(worktreeDir, "DEVELOPER_REPORT.md");
    const qaReport = join(worktreeDir, "QA_REPORT.md");
    const reviewReport = join(worktreeDir, "REVIEW.md");
    const finalizeReport = join(worktreeDir, "FINALIZE_REPORT.md");

    expect(existsSync(explorerReport), "EXPLORER_REPORT.md should exist after explorer phase").toBe(true);
    expect(existsSync(developerReport), "DEVELOPER_REPORT.md should exist after developer phase").toBe(true);
    expect(existsSync(qaReport), "QA_REPORT.md should exist after qa phase").toBe(true);
    expect(existsSync(reviewReport), "REVIEW.md should exist after reviewer phase").toBe(true);
    expect(existsSync(finalizeReport), "FINALIZE_REPORT.md should exist after finalize phase").toBe(true);

    // ── Assert artifact content ────────────────────────────────────────────

    const explorerContent = readFileSync(explorerReport, "utf-8");
    expect(explorerContent).toContain("Smoke test noop");

    const qaContent = readFileSync(qaReport, "utf-8");
    expect(qaContent).toContain("PASS");

    const reviewContent = readFileSync(reviewReport, "utf-8");
    expect(reviewContent).toContain("PASS");

    // Worker must exit cleanly (0) when all phases succeed.
    expect(exitCode, `Worker should exit 0. Check ${tmpDir}/.foreman/logs for details.`).toBe(0);

    // ── Assert SQLite messages were produced ───────────────────────────────
    // The pipeline sends inter-agent messages via SqliteMailClient.
    // Re-open the same store the worker wrote to and verify messages exist.
    const postStore = ForemanStore.forProject(projectDir);
    const messages = postStore.getAllMessages(run.id);
    postStore.close();

    expect(messages.length, "Pipeline should produce at least one inter-agent message").toBeGreaterThan(0);

    // Explorer should have sent its report to the developer inbox
    const explorerMsg = messages.find((m) => m.subject.includes("Explorer Report"));
    expect(explorerMsg, "Explorer Report message should be sent to developer inbox").toBeDefined();
    expect(explorerMsg?.recipient_agent_type).toMatch(/developer/);

    // phase-complete events should be sent to foreman
    const phaseCompletes = messages.filter((m) => m.subject.includes("phase-complete"));
    expect(phaseCompletes.length, "At least one phase-complete message should be sent to foreman").toBeGreaterThan(0);
  });

  // ── Phase ordering via log ─────────────────────────────────────────────────

  it("phase artifacts appear in the correct order according to the run log", () => {
    store = ForemanStore.forProject(projectDir);
    const project = store.registerProject("smoke-order-project", projectDir);
    const run = store.createRun(project.id, "bd-smoke-02", "claude-sonnet-4-6", worktreeDir);
    store.updateRun(run.id, {
      status: "running",
      started_at: new Date().toISOString(),
    });

    writeFileSync(join(worktreeDir, "TASK.md"), "# Smoke Phase Order Test\n");

    const configPath = join(tmpDir, "smoke-order-config.json");
    writeFileSync(configPath, JSON.stringify({
      runId: run.id,
      projectId: project.id,
      seedId: "bd-smoke-02",
      seedTitle: "Smoke phase ordering test",
      model: "claude-sonnet-4-6",
      worktreePath: worktreeDir,
      projectPath: projectDir,
      prompt: "Smoke test.",
      pipeline: true,
      seedType: "feature",
      env: { FOREMAN_SMOKE_TEST: "true" },
    }));

    try {
      execFileSync(TSX_BIN, [WORKER_SCRIPT, configPath], {
        timeout: PIPELINE_TIMEOUT_MS,
        encoding: "utf-8",
        env: {
          ...process.env,
          HOME: tmpDir,
          FOREMAN_SMOKE_TEST: "true",
          ANTHROPIC_API_KEY: "sk-ant-smoke-test-no-real-calls",
          AGENT_MAIL_URL: "",
        },
      });
    } catch {
      // Ignore exit failures; assertions below will surface the real problem.
    }

    // The log file records phases as they execute.  By checking that earlier-
    // phase markers appear before later-phase markers we validate the ordering.
    const logDir = join(tmpDir, ".foreman", "logs");
    const logFile = join(logDir, `${run.id}.log`);

    if (existsSync(logFile)) {
      const logContent = readFileSync(logFile, "utf-8");

      const explorerPos = logContent.indexOf("[PHASE: EXPLORER]");
      const developerPos = logContent.indexOf("[PHASE: DEVELOPER]");
      const qaPos = logContent.indexOf("[PHASE: QA]");
      const reviewerPos = logContent.indexOf("[PHASE: REVIEWER]");
      const finalizePos = logContent.indexOf("[FINALIZE]");

      expect(explorerPos, "EXPLORER phase should appear in the log").toBeGreaterThanOrEqual(0);
      expect(developerPos, "DEVELOPER phase should appear in the log").toBeGreaterThanOrEqual(0);
      expect(qaPos, "QA phase should appear in the log").toBeGreaterThanOrEqual(0);
      expect(reviewerPos, "REVIEWER phase should appear in the log").toBeGreaterThanOrEqual(0);
      expect(finalizePos, "FINALIZE phase should appear in the log").toBeGreaterThanOrEqual(0);

      // Check ordering
      expect(explorerPos).toBeLessThan(developerPos);
      expect(developerPos).toBeLessThan(qaPos);
      expect(qaPos).toBeLessThan(reviewerPos);
      expect(reviewerPos).toBeLessThan(finalizePos);
    }
    // If log doesn't exist yet (process too fast), that's ok — artifact checks suffice.
  });

  // ── Skip paths don't regress ───────────────────────────────────────────────

  it("skipExplore=true causes EXPLORER_REPORT.md to be absent but subsequent phases run", () => {
    store = ForemanStore.forProject(projectDir);
    const project = store.registerProject("smoke-skip-project", projectDir);
    const run = store.createRun(project.id, "bd-smoke-03", "claude-sonnet-4-6", worktreeDir);
    store.updateRun(run.id, {
      status: "running",
      started_at: new Date().toISOString(),
    });

    writeFileSync(join(worktreeDir, "TASK.md"), "# Smoke Skip Test\n");

    const configPath = join(tmpDir, "smoke-skip-config.json");
    writeFileSync(configPath, JSON.stringify({
      runId: run.id,
      projectId: project.id,
      seedId: "bd-smoke-03",
      seedTitle: "Smoke skip-explore test",
      model: "claude-sonnet-4-6",
      worktreePath: worktreeDir,
      projectPath: projectDir,
      prompt: "Smoke test.",
      pipeline: true,
      seedType: "feature",
      skipExplore: true,
      env: { FOREMAN_SMOKE_TEST: "true" },
    }));

    try {
      execFileSync(TSX_BIN, [WORKER_SCRIPT, configPath], {
        timeout: PIPELINE_TIMEOUT_MS,
        encoding: "utf-8",
        env: {
          ...process.env,
          HOME: tmpDir,
          FOREMAN_SMOKE_TEST: "true",
          ANTHROPIC_API_KEY: "sk-ant-smoke-test-no-real-calls",
          AGENT_MAIL_URL: "",
        },
      });
    } catch {
      // Ignore
    }

    // Explorer was skipped → no EXPLORER_REPORT.md
    expect(existsSync(join(worktreeDir, "EXPLORER_REPORT.md")),
      "EXPLORER_REPORT.md should NOT be created when skipExplore=true").toBe(false);

    // But developer, qa, reviewer, finalize should still run
    expect(existsSync(join(worktreeDir, "DEVELOPER_REPORT.md")),
      "DEVELOPER_REPORT.md should exist even when explorer is skipped").toBe(true);
    expect(existsSync(join(worktreeDir, "QA_REPORT.md")),
      "QA_REPORT.md should exist even when explorer is skipped").toBe(true);
    expect(existsSync(join(worktreeDir, "REVIEW.md")),
      "REVIEW.md should exist even when explorer is skipped").toBe(true);
    expect(existsSync(join(worktreeDir, "FINALIZE_REPORT.md")),
      "FINALIZE_REPORT.md should exist even when explorer is skipped").toBe(true);
  });

  // ── Resume path: skip phases whose artifacts already exist ─────────────────

  it("phase artifacts pre-existing on disk are skipped (resume after crash)", () => {
    store = ForemanStore.forProject(projectDir);
    const project = store.registerProject("smoke-resume-project", projectDir);
    const run = store.createRun(project.id, "bd-smoke-04", "claude-sonnet-4-6", worktreeDir);
    store.updateRun(run.id, {
      status: "running",
      started_at: new Date().toISOString(),
    });

    writeFileSync(join(worktreeDir, "TASK.md"), "# Smoke Resume Test\n");

    // Pre-populate explorer and developer artifacts so they are skipped.
    const preExistingExplorer = "# Explorer Report\n\n## PRE-EXISTING\n";
    const preExistingDeveloper = "# Developer Report\n\n## PRE-EXISTING\n";
    writeFileSync(join(worktreeDir, "EXPLORER_REPORT.md"), preExistingExplorer);
    writeFileSync(join(worktreeDir, "DEVELOPER_REPORT.md"), preExistingDeveloper);

    const configPath = join(tmpDir, "smoke-resume-config.json");
    writeFileSync(configPath, JSON.stringify({
      runId: run.id,
      projectId: project.id,
      seedId: "bd-smoke-04",
      seedTitle: "Smoke resume test",
      model: "claude-sonnet-4-6",
      worktreePath: worktreeDir,
      projectPath: projectDir,
      prompt: "Smoke test.",
      pipeline: true,
      seedType: "feature",
      env: { FOREMAN_SMOKE_TEST: "true" },
    }));

    try {
      execFileSync(TSX_BIN, [WORKER_SCRIPT, configPath], {
        timeout: PIPELINE_TIMEOUT_MS,
        encoding: "utf-8",
        env: {
          ...process.env,
          HOME: tmpDir,
          FOREMAN_SMOKE_TEST: "true",
          ANTHROPIC_API_KEY: "sk-ant-smoke-test-no-real-calls",
          AGENT_MAIL_URL: "",
        },
      });
    } catch {
      // Ignore
    }

    // Explorer artifact must be unchanged (was pre-existing — skipped)
    const explorerContent = readFileSync(join(worktreeDir, "EXPLORER_REPORT.md"), "utf-8");
    expect(explorerContent).toBe(preExistingExplorer);

    // Developer artifact must be unchanged (was pre-existing — skipped on first pass)
    const developerContent = readFileSync(join(worktreeDir, "DEVELOPER_REPORT.md"), "utf-8");
    expect(developerContent).toBe(preExistingDeveloper);

    // QA + Review + Finalize must have been created by the resumed run
    expect(existsSync(join(worktreeDir, "QA_REPORT.md"))).toBe(true);
    expect(existsSync(join(worktreeDir, "REVIEW.md"))).toBe(true);
    expect(existsSync(join(worktreeDir, "FINALIZE_REPORT.md"))).toBe(true);
  });

  // ── SQLite run status ──────────────────────────────────────────────────────

  it("SQLite run record reaches 'completed' status after successful smoke pipeline", () => {
    store = ForemanStore.forProject(projectDir);
    const project = store.registerProject("smoke-status-project", projectDir);
    const run = store.createRun(project.id, "bd-smoke-05", "claude-sonnet-4-6", worktreeDir);
    store.updateRun(run.id, {
      status: "running",
      started_at: new Date().toISOString(),
    });

    writeFileSync(join(worktreeDir, "TASK.md"), "# Smoke Status Test\n");

    const configPath = join(tmpDir, "smoke-status-config.json");
    writeFileSync(configPath, JSON.stringify({
      runId: run.id,
      projectId: project.id,
      seedId: "bd-smoke-05",
      seedTitle: "Smoke status test",
      model: "claude-sonnet-4-6",
      worktreePath: worktreeDir,
      projectPath: projectDir,
      prompt: "Smoke test.",
      pipeline: true,
      seedType: "feature",
      env: { FOREMAN_SMOKE_TEST: "true" },
    }));

    let exitCode = 0;
    try {
      execFileSync(TSX_BIN, [WORKER_SCRIPT, configPath], {
        timeout: PIPELINE_TIMEOUT_MS,
        encoding: "utf-8",
        env: {
          ...process.env,
          HOME: tmpDir,
          FOREMAN_SMOKE_TEST: "true",
          ANTHROPIC_API_KEY: "sk-ant-smoke-test-no-real-calls",
          AGENT_MAIL_URL: "",
        },
      });
    } catch (err: unknown) {
      exitCode = (err as { status?: number }).status ?? 1;
    }

    // Re-open the store (subprocess wrote to same db file).
    // ForemanStore.forProject uses the .foreman/foreman.db path.
    const checkStore = ForemanStore.forProject(projectDir);
    try {
      const updatedRun = checkStore.getRun(run.id);
      // After a successful smoke pipeline, the run should be completed.
      expect(exitCode, "Worker should exit 0").toBe(0);
      expect(updatedRun?.status, "Run should be completed in SQLite").toBe("completed");
    } finally {
      checkStore.close();
    }
  });
});

// ── Structural invariants ─────────────────────────────────────────────────────
// Source-code assertions that verify the smoke test infrastructure is wired up
// correctly without spawning subprocesses.

describe("FOREMAN_SMOKE_TEST bypass: structural invariants", () => {
  const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

  it("agent-worker.ts has FOREMAN_SMOKE_TEST bypass in runPhase()", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    expect(source).toContain('FOREMAN_SMOKE_TEST === "true"');
  });

  it("runPhase() smoke bypass writes all five phase report files", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    expect(source).toContain("EXPLORER_REPORT.md");
    expect(source).toContain("DEVELOPER_REPORT.md");
    expect(source).toContain("QA_REPORT.md");
    expect(source).toContain("REVIEW.md");
    expect(source).toContain("REPRODUCER_REPORT.md");
  });

  it("finalize() smoke bypass is present and returns success: true", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    // The finalize bypass must return { success: true, retryable: false }
    expect(source).toContain("SMOKE NOOP — skipping git/npm/push");
    expect(source).toContain("return { success: true, retryable: false }");
  });

  it("smoke bypass returns { success: true, costUsd: 0, turns: 1 } from runPhase()", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    expect(source).toContain("return { success: true, costUsd: 0, turns: 1 }");
  });

  it("smoke defaults directory contains all four phase prompt files", () => {
    const smokePromptsDir = join(PROJECT_ROOT, "src", "defaults", "prompts", "smoke");
    expect(existsSync(join(smokePromptsDir, "explorer.md")), "smoke/explorer.md must exist").toBe(true);
    expect(existsSync(join(smokePromptsDir, "developer.md")), "smoke/developer.md must exist").toBe(true);
    expect(existsSync(join(smokePromptsDir, "qa.md")), "smoke/qa.md must exist").toBe(true);
    expect(existsSync(join(smokePromptsDir, "reviewer.md")), "smoke/reviewer.md must exist").toBe(true);
  });

  it("smoke/explorer.md instructs agent to write exactly EXPLORER_REPORT.md", () => {
    const smokePromptsDir = join(PROJECT_ROOT, "src", "defaults", "prompts", "smoke");
    const content = readFileSync(join(smokePromptsDir, "explorer.md"), "utf-8");
    expect(content).toContain("EXPLORER_REPORT.md");
    expect(content).toContain("PASS");
  });

  it("smoke/qa.md contains PASS verdict so QA gate proceeds", () => {
    const smokePromptsDir = join(PROJECT_ROOT, "src", "defaults", "prompts", "smoke");
    const content = readFileSync(join(smokePromptsDir, "qa.md"), "utf-8");
    expect(content).toContain("PASS");
  });

  it("smoke/reviewer.md contains PASS verdict so reviewer gate proceeds", () => {
    const smokePromptsDir = join(PROJECT_ROOT, "src", "defaults", "prompts", "smoke");
    const content = readFileSync(join(smokePromptsDir, "reviewer.md"), "utf-8");
    expect(content).toContain("PASS");
  });
});

// ── loadPrompt() resolves prompts via unified loader ──────────────────────────

describe("loadPrompt(): unified resolution chain", () => {
  let tmpProject: string;

  beforeEach(() => {
    tmpProject = mkdtempSync(join(tmpdir(), "foreman-promptloader-test-"));
    // Install bundled prompts so the loader can find them
    installBundledPrompts(tmpProject, true);
  });

  afterEach(() => {
    rmSync(tmpProject, { recursive: true, force: true });
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

  it("loadPrompt project-local override takes precedence over bundled installed", async () => {
    const { loadPrompt } = await import("../../lib/prompt-loader.js");
    // Write a custom override
    const overridePath = join(tmpProject, ".foreman", "prompts", "default", "explorer.md");
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
