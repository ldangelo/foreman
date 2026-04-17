/**
 * Tests for verdict-triggered retry in the pipeline executor.
 *
 * Verifies:
 *  1. reviewer FAIL verdict loops back to developer (regression for P0 bug)
 *  2. qa FAIL verdict loops back to developer
 *  3. Retry counter is independent per phase (reviewer and qa don't share budget)
 *  4. Max retries (retryOnFail) limits loop count
 *  5. After max retries exhausted, pipeline continues to next phase
 *  6. PASS verdict does NOT loop back (normal flow)
 *  7. Missing artifact yields "unknown" verdict — no retry triggered
 *  8. QA report without test evidence is treated as FAIL
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ── Helpers ───────────────────────────────────────────────────────────────

function makeBasePipelineArgs(
  tmpDir: string,
  phases: object[],
  runPhase: ReturnType<typeof vi.fn>,
  log: ReturnType<typeof vi.fn>,
) {
  const mockStore = {
    updateRunProgress: vi.fn(),
    logEvent: vi.fn(),
  };

  return {
    config: {
      runId: "run-verdict-001",
      projectId: "proj-001",
      seedId: "seed-verdict",
      seedTitle: "Verdict retry test",
      model: "anthropic/claude-sonnet-4-6",
      worktreePath: tmpDir,
      env: {},
    },
    workflowConfig: { name: "test", phases } as never,
    store: mockStore as never,
    logFile: join(tmpDir, "verdict.log"),
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
  return { success: true, costUsd: 0.01, turns: 5, tokensIn: 100, tokensOut: 50 };
}

// ── Tests ─────────────────────────────────────────────────────────────────

describe("verdict-triggered retry", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-verdict-test-"));
    mkdirSync(tmpDir, { recursive: true });
    // Create stub prompt files so prompt-loader doesn't throw
    const promptDir = join(tmpDir, ".foreman", "prompts", "default");
    mkdirSync(promptDir, { recursive: true });
    for (const phase of ["developer", "qa", "reviewer", "explorer"]) {
      writeFileSync(join(promptDir, `${phase}.md`), `# ${phase} stub\n`);
    }
    writeFileSync(
      join(promptDir, "finalize.md"),
      "# finalize stub\nqa={{qaValidatedTargetRef}}\ncurrent={{currentTargetRef}}\nrerun={{shouldRunFinalizeValidation}}\n",
    );
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("reviewer FAIL loops back to developer (retryOnFail: 1)", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const phaseOrder: string[] = [];
    const log = vi.fn();

    const phases = [
      { name: "developer", artifact: "DEVELOPER_REPORT.md" },
      { name: "reviewer", artifact: "REVIEW.md", verdict: true, retryWith: "developer", retryOnFail: 1 },
      { name: "finalize", artifact: "FINALIZE_REPORT.md" },
    ];

    let reviewerCallCount = 0;
    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "reviewer") {
        reviewerCallCount++;
        // First reviewer run: write FAIL verdict
        if (reviewerCallCount === 1) {
          writeFileSync(join(tmpDir, "REVIEW.md"), "# Review\n\n## Verdict: FAIL\n\nIssues found.\n");
        } else {
          // Second reviewer run (after developer retry): write PASS
          writeFileSync(join(tmpDir, "REVIEW.md"), "# Review\n\n## Verdict: PASS\n\nAll good.\n");
        }
      }
      return successResult();
    });

    await executePipeline(makeBasePipelineArgs(tmpDir, phases, runPhase, log) as never);

    // developer → reviewer (FAIL) → developer (retry) → reviewer (PASS) → finalize
    expect(phaseOrder).toEqual(["developer", "reviewer", "developer", "reviewer", "finalize"]);
    expect(reviewerCallCount).toBe(2);
    // Retry log should have been emitted
    expect(log).toHaveBeenCalledWith(expect.stringContaining("FAIL — looping back to developer"));
  });

  it("qa FAIL loops back to developer (retryOnFail: 2)", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const phaseOrder: string[] = [];
    const log = vi.fn();

    const phases = [
      { name: "developer", artifact: "DEVELOPER_REPORT.md" },
      { name: "qa", artifact: "QA_REPORT.md", verdict: true, retryWith: "developer", retryOnFail: 2 },
      { name: "finalize", artifact: "FINALIZE_REPORT.md" },
    ];

    let qaCallCount = 0;
    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "qa") {
        qaCallCount++;
        if (qaCallCount < 3) {
          writeFileSync(join(tmpDir, "QA_REPORT.md"), "# QA\n\n## Verdict: FAIL\nTests failed.\n");
        } else {
          writeFileSync(join(tmpDir, "QA_REPORT.md"), "# QA\n\n## Verdict: PASS\nAll tests pass.\n");
        }
      }
      return successResult();
    });

    await executePipeline(makeBasePipelineArgs(tmpDir, phases, runPhase, log) as never);

    // developer → qa (FAIL) → developer → qa (FAIL) → developer → qa (PASS) → finalize
    expect(phaseOrder).toEqual([
      "developer", "qa",      // first qa: FAIL
      "developer", "qa",      // retry 1: FAIL
      "developer", "qa",      // retry 2: PASS
      "finalize",
    ]);
    expect(qaCallCount).toBe(3);
  });

  it("after max retries (retryOnFail: 1) exhausted, pipeline continues to finalize", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const phaseOrder: string[] = [];
    const log = vi.fn();

    const phases = [
      { name: "developer", artifact: "DEVELOPER_REPORT.md" },
      { name: "reviewer", artifact: "REVIEW.md", verdict: true, retryWith: "developer", retryOnFail: 1 },
      { name: "finalize", artifact: "FINALIZE_REPORT.md" },
    ];

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "reviewer") {
        // Reviewer always FAILs — but max retries is 1
        writeFileSync(join(tmpDir, "REVIEW.md"), "# Review\n\n## Verdict: FAIL\nStill failing.\n");
      }
      return successResult();
    });

    await executePipeline(makeBasePipelineArgs(tmpDir, phases, runPhase, log) as never);

    // developer → reviewer (FAIL, retry 1) → developer → reviewer (FAIL, exhausted) → finalize
    expect(phaseOrder).toEqual(["developer", "reviewer", "developer", "reviewer", "finalize"]);
    expect(log).toHaveBeenCalledWith(expect.stringContaining("max retries"));
  });

  it("PASS verdict does NOT trigger retry — moves to next phase", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const phaseOrder: string[] = [];
    const log = vi.fn();

    const phases = [
      { name: "developer", artifact: "DEVELOPER_REPORT.md" },
      { name: "reviewer", artifact: "REVIEW.md", verdict: true, retryWith: "developer", retryOnFail: 1 },
      { name: "finalize", artifact: "FINALIZE_REPORT.md" },
    ];

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "reviewer") {
        writeFileSync(join(tmpDir, "REVIEW.md"), "# Review\n\n## Verdict: PASS\nLGTM.\n");
      }
      return successResult();
    });

    await executePipeline(makeBasePipelineArgs(tmpDir, phases, runPhase, log) as never);

    // No retry — straight through
    expect(phaseOrder).toEqual(["developer", "reviewer", "finalize"]);
    expect(log).not.toHaveBeenCalledWith(expect.stringContaining("FAIL — looping back"));
  });

  it("treats QA report without test evidence as FAIL and retries developer", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const phaseOrder: string[] = [];
    const log = vi.fn();

    const phases = [
      { name: "developer", artifact: "DEVELOPER_REPORT.md" },
      { name: "qa", artifact: "QA_REPORT.md", verdict: true, retryWith: "developer", retryOnFail: 1 },
      { name: "finalize", artifact: "FINALIZE_REPORT.md" },
    ];

    let qaCallCount = 0;
    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "qa") {
        qaCallCount++;
        if (qaCallCount === 1) {
          writeFileSync(join(tmpDir, "QA_REPORT.md"), "# QA Report\n\n## Verdict: PASS\n\n## Test Results\n- Looked good\n");
        } else {
          writeFileSync(join(tmpDir, "QA_REPORT.md"), "# QA Report\n\n## Verdict: PASS\n\n## Test Results\n- Command run: npm test -- --reporter=dot 2>&1\n- Test suite: 12 passed, 0 failed\n- Raw summary: 12 passed, 0 failed\n");
        }
      }
      return successResult();
    });

    await executePipeline(makeBasePipelineArgs(tmpDir, phases, runPhase, log) as never);

    expect(phaseOrder).toEqual(["developer", "qa", "developer", "qa", "finalize"]);
    expect(log).toHaveBeenCalledWith(expect.stringContaining("report missing test command evidence"));
  });

  it("missing artifact yields no retry (verdict unknown)", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const phaseOrder: string[] = [];
    const log = vi.fn();

    const phases = [
      { name: "developer", artifact: "DEVELOPER_REPORT.md" },
      { name: "reviewer", artifact: "REVIEW.md", verdict: true, retryWith: "developer", retryOnFail: 1 },
      { name: "finalize", artifact: "FINALIZE_REPORT.md" },
    ];

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      // reviewer does NOT write REVIEW.md — missing artifact
      return successResult();
    });

    await executePipeline(makeBasePipelineArgs(tmpDir, phases, runPhase, log) as never);

    // No retry — unknown verdict falls through
    expect(phaseOrder).toEqual(["developer", "reviewer", "finalize"]);
    expect(log).not.toHaveBeenCalledWith(expect.stringContaining("FAIL — looping back"));
  });

  it("reviewer and qa retry counters are independent (separate retryOnFail budgets)", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const phaseOrder: string[] = [];
    const log = vi.fn();

    const phases = [
      { name: "developer", artifact: "DEVELOPER_REPORT.md" },
      { name: "qa", artifact: "QA_REPORT.md", verdict: true, retryWith: "developer", retryOnFail: 1 },
      { name: "reviewer", artifact: "REVIEW.md", verdict: true, retryWith: "developer", retryOnFail: 1 },
      { name: "finalize", artifact: "FINALIZE_REPORT.md" },
    ];

    let qaCount = 0;
    let reviewerCount = 0;
    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "qa") {
        qaCount++;
        // First QA fails, second passes
        if (qaCount === 1) {
          writeFileSync(join(tmpDir, "QA_REPORT.md"), "# QA\n\n## Verdict: FAIL\n");
        } else {
          writeFileSync(join(tmpDir, "QA_REPORT.md"), "# QA\n\n## Verdict: PASS\n");
        }
      }
      if (phaseName === "reviewer") {
        reviewerCount++;
        // First reviewer fails, second passes (independent budget from QA)
        if (reviewerCount === 1) {
          writeFileSync(join(tmpDir, "REVIEW.md"), "# Review\n\n## Verdict: FAIL\n");
        } else {
          writeFileSync(join(tmpDir, "REVIEW.md"), "# Review\n\n## Verdict: PASS\n");
        }
      }
      return successResult();
    });

    await executePipeline(makeBasePipelineArgs(tmpDir, phases, runPhase, log) as never);

    // When reviewer fails and loops to developer, qa also re-runs (since it's between developer and reviewer)
    // developer → qa(FAIL) → developer → qa(PASS) → reviewer(FAIL) → developer → qa(PASS) → reviewer(PASS) → finalize
    expect(phaseOrder).toEqual([
      "developer", "qa",                   // qa fails
      "developer", "qa",                   // qa retry passes
      "reviewer",                          // reviewer fails, loops back to developer
      "developer", "qa", "reviewer",       // qa passes (3rd call), reviewer passes
      "finalize",
    ]);
    expect(qaCount).toBe(3); // qa runs 3x: initial fail, retry pass, re-runs after reviewer fail
    expect(reviewerCount).toBe(2);
  });

  it("records QA target revision and skips finalize rerun when target is unchanged", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const prompts: Record<string, string> = {};
    const log = vi.fn();
    const runPhase = vi.fn().mockImplementation(async (phaseName: string, prompt: string) => {
      prompts[phaseName] = prompt;
      if (phaseName === "qa") {
        writeFileSync(
          join(tmpDir, "QA_REPORT.md"),
          "# QA\n\n## Verdict: PASS\n\n## Test Results\n- Command run: `npm test -- --reporter=dot 2>&1`\n- Test suite: 10 passed, 0 failed\n- Raw summary: 10 passed, 0 failed\n",
        );
      }
      if (phaseName === "finalize") {
        writeFileSync(
          join(tmpDir, "FINALIZE_VALIDATION.md"),
          "# Finalize Validation\n\n## Target Integration\n- Status: SKIPPED\n\n## Test Validation\n- Status: SKIPPED\n- Output: QA already passed and target branch did not move.\n\n## Failure Scope\n- SKIPPED\n\n## Verdict: PASS\n",
        );
      }
      return successResult();
    });

    const vcsBackend = {
      name: "jujutsu",
      detectDefaultBranch: vi.fn().mockResolvedValue("dev"),
      resolveRef: vi.fn().mockImplementation(async (_repoPath: string, ref: string) => {
        if (ref === "origin/dev" || ref === "dev") return "rev-dev-123";
        throw new Error(`unknown ref ${ref}`);
      }),
      getHeadId: vi.fn().mockResolvedValue("head-bead-456"),
      isAncestor: vi.fn().mockResolvedValue(true),
      getFinalizeCommands: vi.fn().mockReturnValue({
        stageCommand: "",
        commitCommand: "jj describe -m 'msg'",
        pushCommand: "jj git push --bookmark foreman/seed-verdict --allow-new",
        integrateTargetCommand: "jj git fetch && jj rebase -d dev@origin",
        branchVerifyCommand: "jj bookmark list foreman/seed-verdict",
        cleanCommand: "jj workspace forget foreman-seed-verdict",
        restoreTrackedStateCommand: "true",
      }),
    };

    const phases = [
      { name: "developer", artifact: "DEVELOPER_REPORT.md" },
      { name: "qa", artifact: "QA_REPORT.md", verdict: true },
      { name: "finalize", artifact: "FINALIZE_VALIDATION.md", verdict: true },
    ];

    const args = makeBasePipelineArgs(tmpDir, phases, runPhase, log) as any;
    args.config.targetBranch = "dev";
    args.config.vcsBackend = vcsBackend;

    await executePipeline(args);

    expect(prompts.finalize).toContain("qa=rev-dev-123");
    expect(prompts.finalize).toContain("current=rev-dev-123");
    expect(prompts.finalize).toContain("rerun=false");
    expect(args.store.updateRunProgress).toHaveBeenCalledWith(
      "run-verdict-001",
      expect.objectContaining({
        qaValidatedTargetBranch: "dev",
        qaValidatedTargetRef: "rev-dev-123",
        qaValidatedHeadRef: "head-bead-456",
      }),
    );
    expect(args.store.updateRunProgress).toHaveBeenCalledWith(
      "run-verdict-001",
      expect.objectContaining({
        currentTargetRef: "rev-dev-123",
      }),
    );
  });

  it("fails finalize when target is unchanged but validation was not skipped", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const log = vi.fn();
    const phaseOrder: string[] = [];
    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "qa") {
        writeFileSync(
          join(tmpDir, "QA_REPORT.md"),
          "# QA\n\n## Verdict: PASS\n\n## Test Results\n- Command run: `npm test -- --reporter=dot 2>&1`\n- Test suite: 10 passed, 0 failed\n- Raw summary: 10 passed, 0 failed\n",
        );
      }
      if (phaseName === "finalize") {
        writeFileSync(
          join(tmpDir, "FINALIZE_VALIDATION.md"),
          "# Finalize Validation\n\n## Target Integration\n- Status: SUCCESS\n\n## Test Validation\n- Status: PASS\n- Output: reran tests anyway\n\n## Failure Scope\n- UNKNOWN\n\n## Verdict: PASS\n",
        );
      }
      return successResult();
    });

    const vcsBackend = {
      name: "jujutsu",
      detectDefaultBranch: vi.fn().mockResolvedValue("dev"),
      resolveRef: vi.fn().mockImplementation(async (_repoPath: string, ref: string) => {
        if (ref === "origin/dev" || ref === "dev") return "rev-dev-123";
        throw new Error(`unknown ref ${ref}`);
      }),
      getHeadId: vi.fn().mockResolvedValue("head-bead-456"),
      isAncestor: vi.fn().mockResolvedValue(true),
      getFinalizeCommands: vi.fn().mockReturnValue({
        stageCommand: "",
        commitCommand: "jj describe -m 'msg'",
        pushCommand: "jj git push --bookmark foreman/seed-verdict --allow-new",
        integrateTargetCommand: "jj git fetch && jj rebase -d dev@origin",
        branchVerifyCommand: "jj bookmark list foreman/seed-verdict",
        cleanCommand: "jj workspace forget foreman-seed-verdict",
        restoreTrackedStateCommand: "true",
      }),
    };

    const phases = [
      { name: "developer", artifact: "DEVELOPER_REPORT.md" },
      { name: "qa", artifact: "QA_REPORT.md", verdict: true },
      { name: "finalize", artifact: "FINALIZE_VALIDATION.md", verdict: true, retryWith: "developer", retryOnFail: 1 },
    ];

    const args = makeBasePipelineArgs(tmpDir, phases, runPhase, log) as any;
    args.config.targetBranch = "dev";
    args.config.vcsBackend = vcsBackend;

    await executePipeline(args);

    expect(log).toHaveBeenCalledWith(expect.stringContaining("expected skipped target integration because target branch was unchanged after QA"));
    expect(phaseOrder).toEqual(["developer", "qa", "finalize", "developer", "qa", "finalize"]);
  });

  it("does not retry finalize when no-drift contract fails but failure scope is classified as unrelated via analysis section", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const log = vi.fn();
    const phaseOrder: string[] = [];
    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "qa") {
        writeFileSync(
          join(tmpDir, "QA_REPORT.md"),
          "# QA\n\n## Verdict: PASS\n\n## Test Results\n- Command run: `npm test -- --reporter=dot 2>&1`\n- Test suite: 10 passed, 0 failed\n- Raw summary: 10 passed, 0 failed\n",
        );
      }
      if (phaseName === "finalize") {
        writeFileSync(
          join(tmpDir, "FINALIZE_VALIDATION.md"),
          "# Finalize Validation\n\n## Rebase\n- Status: SUCCESS\n- Note: Skipped rebase (already in place)\n\n## Test Validation\n- Status: FAIL\n- Output: unrelated test failures\n\n## Failure Scope Analysis\n\n### Classification: UNRELATED_FILES\n\n## Verdict: FAIL\n",
        );
      }
      return successResult();
    });

    const vcsBackend = {
      name: "jujutsu",
      detectDefaultBranch: vi.fn().mockResolvedValue("dev"),
      resolveRef: vi.fn().mockResolvedValue("rev-dev-same"),
      getHeadId: vi.fn().mockResolvedValue("head-bead-123"),
      isAncestor: vi.fn().mockResolvedValue(true),
      getFinalizeCommands: vi.fn().mockReturnValue({
        stageCommand: "",
        commitCommand: "jj describe -m 'msg'",
        pushCommand: "jj git push --bookmark foreman/seed-verdict --allow-new",
        integrateTargetCommand: "jj git fetch && jj rebase -d dev@origin",
        branchVerifyCommand: "jj bookmark list foreman/seed-verdict",
        cleanCommand: "jj workspace forget foreman-seed-verdict",
        restoreTrackedStateCommand: "true",
      }),
    };

    const phases = [
      { name: "developer", artifact: "DEVELOPER_REPORT.md" },
      { name: "qa", artifact: "QA_REPORT.md", verdict: true },
      { name: "finalize", artifact: "FINALIZE_VALIDATION.md", verdict: true, retryWith: "developer", retryOnFail: 1 },
    ];

    const args = makeBasePipelineArgs(tmpDir, phases, runPhase, log) as any;
    args.config.targetBranch = "dev";
    args.config.vcsBackend = vcsBackend;

    await executePipeline(args);

    expect(log).toHaveBeenCalledWith(expect.stringContaining("expected skipped target integration because target branch was unchanged after QA"));
    expect(log).toHaveBeenCalledWith(expect.stringContaining("unrelated/pre-existing test failures detected, skipping developer retry"));
    expect(phaseOrder).toEqual(["developer", "qa", "finalize"]);
  });

  it("fails finalize when target drifted but integration was marked skipped", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const log = vi.fn();
    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      if (phaseName === "qa") {
        writeFileSync(
          join(tmpDir, "QA_REPORT.md"),
          "# QA\n\n## Verdict: PASS\n\n## Test Results\n- Command run: `npm test -- --reporter=dot 2>&1`\n- Test suite: 10 passed, 0 failed\n- Raw summary: 10 passed, 0 failed\n",
        );
      }
      if (phaseName === "finalize") {
        writeFileSync(
          join(tmpDir, "FINALIZE_VALIDATION.md"),
          "# Finalize Validation\n\n## Target Integration\n- Status: SKIPPED\n\n## Test Validation\n- Status: PASS\n- Output: reran tests on drifted target\n\n## Failure Scope\n- UNKNOWN\n\n## Verdict: PASS\n",
        );
      }
      return successResult();
    });

    let resolveCount = 0;
    const vcsBackend = {
      name: "jujutsu",
      detectDefaultBranch: vi.fn().mockResolvedValue("dev"),
      resolveRef: vi.fn().mockImplementation(async (_repoPath: string, ref: string) => {
        if (ref !== "origin/dev" && ref !== "dev") throw new Error(`unknown ref ${ref}`);
        resolveCount += 1;
        return resolveCount === 1 ? "rev-dev-qa" : "rev-dev-finalize";
      }),
      getHeadId: vi.fn().mockResolvedValue("head-bead-456"),
      isAncestor: vi.fn().mockResolvedValue(false),
      getFinalizeCommands: vi.fn().mockReturnValue({
        stageCommand: "",
        commitCommand: "jj describe -m 'msg'",
        pushCommand: "jj git push --bookmark foreman/seed-verdict --allow-new",
        integrateTargetCommand: "jj git fetch && jj rebase -d dev@origin",
        branchVerifyCommand: "jj bookmark list foreman/seed-verdict",
        cleanCommand: "jj workspace forget foreman-seed-verdict",
        restoreTrackedStateCommand: "true",
      }),
    };

    const phases = [
      { name: "developer", artifact: "DEVELOPER_REPORT.md" },
      { name: "qa", artifact: "QA_REPORT.md", verdict: true },
      { name: "finalize", artifact: "FINALIZE_VALIDATION.md", verdict: true, retryWith: "developer", retryOnFail: 1 },
    ];

    const args = makeBasePipelineArgs(tmpDir, phases, runPhase, log) as any;
    args.config.targetBranch = "dev";
    args.config.vcsBackend = vcsBackend;

    await executePipeline(args);

    expect(log).toHaveBeenCalledWith(expect.stringContaining("target integration was skipped even though target branch drifted after QA"));
  });

  it("fails finalize when drifted target revision is not actually contained in finalized head", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const log = vi.fn();
    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      if (phaseName === "qa") {
        writeFileSync(
          join(tmpDir, "QA_REPORT.md"),
          "# QA\n\n## Verdict: PASS\n\n## Test Results\n- Command run: `npm test -- --reporter=dot 2>&1`\n- Test suite: 10 passed, 0 failed\n- Raw summary: 10 passed, 0 failed\n",
        );
      }
      if (phaseName === "finalize") {
        writeFileSync(
          join(tmpDir, "FINALIZE_VALIDATION.md"),
          "# Finalize Validation\n\n## Target Integration\n- Status: SUCCESS\n\n## Test Validation\n- Status: PASS\n- Output: looked good\n\n## Failure Scope\n- UNKNOWN\n\n## Verdict: PASS\n",
        );
      }
      return successResult();
    });

    let resolveCount = 0;
    const vcsBackend = {
      name: "jujutsu",
      detectDefaultBranch: vi.fn().mockResolvedValue("dev"),
      resolveRef: vi.fn().mockImplementation(async (_repoPath: string, ref: string) => {
        if (ref !== "origin/dev" && ref !== "dev") throw new Error(`unknown ref ${ref}`);
        resolveCount += 1;
        return resolveCount === 1 ? "rev-dev-qa" : "rev-dev-finalize";
      }),
      getHeadId: vi.fn().mockResolvedValue("head-bead-456"),
      isAncestor: vi.fn().mockResolvedValue(false),
      getFinalizeCommands: vi.fn().mockReturnValue({
        stageCommand: "",
        commitCommand: "jj describe -m 'msg'",
        pushCommand: "jj git push --bookmark foreman/seed-verdict --allow-new",
        integrateTargetCommand: "jj git fetch && jj rebase -d dev@origin",
        branchVerifyCommand: "jj bookmark list foreman/seed-verdict",
        cleanCommand: "jj workspace forget foreman-seed-verdict",
        restoreTrackedStateCommand: "true",
      }),
    };

    const phases = [
      { name: "developer", artifact: "DEVELOPER_REPORT.md" },
      { name: "qa", artifact: "QA_REPORT.md", verdict: true },
      { name: "finalize", artifact: "FINALIZE_VALIDATION.md", verdict: true, retryWith: "developer", retryOnFail: 1 },
    ];

    const args = makeBasePipelineArgs(tmpDir, phases, runPhase, log) as any;
    args.config.targetBranch = "dev";
    args.config.vcsBackend = vcsBackend;

    await executePipeline(args);

    expect(log).toHaveBeenCalledWith(expect.stringContaining("finalized branch does not contain the drifted target revision"));
  });
});
