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
      seedId: "seed-reviewer-retry",
      seedTitle: "Reviewer retry regression test",
      model: "anthropic/claude-sonnet-4-6",
      worktreePath: tmpDir,
      env: {},
    },
    workflowConfig: { name: workflowName } as never,
    store: mockStore as never,
    logFile: join(tmpDir, "pipeline.log"),
    notifyClient: null,
    agentMailClient: null,
    runPhase,
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
    expect(phases["reviewer"].artifact).toBe("REVIEW.md");
  });

  it("qa phase has verdict:true, retryWith:developer, retryOnFail:2", () => {
    const phases = loadPhaseMap(BUNDLED_DEFAULT_YAML);
    expect(phases["qa"]).toBeDefined();
    expect(phases["qa"].verdict).toBe(true);
    expect(phases["qa"].retryWith).toBe("developer");
    expect(phases["qa"].retryOnFail).toBe(2);
    expect(phases["qa"].artifact).toBe("QA_REPORT.md");
  });
});

describe("project-local .foreman/workflows/default.yaml: verdict/retry config", () => {
  it("reviewer phase has verdict:true, retryWith:developer, retryOnFail:1", () => {
    const phases = loadPhaseMap(LOCAL_DEFAULT_YAML);
    expect(phases["reviewer"]).toBeDefined();
    expect(phases["reviewer"].verdict).toBe(true);
    expect(phases["reviewer"].retryWith).toBe("developer");
    expect(phases["reviewer"].retryOnFail).toBe(1);
    expect(phases["reviewer"].artifact).toBe("REVIEW.md");
  });

  it("qa phase has verdict:true, retryWith:developer, retryOnFail:2", () => {
    const phases = loadPhaseMap(LOCAL_DEFAULT_YAML);
    expect(phases["qa"]).toBeDefined();
    expect(phases["qa"].verdict).toBe(true);
    expect(phases["qa"].retryWith).toBe("developer");
    expect(phases["qa"].retryOnFail).toBe(2);
    expect(phases["qa"].artifact).toBe("QA_REPORT.md");
  });

  it("local file stays in sync with bundled default for verdict/retry fields", () => {
    const bundled = loadPhaseMap(BUNDLED_DEFAULT_YAML);
    const local = loadPhaseMap(LOCAL_DEFAULT_YAML);

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

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-reviewer-retry-"));
    mkdirSync(tmpDir, { recursive: true });
    // Create stub prompt files so buildPhasePrompt doesn't throw
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
  });

  it("loads real default workflow and reviewer FAIL loops back to developer", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");

    const workflowConfig = loadWorkflowConfig("default", PROJECT_ROOT);

    // Confirm the loaded workflow has the retry config we expect
    const reviewerPhase = workflowConfig.phases.find(
      (p) => p.name === "reviewer",
    );
    expect(reviewerPhase?.verdict).toBe(true);
    expect(reviewerPhase?.retryWith).toBe("developer");
    expect(reviewerPhase?.retryOnFail).toBe(1);

    const phaseOrder: string[] = [];
    const log = vi.fn();
    let reviewerCallCount = 0;

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);

      if (phaseName === "reviewer") {
        reviewerCallCount++;
        if (reviewerCallCount === 1) {
          // First reviewer run: write FAIL verdict
          writeFileSync(
            join(tmpDir, "REVIEW.md"),
            "# Code Review\n\n## Verdict: FAIL\n\n## Issues\n- **[CRITICAL]** src/foo.ts:10 — null deref\n",
          );
        } else {
          // Second reviewer run (after developer retry): write PASS
          writeFileSync(
            join(tmpDir, "REVIEW.md"),
            "# Code Review\n\n## Verdict: PASS\n\n## Issues\n(none)\n",
          );
        }
      }

      return successResult();
    });

    const args = makePipelineArgs(tmpDir, workflowConfig.name, runPhase, log);

    await executePipeline({ ...args, workflowConfig } as never);

    // Expected: explorer → developer → qa → reviewer(FAIL) → developer → qa → reviewer(PASS) → finalize
    // (explorer may be skipped if skipIfArtifact is checked — but no artifact present, so it runs)
    expect(phaseOrder).toContain("reviewer");
    expect(reviewerCallCount).toBe(2);

    // Verify retry log was emitted
    expect(log).toHaveBeenCalledWith(
      expect.stringContaining("FAIL — looping back to developer"),
    );

    // Verify finalize ran AFTER the second reviewer pass
    const finalizeIdx = phaseOrder.lastIndexOf("finalize");
    const lastReviewerIdx = phaseOrder.lastIndexOf("reviewer");
    expect(finalizeIdx).toBeGreaterThan(lastReviewerIdx);
  });

  it("reviewer PASS proceeds directly to finalize (no retry)", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const { loadWorkflowConfig } = await import("../../lib/workflow-loader.js");

    const workflowConfig = loadWorkflowConfig("default", PROJECT_ROOT);
    const phaseOrder: string[] = [];
    const log = vi.fn();

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "reviewer") {
        writeFileSync(
          join(tmpDir, "REVIEW.md"),
          "# Code Review\n\n## Verdict: PASS\n\nLGTM.\n",
        );
      }
      return successResult();
    });

    const args = makePipelineArgs(tmpDir, workflowConfig.name, runPhase, log);
    await executePipeline({ ...args, workflowConfig } as never);

    // reviewer runs exactly once, then finalize
    const reviewerRuns = phaseOrder.filter((p) => p === "reviewer").length;
    expect(reviewerRuns).toBe(1);
    expect(log).not.toHaveBeenCalledWith(
      expect.stringContaining("FAIL — looping back"),
    );

    const reviewerIdx = phaseOrder.indexOf("reviewer");
    const finalizeIdx = phaseOrder.indexOf("finalize");
    expect(finalizeIdx).toBeGreaterThan(reviewerIdx);
  });
});
