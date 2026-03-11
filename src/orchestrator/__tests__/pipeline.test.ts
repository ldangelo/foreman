import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, existsSync, readFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { rmSync } from "node:fs";

// ── Mock SDK ────────────────────────────────────────────────────────────

// We mock the SDK query() to avoid spawning real Claude sessions.
// Each test configures mockQueryResults to control phase outcomes.

type MockPhaseOutcome = {
  success: boolean;
  error?: string;
};

let mockQueryResults: MockPhaseOutcome[] = [];
let mockQueryCallIndex = 0;
let capturedPrompts: string[] = [];
let capturedModels: string[] = [];

vi.mock("@anthropic-ai/claude-agent-sdk", () => ({
  query: vi.fn(({ prompt, options }: { prompt: string; options: { model: string } }) => {
    capturedPrompts.push(prompt);
    capturedModels.push(options.model);

    const idx = mockQueryCallIndex++;
    const outcome = mockQueryResults[idx] ?? { success: true };

    // Return an async generator that yields a single result message
    return (async function* () {
      if (outcome.success) {
        yield {
          type: "result",
          subtype: "success",
          total_cost_usd: 0.01,
          num_turns: 3,
          usage: { input_tokens: 1000, output_tokens: 500 },
          duration_ms: 5000,
        };
      } else {
        yield {
          type: "result",
          subtype: "error",
          total_cost_usd: 0.005,
          num_turns: 1,
          usage: { input_tokens: 200, output_tokens: 50 },
          duration_ms: 1000,
          errors: [outcome.error ?? "mock error"],
        };
      }
    })();
  }),
}));

// ── Import after mock ──────────────────────────────────────────────────

import { runPipeline, type PipelineConfig } from "../pipeline.js";

// ── Mock store ─────────────────────────────────────────────────────────

function makeMockStore() {
  return {
    updateRunProgress: vi.fn(),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
  } as any;
}

function makeProgress() {
  return {
    toolCalls: 0,
    toolBreakdown: {},
    filesChanged: [],
    turns: 0,
    costUsd: 0,
    tokensIn: 0,
    tokensOut: 0,
    lastToolCall: null,
    lastActivity: new Date().toISOString(),
  };
}

// ── Helpers ─────────────────────────────────────────────────────────────

let tempDir: string;

function makeTempDir(): string {
  return mkdtempSync(join(tmpdir(), "pipeline-test-"));
}

function makeConfig(overrides: Partial<PipelineConfig> = {}): PipelineConfig {
  return {
    runId: "run-001",
    projectId: "proj-001",
    beadId: "bead-123",
    beadTitle: "Fix auth module",
    beadDescription: "Fix JWT token refresh",
    model: "claude-sonnet-4-6",
    worktreePath: tempDir,
    env: {},
    logFile: join(tempDir, "pipeline.log"),
    ...overrides,
  };
}

beforeEach(() => {
  tempDir = makeTempDir();
  mockQueryCallIndex = 0;
  mockQueryResults = [];
  capturedPrompts = [];
  capturedModels = [];
  vi.clearAllMocks();
});

afterEach(() => {
  rmSync(tempDir, { recursive: true, force: true });
});

// ── Tests ───────────────────────────────────────────────────────────────

