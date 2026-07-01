/**
 * Regression tests for reviewer FAIL → developer retry in the default workflow.
 *
 * Root cause (bd-wbmw): The project-local .foreman/workflows/default.yaml was
 * missing `verdict: true`, `retryWith: developer`, and `retryOnFail` on both
 * the reviewer and qa phases. Since the loader picks up the project-local file
 * before the bundled default, the retry config was silently absent — causing
 * reviewer FAIL to fall through directly to finalize instead of looping back
 * to developer.
 *
 * Verifies:
 *  1. The bundled default.yaml reviewer phase has verdict/retryWith/retryOnFail
 *  2. The bundled default.yaml qa phase has verdict/retryWith/retryOnFail
 *  3. The project-local .foreman/workflows/default.yaml (this repo) has the
 *     same critical fields — so it stays in sync with the bundled default
 *  4. executePipeline() with the ACTUAL loaded default workflow correctly loops
 *     reviewer FAIL back to developer
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  existsSync,
  mkdtempSync,
  rmSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { load as yamlLoad } from "js-yaml";

// ── Constants ─────────────────────────────────────────────────────────────────

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const BUNDLED_DEFAULT_YAML = join(
  PROJECT_ROOT,
  "src",
  "defaults",
  "workflows",
  "default.yaml",
);
const LOCAL_DEFAULT_YAML = join(
  PROJECT_ROOT,
  ".foreman",
  "workflows",
  "default.yaml",
);
const RESOLVED_LOCAL_DEFAULT_YAML = existsSync(LOCAL_DEFAULT_YAML)
  ? LOCAL_DEFAULT_YAML
  : BUNDLED_DEFAULT_YAML;

// ── Helpers ───────────────────────────────────────────────────────────────────

type PhaseMap = Record<
  string,
  {
    verdict?: boolean;
    retryWith?: string;
    retryOnFail?: number;
    artifact?: string;
  }
>;

function loadPhaseMap(yamlPath: string): PhaseMap {
  const raw = yamlLoad(readFileSync(yamlPath, "utf-8")) as {
    phases: Array<{ name: string; [k: string]: unknown }>;
  };
  const map: PhaseMap = {};
  for (const phase of raw.phases) {
    map[phase.name] = {
      verdict: phase["verdict"] as boolean | undefined,
      retryWith: phase["retryWith"] as string | undefined,
      retryOnFail: phase["retryOnFail"] as number | undefined,
      artifact: phase["artifact"] as string | undefined,
    };
  }
  return map;
}

function makePipelineArgs(
  tmpDir: string,
  workflowName: string,
  runPhase: ReturnType<typeof vi.fn>,
  runBuiltinPhase: ReturnType<typeof vi.fn>,
  log: ReturnType<typeof vi.fn>,
) {
  const mockStore = {
    updateRunProgress: vi.fn(),
    logEvent: vi.fn(),
  };
  return {
    config: {
      runId: "run-reviewer-retry-test",
      projectId: "proj-reviewer-retry",
      taskId: "task-reviewer-retry",
      taskTitle: "Reviewer retry regression test",
      model: "anthropic/claude-sonnet-4-6",
      worktreePath: tmpDir,
      env: {},
      taskMeta: {
        id: "task-reviewer-retry",
        title: "Reviewer retry regression test",
        description: "",
        type: "feature",
        priority: 2,
        projectReportsDir: ".foreman/reports/proj-reviewer-retry/task-reviewer-retry/run-reviewer-retry-test",
      },
    },
    workflowConfig: { name: workflowName } as never,
    store: mockStore as never,
    logFile: join(tmpDir, "pipeline.log"),
    notifyClient: null,
    agentMailClient: null,
    runPhase,
    runBuiltinPhase,
    registerAgent: vi.fn().mockResolvedValue(undefined),
    sendMail: vi.fn(),
    sendMailText: vi.fn(),
    reserveFiles: vi.fn(),
    releaseFiles: vi.fn(),
    markStuck: vi.fn().mockResolvedValue(undefined),
    log,
    promptOpts: { projectRoot: tmpDir, workflow: "default" },
  };
}

function writePhaseArtifact(tmpDir: string, phaseName: string, content: string): void {
  const phaseArtifacts: Record<string, string> = {
    explorer: "EXPLORER_REPORT.md",
    developer: "DEVELOPER_REPORT.md",
    qa: "QA_REPORT.md",
    reviewer: "REVIEW.md",
    finalize: "FINALIZE_VALIDATION.md",
    "pr-review": "PR_REVIEW_REPORT.md",
  };
  const artifact = phaseArtifacts[phaseName];
  if (!artifact) return;
  writeFileSync(join(tmpDir, artifact), content);
  const reportDir = join(tmpDir, ".foreman", "reports", "proj-reviewer-retry", "task-reviewer-retry", "run-reviewer-retry-test");
  mkdirSync(reportDir, { recursive: true });
  writeFileSync(join(reportDir, artifact), content);
}

function successResult() {
  return {
    success: true,
    costUsd: 0.01,
    turns: 5,
    tokensIn: 100,
    tokensOut: 50,
  };
}

// ── Workflow config invariant tests ───────────────────────────────────────────

describe("bundled default.yaml: verdict/retry config", () => {
  it("reviewer phase has verdict:true, retryWith:developer, retryOnFail:1", () => {
    const phases = loadPhaseMap(BUNDLED_DEFAULT_YAML);
    expect(phases["reviewer"]).toBeDefined();
    expect(phases["reviewer"].verdict).toBe(true);
    expect(phases["reviewer"].retryWith).toBe("developer");
    expect(phases["reviewer"].retryOnFail).toBe(1);
    expect(phases["reviewer"].artifact).toBe("{task.projectReportsDir}/REVIEW.md");
  });

  it("qa phase has verdict:true, retryWith:developer, retryOnFail:2", () => {
    const phases = loadPhaseMap(BUNDLED_DEFAULT_YAML);
    expect(phases["qa"]).toBeDefined();
    expect(phases["qa"].verdict).toBe(true);
    expect(phases["qa"].retryWith).toBe("developer");
    expect(phases["qa"].retryOnFail).toBe(2);
    expect(phases["qa"].artifact).toBe("{task.projectReportsDir}/QA_REPORT.md");
  });
});

describe("project-local .foreman/workflows/default.yaml: verdict/retry config", () => {
  it("reviewer phase has verdict:true, retryWith:developer, retryOnFail:1", () => {
    const phases = loadPhaseMap(RESOLVED_LOCAL_DEFAULT_YAML);
    expect(phases["reviewer"]).toBeDefined();
    expect(phases["reviewer"].verdict).toBe(true);
    expect(phases["reviewer"].retryWith).toBe("developer");
    expect(phases["reviewer"].retryOnFail).toBe(1);
    expect(phases["reviewer"].artifact).toBe("{task.projectReportsDir}/REVIEW.md");
  });

  it("qa phase has verdict:true, retryWith:developer, retryOnFail:2", () => {
    const phases = loadPhaseMap(RESOLVED_LOCAL_DEFAULT_YAML);
    expect(phases["qa"]).toBeDefined();
    expect(phases["qa"].verdict).toBe(true);
    expect(phases["qa"].retryWith).toBe("developer");
    expect(phases["qa"].retryOnFail).toBe(2);
    expect(phases["qa"].artifact).toBe("{task.projectReportsDir}/QA_REPORT.md");
  });

  it("local file stays in sync with bundled default for verdict/retry fields", () => {
    const bundled = loadPhaseMap(BUNDLED_DEFAULT_YAML);
    const local = loadPhaseMap(RESOLVED_LOCAL_DEFAULT_YAML);

    for (const phaseName of ["qa", "reviewer", "finalize"]) {
      const b = bundled[phaseName];
      const l = local[phaseName];
      if (b === undefined || l === undefined) continue;
      expect(l.verdict).toBe(b.verdict);
      expect(l.retryWith).toBe(b.retryWith);
      expect(l.retryOnFail).toBe(b.retryOnFail);
      expect(l.artifact).toBe(b.artifact);
    }
  });
});

// ── Integration test: executePipeline with real loaded default workflow ───────

describe("executePipeline(): reviewer FAIL loops back to developer (regression)", () => {
  let tmpDir: string;
  let originalHome: string | undefined;

  beforeEach(() => {
    originalHome = process.env.HOME;
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-reviewer-retry-"));
    mkdirSync(tmpDir, { recursive: true });
    process.env.HOME = tmpDir;
    // Create stub prompt files so buildPhasePrompt doesn't throw
    mkdirSync(join(tmpDir, ".foreman", "reports", "proj-reviewer-retry", "task-reviewer-retry", "run-reviewer-retry-test"), { recursive: true });
    const promptDir = join(tmpDir, ".foreman", "prompts", "default");
    mkdirSync(promptDir, { recursive: true });
    for (const phase of [
      "developer",
      "qa",
      "reviewer",
      "finalize",
      "explorer",
    ]) {
      writeFileSync(join(promptDir, `${phase}.md`), `# ${phase} stub\n`);
    }
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    if (originalHome === undefined) {
      delete process.env.HOME;
    } else {
      process.env.HOME = originalHome;
    }
  });

  it("loads real default workflow and reviewer FAIL loops back to developer", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");

    const loaded = loadWorkflowConfig("default", PROJECT_ROOT);
    const workflowConfig = {
      ...loaded,
      phases: loaded.phases
        .filter((phase) => ["explorer", "developer", "qa", "reviewer", "cli-review", "finalize"].includes(phase.name))
        .map((phase) => phase.artifact ? { ...phase, artifact: phase.artifact.split("/").pop() } : phase),
    };

    const reviewerPhase = workflowConfig.phases.find((p) => p.name === "reviewer");
    expect(reviewerPhase?.verdict).toBe(true);
    expect(reviewerPhase?.retryWith).toBe("developer");
    expect(reviewerPhase?.retryOnFail).toBe(1);

    const builtinOrder: string[] = [];
    const phaseOrder: string[] = [];
    const log = vi.fn();
    let reviewerCallCount = 0;

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "reviewer") {
        reviewerCallCount += 1;
        writePhaseArtifact(
          tmpDir,
          phaseName,
          reviewerCallCount === 1
            ? "# Code Review\n\n## Verdict: FAIL\n\n## Issues\n- **[CRITICAL]** src/foo.ts:10 — null deref\n"
            : "# Code Review\n\n## Verdict: PASS\n\n## Issues\n(none)\n",
        );
      } else if (phaseName === "qa") {
        writePhaseArtifact(tmpDir, phaseName, "# QA Report\n\n## Verdict: PASS\n\nRan `npm test`\n\nTests: 12 passed, 0 failed\n");
      } else if (phaseName === "finalize") {
        writePhaseArtifact(tmpDir, phaseName, "# Finalize Validation\n\n## Target Integration: SUCCESS\n\n## Test Validation: PASS\n");
      } else {
        writePhaseArtifact(tmpDir, phaseName, `# ${phaseName}\n`);
      }
      return successResult();
    });

    const runBuiltinPhase = vi.fn().mockImplementation(async (phase: { name: string }) => {
      phaseOrder.push(phase.name);
      builtinOrder.push(phase.name);
      if (phase.name === "cli-review") {
        writeFileSync(
          join(tmpDir, ".foreman/reports/proj-reviewer-retry/task-reviewer-retry/run-reviewer-retry-test/CR_CLI_REPORT.md"),
          "# CodeRabbit CLI Report\n\n## Verdict: PASS\n",
        );
      }
      return successResult();
    });

    const args = makePipelineArgs(tmpDir, workflowConfig.name, runPhase, runBuiltinPhase, log);
    await executePipeline({ ...args, workflowConfig } as never);

    expect(phaseOrder).toContain("reviewer");
    expect(reviewerCallCount).toBeGreaterThan(1);
    expect(builtinOrder).toContain("cli-review");
    expect(log).toHaveBeenCalledWith(
      expect.stringContaining("FAIL — looping back to developer"),
    );

    const cliReviewIdx = phaseOrder.lastIndexOf("cli-review");
    const lastReviewerIdx = phaseOrder.lastIndexOf("reviewer");
    expect(cliReviewIdx).toBeGreaterThan(lastReviewerIdx);
  });

  it("reviewer PASS proceeds directly to finalize (no retry)", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");

    const loaded = loadWorkflowConfig("default", PROJECT_ROOT);
    const workflowConfig = {
      ...loaded,
      phases: loaded.phases
        .filter((phase) => ["explorer", "developer", "qa", "reviewer", "cli-review", "finalize"].includes(phase.name))
        .map((phase) => phase.artifact ? { ...phase, artifact: phase.artifact.split("/").pop() } : phase),
    };

    const builtinOrder: string[] = [];
    const phaseOrder: string[] = [];
    const log = vi.fn();

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "reviewer") {
        writePhaseArtifact(tmpDir, phaseName, "# Code Review\n\n## Verdict: PASS\n\nLGTM.\n");
      } else if (phaseName === "qa") {
        writePhaseArtifact(tmpDir, phaseName, "# QA Report\n\n## Verdict: PASS\n\nRan `npm test`\n\nTests: 12 passed, 0 failed\n");
      } else if (phaseName === "finalize") {
        writePhaseArtifact(tmpDir, phaseName, "# Finalize Validation\n\n## Target Integration: SUCCESS\n\n## Test Validation: PASS\n");
      } else {
        writePhaseArtifact(tmpDir, phaseName, `# ${phaseName}\n`);
      }
      return successResult();
    });

    const runBuiltinPhase = vi.fn().mockImplementation(async (phase: { name: string }) => {
      phaseOrder.push(phase.name);
      builtinOrder.push(phase.name);
      if (phase.name === "cli-review") {
        writeFileSync(
          join(tmpDir, ".foreman/reports/proj-reviewer-retry/task-reviewer-retry/run-reviewer-retry-test/CR_CLI_REPORT.md"),
          "# CodeRabbit CLI Report\n\n## Verdict: PASS\n",
        );
      }
      return successResult();
    });

    const args = makePipelineArgs(tmpDir, workflowConfig.name, runPhase, runBuiltinPhase, log);
    await executePipeline({ ...args, workflowConfig } as never);

    const reviewerRuns = phaseOrder.filter((p) => p === "reviewer").length;
    expect(reviewerRuns).toBeGreaterThanOrEqual(1);
    expect(builtinOrder).toContain("cli-review");

    const reviewerIdx = phaseOrder.indexOf("reviewer");
    const cliReviewIdx = phaseOrder.indexOf("cli-review");
    expect(cliReviewIdx).toBeGreaterThan(reviewerIdx);
  });
});
