/**
 * Tests for finalize pre-push test validation (bd-ywnz).
 *
 * Verifies that the finalize phase is configured to:
 *   1. Run tests after rebase and before push (via prompt instructions)
 *   2. Write FINALIZE_VALIDATION.md with PASS/FAIL verdict
 *   3. Stop and NOT push when tests fail (FAIL verdict)
 *   4. The default.yaml workflow enables verdict/retry for finalize
 *
 * Also tests pipeline-executor verdict retry logic for the finalize phase:
 *   - FAIL verdict → loops back to developer (retryWith: developer)
 *   - PASS verdict → proceeds to onPipelineComplete
 *   - retryOnFail: 1 means only one retry attempt
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { readFileSync } from "node:fs";
import { validateWorkflowConfig } from "../../lib/workflow-loader.js";
import { installBundledPrompts } from "../../lib/prompt-loader.js";
import { executePipeline } from "../pipeline-executor.js";
import type { PipelineContext, RunPhaseFn, PhaseResult } from "../pipeline-executor.js";
import type { WorkflowConfig } from "../../lib/workflow-loader.js";
import type { ForemanStore } from "../../lib/store.js";

// ── Constants ─────────────────────────────────────────────────────────────────

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const DEFAULT_FINALIZE_MD = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "finalize.md");
const DEFAULT_WORKFLOW_YAML = join(PROJECT_ROOT, "src", "defaults", "workflows", "default.yaml");

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeMockStore(): ForemanStore {
  return {
    updateRunProgress: vi.fn(),
    logEvent: vi.fn(),
    getActiveRuns: vi.fn(() => []),
    updateRun: vi.fn(),
    getRunEvents: vi.fn((): unknown[] => []),
  } as unknown as ForemanStore;
}

function makePipelineContext(
  tmpDir: string,
  runPhase: RunPhaseFn,
  overrides: Partial<PipelineContext> = {},
): PipelineContext {
  const store = makeMockStore();
  return {
    config: {
      runId: "run-test-1",
      projectId: "proj-test",
      seedId: "bd-test",
      seedTitle: "Test task",
      model: "anthropic/claude-haiku-4-5",
      worktreePath: tmpDir,
      env: {},
    },
    workflowConfig: {
      name: "default",
      phases: [],
    },
    store,
    logFile: join(tmpDir, "test.log"),
    notifyClient: null,
    agentMailClient: null,
    runPhase,
    registerAgent: vi.fn().mockResolvedValue(undefined),
    sendMail: vi.fn(),
    sendMailText: vi.fn(),
    reserveFiles: vi.fn(),
    releaseFiles: vi.fn(),
    markStuck: vi.fn().mockResolvedValue(undefined),
    log: vi.fn(),
    promptOpts: { projectRoot: tmpDir, workflow: "default" },
    ...overrides,
  } as PipelineContext;
}

// A minimal workflow config for testing finalize verdict/retry:
// developer → finalize (with verdict and retryWith)
function makeTestWorkflow(retryOnFail = 1): WorkflowConfig {
  return {
    name: "test",
    phases: [
      {
        name: "developer",
        prompt: "developer.md",
        artifact: "DEVELOPER_REPORT.md",
        mail: { onStart: false, onComplete: false },
      },
      {
        name: "finalize",
        prompt: "finalize.md",
        artifact: "FINALIZE_VALIDATION.md",
        verdict: true,
        retryWith: "developer",
        retryOnFail,
        mail: { onStart: false, onComplete: false, onFail: "developer" },
      },
    ],
  };
}

// ── Structural tests: default workflow YAML ───────────────────────────────────

describe("default.yaml: finalize phase pre-push validation config", () => {
  it("finalize phase has artifact: FINALIZE_VALIDATION.md", () => {
    const { load: yamlLoad } = require("js-yaml") as { load: (s: string) => unknown };
    const raw = yamlLoad(readFileSync(DEFAULT_WORKFLOW_YAML, "utf-8"));
    const config = validateWorkflowConfig(raw, "default");
    const finalize = config.phases.find((p) => p.name === "finalize");
    expect(finalize).toBeDefined();
    expect(finalize?.artifact).toBe("FINALIZE_VALIDATION.md");
  });

  it("finalize phase has verdict: true", () => {
    const { load: yamlLoad } = require("js-yaml") as { load: (s: string) => unknown };
    const raw = yamlLoad(readFileSync(DEFAULT_WORKFLOW_YAML, "utf-8"));
    const config = validateWorkflowConfig(raw, "default");
    const finalize = config.phases.find((p) => p.name === "finalize");
    expect(finalize?.verdict).toBe(true);
  });

  it("finalize phase has retryWith: developer", () => {
    const { load: yamlLoad } = require("js-yaml") as { load: (s: string) => unknown };
    const raw = yamlLoad(readFileSync(DEFAULT_WORKFLOW_YAML, "utf-8"));
    const config = validateWorkflowConfig(raw, "default");
    const finalize = config.phases.find((p) => p.name === "finalize");
    expect(finalize?.retryWith).toBe("developer");
  });

  it("finalize phase has retryOnFail: 1", () => {
    const { load: yamlLoad } = require("js-yaml") as { load: (s: string) => unknown };
    const raw = yamlLoad(readFileSync(DEFAULT_WORKFLOW_YAML, "utf-8"));
    const config = validateWorkflowConfig(raw, "default");
    const finalize = config.phases.find((p) => p.name === "finalize");
    expect(finalize?.retryOnFail).toBe(1);
  });

  it("finalize phase has mail.onFail: developer", () => {
    const { load: yamlLoad } = require("js-yaml") as { load: (s: string) => unknown };
    const raw = yamlLoad(readFileSync(DEFAULT_WORKFLOW_YAML, "utf-8"));
    const config = validateWorkflowConfig(raw, "default");
    const finalize = config.phases.find((p) => p.name === "finalize");
    expect(finalize?.mail?.onFail).toBe("developer");
  });

  it("finalize phase maxTurns is at least 30 (enough for git + npm test)", () => {
    const { load: yamlLoad } = require("js-yaml") as { load: (s: string) => unknown };
    const raw = yamlLoad(readFileSync(DEFAULT_WORKFLOW_YAML, "utf-8"));
    const config = validateWorkflowConfig(raw, "default");
    const finalize = config.phases.find((p) => p.name === "finalize");
    expect(finalize?.maxTurns).toBeGreaterThanOrEqual(30);
  });
});

// ── Structural tests: finalize.md prompt ─────────────────────────────────────

describe("default/finalize.md: pre-push test validation prompt", () => {
  it("prompt contains npm test instruction after target integration step", () => {
    const content = readFileSync(DEFAULT_FINALIZE_MD, "utf-8");
    const integratePos = content.indexOf("{{vcsIntegrateTargetCommand}}");
    const npmTestPos = content.indexOf("npm test");
    expect(integratePos).toBeGreaterThan(-1);
    expect(npmTestPos).toBeGreaterThan(-1);
    expect(npmTestPos).toBeGreaterThan(integratePos);
  });

  it("prompt instructs agent to write FINALIZE_VALIDATION.md", () => {
    const content = readFileSync(DEFAULT_FINALIZE_MD, "utf-8");
    expect(content).toContain("FINALIZE_VALIDATION.md");
  });

  it("prompt contains ## Verdict: PASS and ## Verdict: FAIL template entries", () => {
    const content = readFileSync(DEFAULT_FINALIZE_MD, "utf-8");
    expect(content).toContain("## Verdict: PASS");
    expect(content).toContain("## Verdict: FAIL");
  });

  it("prompt instructs agent to skip integration and tests when target did not drift after QA", () => {
    const content = readFileSync(DEFAULT_FINALIZE_MD, "utf-8");
    expect(content).toContain("Should integrate target drift");
    expect(content).toContain("Do **not** run `{{vcsIntegrateTargetCommand}}`");
    expect(content).toContain("Do **not** rerun `npm test`");
    expect(content).toContain("## Target Integration");
    expect(content).toContain("- Status: SUCCESS | SKIPPED | FAIL");
    expect(content).toContain("Write `## Target Integration` with `- Status: SKIPPED`");
  });

  it("prompt instructs agent NOT to push when tests fail", () => {
    const content = readFileSync(DEFAULT_FINALIZE_MD, "utf-8");
    // Should explicitly tell the agent to stop / not push on FAIL
    expect(content.toLowerCase()).toMatch(/do not push|stop here|not push|do not run step 8/i);
  });

  it("npm test must appear before push command in the prompt", () => {
    const content = readFileSync(DEFAULT_FINALIZE_MD, "utf-8");
    const npmTestPos = content.indexOf("npm test");
    // Push command is now a template variable {{vcsPushCommand}} (TRD-026)
    const vcsPushPos = content.indexOf("{{vcsPushCommand}}");
    expect(npmTestPos).toBeGreaterThan(-1);
    expect(vcsPushPos).toBeGreaterThan(-1);
    expect(npmTestPos).toBeLessThan(vcsPushPos);
  });

  it("prompt does not send agent-error mail on test failure (expected retry condition)", () => {
    const content = readFileSync(DEFAULT_FINALIZE_MD, "utf-8");
    // The section describing test failure handling should NOT include /send-mail error
    // Extract the test failure handling section
    const testFailSection = content.slice(
      content.indexOf("## Verdict: FAIL"),
      content.indexOf("### Step 8:"),
    );
    // Should not contain agent-error in the test-fail handling block
    expect(testFailSection).not.toContain("agent-error");
  });
});

// ── Pipeline executor: finalize verdict retry logic ───────────────────────────

describe("executePipeline(): finalize FAIL verdict → retry developer", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-test-"));
    // Touch log file
    writeFileSync(join(tmpDir, "test.log"), "");
    // Install bundled prompts so buildPhasePrompt() can resolve them
    installBundledPrompts(tmpDir, true);
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("loops back to developer when finalize writes ## Verdict: FAIL", async () => {
    const phaseOrder: string[] = [];

    // runPhase mock:
    // - developer: always succeeds, writes DEVELOPER_REPORT.md
    // - finalize (first call): succeeds but writes FAIL verdict
    // - developer (retry): succeeds, writes DEVELOPER_REPORT.md
    // - finalize (retry): succeeds with PASS verdict
    let finalizeCallCount = 0;

    const runPhase: RunPhaseFn = vi.fn(async (role: string) => {
      phaseOrder.push(role);
      if (role === "developer") {
        writeFileSync(join(tmpDir, "DEVELOPER_REPORT.md"), "# Developer Report\n");
        return { success: true, costUsd: 0.01, turns: 5, tokensIn: 100, tokensOut: 50 } as PhaseResult;
      }
      if (role === "finalize") {
        finalizeCallCount++;
        if (finalizeCallCount === 1) {
          // First call: tests fail after rebase
          writeFileSync(
            join(tmpDir, "FINALIZE_VALIDATION.md"),
            [
              "# Finalize Validation",
              "## Seed: bd-test",
              "## Test Validation",
              "- Status: FAIL",
              "- Output: 3 tests failed",
              "",
              "## Verdict: FAIL",
            ].join("\n"),
          );
        } else {
          // Retry call: tests pass
          writeFileSync(
            join(tmpDir, "FINALIZE_VALIDATION.md"),
            [
              "# Finalize Validation",
              "## Seed: bd-test",
              "## Test Validation",
              "- Status: PASS",
              "",
              "## Verdict: PASS",
            ].join("\n"),
          );
        }
        return { success: true, costUsd: 0.02, turns: 8, tokensIn: 200, tokensOut: 100 } as PhaseResult;
      }
      return { success: true, costUsd: 0, turns: 1, tokensIn: 10, tokensOut: 5 } as PhaseResult;
    });

    const onPipelineComplete = vi.fn().mockResolvedValue(undefined);
    const ctx = makePipelineContext(tmpDir, runPhase, {
      workflowConfig: makeTestWorkflow(1),
      onPipelineComplete,
    });

    await executePipeline(ctx);

    // Should have run: developer → finalize (FAIL) → developer (retry) → finalize (PASS)
    expect(phaseOrder).toEqual(["developer", "finalize", "developer", "finalize"]);
    expect(onPipelineComplete).toHaveBeenCalledOnce();
  });

  it("does NOT retry when max retries (retryOnFail: 1) are exhausted", async () => {
    const phaseOrder: string[] = [];

    const runPhase: RunPhaseFn = vi.fn(async (role: string) => {
      phaseOrder.push(role);
      if (role === "developer") {
        writeFileSync(join(tmpDir, "DEVELOPER_REPORT.md"), "# Developer Report\n");
        return { success: true, costUsd: 0.01, turns: 5, tokensIn: 100, tokensOut: 50 } as PhaseResult;
      }
      if (role === "finalize") {
        // Always writes FAIL verdict
        writeFileSync(
          join(tmpDir, "FINALIZE_VALIDATION.md"),
          "# Finalize Validation\n## Verdict: FAIL\n",
        );
        return { success: true, costUsd: 0.02, turns: 8, tokensIn: 200, tokensOut: 100 } as PhaseResult;
      }
      return { success: true, costUsd: 0, turns: 1, tokensIn: 10, tokensOut: 5 } as PhaseResult;
    });

    const onPipelineComplete = vi.fn().mockResolvedValue(undefined);
    const ctx = makePipelineContext(tmpDir, runPhase, {
      workflowConfig: makeTestWorkflow(1), // retryOnFail: 1 → only 1 retry
      onPipelineComplete,
    });

    await executePipeline(ctx);

    // retryOnFail: 1 means: developer → finalize(FAIL) → developer(retry) → finalize(FAIL, exhausted)
    expect(phaseOrder).toEqual(["developer", "finalize", "developer", "finalize"]);
    expect(onPipelineComplete).toHaveBeenCalledOnce();
    expect(onPipelineComplete).toHaveBeenCalledWith(expect.objectContaining({ success: false }));
  });

  it("sends mail feedback to developer on finalize FAIL", async () => {
    let finalizeCount = 0;

    const runPhase: RunPhaseFn = vi.fn(async (role: string) => {
      if (role === "developer") {
        writeFileSync(join(tmpDir, "DEVELOPER_REPORT.md"), "# Developer Report\n");
        return { success: true, costUsd: 0.01, turns: 5, tokensIn: 100, tokensOut: 50 } as PhaseResult;
      }
      if (role === "finalize") {
        finalizeCount++;
        if (finalizeCount === 1) {
          // First finalize: tests fail
          writeFileSync(
            join(tmpDir, "FINALIZE_VALIDATION.md"),
            "# Finalize Validation\n## Test Validation\n- Status: FAIL\n- Output: 2 tests failed\n\n## Verdict: FAIL",
          );
        } else {
          // Retry finalize: tests pass
          writeFileSync(
            join(tmpDir, "FINALIZE_VALIDATION.md"),
            "# Finalize Validation\n## Test Validation\n- Status: PASS\n\n## Verdict: PASS",
          );
        }
        return { success: true, costUsd: 0.02, turns: 8, tokensIn: 200, tokensOut: 100 } as PhaseResult;
      }
      return { success: true, costUsd: 0, turns: 1, tokensIn: 10, tokensOut: 5 } as PhaseResult;
    });

    const sendMailText = vi.fn();
    const ctx = makePipelineContext(tmpDir, runPhase, {
      workflowConfig: makeTestWorkflow(1),
      sendMailText,
      onPipelineComplete: vi.fn().mockResolvedValue(undefined),
    });

    await executePipeline(ctx);

    // Should have sent feedback mail to developer-bd-test with the FAIL verdict content
    expect(sendMailText).toHaveBeenCalledWith(
      null,
      "developer-bd-test",
      expect.stringContaining("Finalize Feedback"),
      expect.stringContaining("FAIL"),
    );
  });

  it("does not retry developer for unrelated pre-existing finalize failures", async () => {
    const phaseOrder: string[] = [];

    const runPhase: RunPhaseFn = vi.fn(async (role: string) => {
      phaseOrder.push(role);
      if (role === "developer") {
        writeFileSync(join(tmpDir, "DEVELOPER_REPORT.md"), "# Developer Report\n");
      } else if (role === "finalize") {
        writeFileSync(
          join(tmpDir, "FINALIZE_VALIDATION.md"),
          [
            "# Finalize Validation",
            "## Test Validation",
            "- Status: FAIL",
            "- Output: unrelated tests failed",
            "",
            "## Failure Scope",
            "- UNRELATED_FILES",
            "",
            "## Verdict: FAIL",
          ].join("\n"),
        );
      }
      return { success: true, costUsd: 0.01, turns: 5, tokensIn: 100, tokensOut: 50 } as PhaseResult;
    });

    const onPipelineComplete = vi.fn().mockResolvedValue(undefined);
    const ctx = makePipelineContext(tmpDir, runPhase, {
      workflowConfig: makeTestWorkflow(1),
      onPipelineComplete,
    });

    await executePipeline(ctx);

    expect(phaseOrder).toEqual(["developer", "finalize"]);
    expect(onPipelineComplete).toHaveBeenCalledWith(expect.objectContaining({ success: false }));
  });

  it("does not retry developer when finalize mail marks failure as retryable=false", async () => {
    const phaseOrder: string[] = [];

    const runPhase: RunPhaseFn = vi.fn(async (role: string) => {
      phaseOrder.push(role);
      if (role === "developer") {
        writeFileSync(join(tmpDir, "DEVELOPER_REPORT.md"), "# Developer Report\n");
      } else if (role === "finalize") {
        writeFileSync(
          join(tmpDir, "FINALIZE_VALIDATION.md"),
          [
            "# Finalize Validation",
            "## Target Integration",
            "- Status: FAIL",
            "",
            "## Test Validation",
            "- Status: FAIL",
            "- Output: rebase conflict while integrating target drift",
            "",
            "## Failure Scope",
            "- MODIFIED_FILES",
            "",
            "## Verdict: FAIL",
          ].join("\n"),
        );
      }
      return { success: true, costUsd: 0.01, turns: 5, tokensIn: 100, tokensOut: 50 } as PhaseResult;
    });

    const sendMailText = vi.fn();
    const agentMailClient = {
      fetchInbox: vi.fn().mockResolvedValue([
        {
          id: "m1",
          from: "finalize-bd-test",
          to: "foreman",
          subject: "agent-error",
          body: JSON.stringify({
            phase: "finalize",
            seedId: "bd-test",
            error: "rebase_conflict",
            retryable: false,
          }),
          receivedAt: new Date().toISOString(),
          acknowledged: false,
        },
      ]),
    };

    const onPipelineComplete = vi.fn().mockResolvedValue(undefined);
    const ctx = makePipelineContext(tmpDir, runPhase, {
      workflowConfig: makeTestWorkflow(1),
      agentMailClient: agentMailClient as never,
      sendMailText,
      onPipelineComplete,
    });

    await executePipeline(ctx);

    expect(phaseOrder).toEqual(["developer", "finalize"]);
    expect(sendMailText).not.toHaveBeenCalled();
    expect(onPipelineComplete).toHaveBeenCalledWith(expect.objectContaining({ success: false }));
  });

  it("proceeds to onPipelineComplete when finalize writes ## Verdict: PASS", async () => {
    const phaseOrder: string[] = [];

    const runPhase: RunPhaseFn = vi.fn(async (role: string) => {
      phaseOrder.push(role);
      if (role === "developer") {
        writeFileSync(join(tmpDir, "DEVELOPER_REPORT.md"), "# Developer Report\n");
      } else if (role === "finalize") {
        writeFileSync(
          join(tmpDir, "FINALIZE_VALIDATION.md"),
          "# Finalize Validation\n\n## Target Integration\n- Status: SUCCESS\n\n## Test Validation\n- Status: PASS\n\n## Verdict: PASS\n",
        );
      }
      return { success: true, costUsd: 0.01, turns: 5, tokensIn: 100, tokensOut: 50 } as PhaseResult;
    });

    const onPipelineComplete = vi.fn().mockResolvedValue(undefined);
    const ctx = makePipelineContext(tmpDir, runPhase, {
      workflowConfig: makeTestWorkflow(1),
      onPipelineComplete,
    });

    await executePipeline(ctx);

    // No retry: developer → finalize(PASS) → done
    expect(phaseOrder).toEqual(["developer", "finalize"]);
    expect(onPipelineComplete).toHaveBeenCalledOnce();
  });
});