describe("runPipeline", () => {
  describe("happy path", () => {
    it("runs all 5 phases when all succeed", async () => {
      // explorer, developer, qa, reviewer, finalize — all pass
      mockQueryResults = [
        { success: true },
        { success: true },
        { success: true },
        { success: true },
        { success: true },
      ];

      // QA needs a PASS verdict file
      // The QA agent would normally write this, but since we mock the SDK,
      // we write it ourselves before the reviewer phase reads it.
      // We do this by writing the QA_REPORT before running.
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS\nAll tests pass");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS\nLooks good");

      const store = makeMockStore();
      const progress = makeProgress();

      await runPipeline(makeConfig(), store, progress);

      // 5 SDK calls: explorer, developer, qa, reviewer, finalize
      expect(capturedPrompts).toHaveLength(5);
      expect(capturedPrompts[0]).toContain("Explorer");
      expect(capturedPrompts[1]).toContain("Developer");
      expect(capturedPrompts[2]).toContain("QA Agent");
      expect(capturedPrompts[3]).toContain("Reviewer");
      expect(capturedPrompts[4]).toContain("finalizer");

      // Should mark run as completed
      expect(store.updateRun).toHaveBeenCalledWith("run-001", expect.objectContaining({
        status: "completed",
      }));

      // Should log a "complete" event
      expect(store.logEvent).toHaveBeenCalledWith("proj-001", "complete", expect.objectContaining({
        beadId: "bead-123",
        pipeline: true,
      }), "run-001");
    });

    it("accumulates costs across all phases", async () => {
      mockQueryResults = Array(5).fill({ success: true });
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS");

      const store = makeMockStore();
      const progress = makeProgress();

      await runPipeline(makeConfig(), store, progress);

      // Each phase costs $0.01, 5 phases total
      expect(progress.costUsd).toBeCloseTo(0.05, 4);
      expect(progress.turns).toBe(15);  // 3 turns × 5 phases
      expect(progress.tokensIn).toBe(5000);  // 1000 × 5
      expect(progress.tokensOut).toBe(2500);  // 500 × 5
    });
  });

  describe("skip options", () => {
    it("skips explorer when skipExplore is set", async () => {
      // developer, qa, reviewer, finalize (no explorer)
      mockQueryResults = Array(4).fill({ success: true });
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS");

      const store = makeMockStore();
      const progress = makeProgress();

      await runPipeline(makeConfig({ skipExplore: true }), store, progress);

      expect(capturedPrompts).toHaveLength(4);
      expect(capturedPrompts[0]).toContain("Developer");
      expect(capturedPrompts[0]).not.toContain("Explorer");
    });

    it("skips reviewer when skipReview is set", async () => {
      // explorer, developer, qa, finalize (no reviewer)
      mockQueryResults = Array(4).fill({ success: true });
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");

      const store = makeMockStore();
      const progress = makeProgress();

      await runPipeline(makeConfig({ skipReview: true }), store, progress);

      expect(capturedPrompts).toHaveLength(4);
      expect(capturedPrompts.some(p => p.includes("Reviewer"))).toBe(false);
    });

    it("skips both explorer and reviewer", async () => {
      // developer, qa, finalize only
      mockQueryResults = Array(3).fill({ success: true });
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");

      const store = makeMockStore();
      const progress = makeProgress();

      await runPipeline(makeConfig({ skipExplore: true, skipReview: true }), store, progress);

      expect(capturedPrompts).toHaveLength(3);
      expect(capturedPrompts[0]).toContain("Developer");
      expect(capturedPrompts[1]).toContain("QA Agent");
      expect(capturedPrompts[2]).toContain("finalizer");
    });
  });

  describe("explorer failure (non-fatal)", () => {
    it("continues pipeline when explorer fails", async () => {
      // explorer fails, but developer, qa, reviewer, finalize succeed
      mockQueryResults = [
        { success: false, error: "explorer crashed" },
        { success: true },  // developer
        { success: true },  // qa
        { success: true },  // reviewer
        { success: true },  // finalize
      ];
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS");

      const store = makeMockStore();
      const progress = makeProgress();

      await runPipeline(makeConfig(), store, progress);

      // Pipeline should still complete
      expect(store.updateRun).toHaveBeenCalledWith("run-001", expect.objectContaining({
        status: "completed",
      }));
      // All 5 phases should run
      expect(capturedPrompts).toHaveLength(5);
    });
  });

  describe("developer failure (fatal)", () => {
    it("fails pipeline when developer crashes", async () => {
      mockQueryResults = [
        { success: true },  // explorer
        { success: false, error: "developer OOM" },  // developer
      ];

      const store = makeMockStore();
      const progress = makeProgress();

      await runPipeline(makeConfig(), store, progress);

      // Pipeline should fail
      expect(store.updateRun).toHaveBeenCalledWith("run-001", expect.objectContaining({
        status: "failed",
      }));
      expect(store.logEvent).toHaveBeenCalledWith("proj-001", "fail", expect.objectContaining({
        beadId: "bead-123",
        reason: "developer OOM",
      }), "run-001");

      // Should not proceed to QA
      expect(capturedPrompts).toHaveLength(2);
    });
  });

  describe("QA failure triggers developer retry", () => {
    it("retries developer when QA verdict is FAIL (exhausts retries)", async () => {
      // Since mock SDK doesn't rewrite QA_REPORT.md, the FAIL verdict persists.
      // This means developer retries until MAX_DEVELOPER_RETRIES, then falls through.
      // Pipeline: explorer, dev(0), qa(0)→FAIL, dev(1), qa(1)→FAIL, dev(2), qa(2)→FAIL,
      //           reviewer, finalize = 9 calls
      mockQueryResults = Array(9).fill({ success: true });
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: FAIL\n## Issues\n- test.ts:5 — assertion error");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS");

      const store = makeMockStore();
      const progress = makeProgress();

      await runPipeline(makeConfig(), store, progress);

      // Developer called 3 times (initial + 2 retries)
      const devCalls = capturedPrompts.filter(p => p.startsWith("# Developer Agent"));
      expect(devCalls.length).toBe(3);

      // Retry prompts should include feedback context
      const retryPrompt = devCalls[1];
      expect(retryPrompt).toContain("Previous Feedback");
      expect(retryPrompt).toContain("QA found issues");
    });

    it("retries developer when QA agent crashes", async () => {
      // QA crashes on first attempt, triggering retry.
      // On retry, QA succeeds and reads the PASS verdict file.
      // Pipeline: explorer, dev(0), qa(0)→crash, dev(1), qa(1)→PASS, reviewer, finalize = 7
      mockQueryResults = [
        { success: true },  // explorer
        { success: true },  // developer (attempt 0)
        { success: false, error: "QA timeout" },  // qa crashes
        { success: true },  // developer (retry 1)
        { success: true },  // qa (retry 1) — succeeds, reads PASS
        { success: true },  // reviewer
        { success: true },  // finalize
      ];
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS");

      const store = makeMockStore();
      const progress = makeProgress();

      await runPipeline(makeConfig(), store, progress);

      // Developer called twice (initial + 1 retry after crash)
      const devCalls = capturedPrompts.filter(p => p.startsWith("# Developer Agent"));
      expect(devCalls.length).toBe(2);
      expect(devCalls[1]).toContain("QA agent crashed");
    });
  });

  describe("reviewer failure triggers developer retry", () => {
    it("retries developer when reviewer verdict is FAIL (exhausts retries)", async () => {
      // REVIEW.md stays FAIL throughout (mock SDK doesn't rewrite it).
      // Pipeline: explorer, dev(0), qa(0), rev(0)→FAIL, dev(1), qa(1), rev(1)→FAIL,
      //           dev(2), qa(2), rev(2)→FAIL (no more retries, falls through), finalize = 11
      mockQueryResults = Array(11).fill({ success: true });

      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: FAIL\n## Issues\n- **[CRITICAL]** auth.ts:10 — SQL injection");

      const store = makeMockStore();
      const progress = makeProgress();

      await runPipeline(makeConfig(), store, progress);

      const devCalls = capturedPrompts.filter(p => p.startsWith("# Developer Agent"));
      expect(devCalls.length).toBe(3);  // initial + 2 retries

      // Retry feedback should reference the review issues
      const retryPrompt = devCalls[1];
      expect(retryPrompt).toContain("Previous Feedback");
      expect(retryPrompt).toContain("Code review found issues");
      expect(retryPrompt).toContain("auth.ts:10");
    });

    it("reviewer crash is non-fatal — proceeds to finalize", async () => {
      mockQueryResults = [
        { success: true },  // explorer
        { success: true },  // developer
        { success: true },  // qa
        { success: false, error: "reviewer crashed" },  // reviewer
        { success: true },  // finalize
      ];
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");

      const store = makeMockStore();
      const progress = makeProgress();

      await runPipeline(makeConfig(), store, progress);

      // Should still complete
      expect(store.updateRun).toHaveBeenCalledWith("run-001", expect.objectContaining({
        status: "completed",
      }));
    });
  });

  describe("max retries exhausted", () => {
    it("proceeds to finalize after MAX_DEVELOPER_RETRIES (2)", async () => {
      // QA keeps failing — developer retries twice, then gives up and finalizes.
      // Pipeline: explorer, dev(0), qa(0)→FAIL, dev(1), qa(1)→FAIL, dev(2), qa(2)→FAIL,
      //           reviewer, finalize = 9 calls
      mockQueryResults = Array(9).fill({ success: true });
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: FAIL\n## Issues\n- persistent failure");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS");

      const store = makeMockStore();
      const progress = makeProgress();

      await runPipeline(makeConfig(), store, progress);

      // Developer should have been called 3 times (initial + 2 retries)
      const devCalls = capturedPrompts.filter(p => p.startsWith("# Developer Agent"));
      expect(devCalls.length).toBe(3);

      // QA should also have been called 3 times
      const qaCalls = capturedPrompts.filter(p => p.startsWith("# QA Agent"));
      expect(qaCalls.length).toBe(3);

      // Log event should record number of retries
      expect(store.logEvent).toHaveBeenCalledWith("proj-001", "complete", expect.objectContaining({
        retries: expect.any(Number),
      }), "run-001");
    });
  });

  describe("finalize failure", () => {
    it("marks pipeline as failed when finalize crashes", async () => {
      mockQueryResults = [
        { success: true },  // explorer
        { success: true },  // developer
        { success: true },  // qa
        { success: true },  // reviewer
        { success: false, error: "git push failed" },  // finalize
      ];
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS");

      const store = makeMockStore();
      const progress = makeProgress();

      await runPipeline(makeConfig(), store, progress);

      expect(store.updateRun).toHaveBeenCalledWith("run-001", expect.objectContaining({
        status: "failed",
      }));
      expect(store.logEvent).toHaveBeenCalledWith("proj-001", "fail", expect.objectContaining({
        reason: "git push failed",
      }), "run-001");
    });
  });

  describe("model selection", () => {
    it("uses haiku for explorer", async () => {
      mockQueryResults = [{ success: true }, { success: true }, { success: true }, { success: true }, { success: true }];
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS");

      const store = makeMockStore();
      await runPipeline(makeConfig(), store, makeProgress());

      expect(capturedModels[0]).toBe("claude-haiku-4-5-20251001");  // explorer
    });

    it("uses sonnet for developer by default", async () => {
      mockQueryResults = Array(5).fill({ success: true });
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS");

      const store = makeMockStore();
      await runPipeline(makeConfig(), store, makeProgress());

      expect(capturedModels[1]).toBe("claude-sonnet-4-6");  // developer
    });

    it("upgrades developer to opus for complex tasks", async () => {
      mockQueryResults = Array(5).fill({ success: true });
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS");

      const store = makeMockStore();
      await runPipeline(
        makeConfig({ beadTitle: "Refactor auth module", beadDescription: "Major overhaul" }),
        store,
        makeProgress(),
      );

      expect(capturedModels[1]).toBe("claude-opus-4-6");  // developer upgraded
    });

    it("uses opus for developer when base model is opus", async () => {
      mockQueryResults = Array(5).fill({ success: true });
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS");

      const store = makeMockStore();
      await runPipeline(
        makeConfig({ model: "claude-opus-4-6" }),
        store,
        makeProgress(),
      );

      expect(capturedModels[1]).toBe("claude-opus-4-6");  // developer uses forced opus
    });

    it("uses haiku for finalize (cheap commit/push)", async () => {
      mockQueryResults = Array(5).fill({ success: true });
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS");

      const store = makeMockStore();
      await runPipeline(makeConfig(), store, makeProgress());

      const lastModel = capturedModels[capturedModels.length - 1];
      expect(lastModel).toBe("claude-haiku-4-5-20251001");  // finalize
    });
  });

  describe("explorer report detection", () => {
    it("developer prompt references EXPLORER_REPORT when it exists", async () => {
      mockQueryResults = Array(5).fill({ success: true });
      writeFileSync(join(tempDir, "EXPLORER_REPORT.md"), "# Explorer findings");
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS");

      const store = makeMockStore();
      await runPipeline(makeConfig(), store, makeProgress());

      const devPrompt = capturedPrompts.find(p => p.includes("Developer"));
      expect(devPrompt).toContain("EXPLORER_REPORT.md");
    });

    it("developer prompt adapts when no explorer report exists", async () => {
      // Skip explorer, so no EXPLORER_REPORT.md
      mockQueryResults = Array(4).fill({ success: true });
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS");

      const store = makeMockStore();
      await runPipeline(makeConfig({ skipExplore: true }), store, makeProgress());

      const devPrompt = capturedPrompts.find(p => p.includes("Developer"));
      expect(devPrompt).toContain("Explore the codebase");
    });
  });

  describe("store progress tracking", () => {
    it("calls updateRunProgress at each phase boundary", async () => {
      mockQueryResults = Array(5).fill({ success: true });
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS");

      const store = makeMockStore();
      await runPipeline(makeConfig(), store, makeProgress());

      // At minimum: explorer start + end, developer start + end, qa start + end,
      // reviewer start + end, finalize start + end = many calls
      expect(store.updateRunProgress.mock.calls.length).toBeGreaterThanOrEqual(8);
    });

    it("progress.lastToolCall tracks current phase", async () => {
      mockQueryResults = Array(5).fill({ success: true });
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS");

      const store = makeMockStore();
      await runPipeline(makeConfig(), store, makeProgress());

      // Collect all lastToolCall values from updateRunProgress calls
      const toolCalls = store.updateRunProgress.mock.calls
        .map(([, p]: [string, any]) => p.lastToolCall)
        .filter(Boolean);

      expect(toolCalls).toContain("explorer:start");
      expect(toolCalls).toContain("developer:start");
      expect(toolCalls).toContain("qa:start");
      expect(toolCalls).toContain("reviewer:start");
      expect(toolCalls).toContain("finalize:start");
    });
  });

  describe("log file", () => {
    it("creates log file with pipeline output", async () => {
      mockQueryResults = Array(5).fill({ success: true });
      writeFileSync(join(tempDir, "QA_REPORT.md"), "## Verdict: PASS");
      writeFileSync(join(tempDir, "REVIEW.md"), "## Verdict: PASS");

      const store = makeMockStore();
      await runPipeline(makeConfig(), store, makeProgress());

      const logContent = readFileSync(join(tempDir, "pipeline.log"), "utf-8");
      expect(logContent).toContain("[pipeline] Starting pipeline for bead-123");
      expect(logContent).toContain("[explorer]");
      expect(logContent).toContain("[developer]");
      expect(logContent).toContain("[qa]");
      expect(logContent).toContain("[reviewer]");
      expect(logContent).toContain("[finalize]");
    });
  });
});
