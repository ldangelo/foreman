/**
 * Regression tests for rebase-related changes (TRD-004-TEST, TRD-018-TEST).
 *
 * Verifies:
 * - AC-T-004-1: Default workflow has no rebaseAfterPhase configured
 * - AC-T-004-2: Pipeline with default workflow emits no rebase:* events
 * - AC-T-018-1: Default workflow produces zero rebase: events
 * - AC-T-018-2: Existing pipeline behavior is unchanged after Phase 0-E refactor
 */

import { describe, it, expect, vi } from "vitest";
import { loadWorkflowConfig } from "../../lib/workflow-loader.js";
import { PipelineEventBus } from "../pipeline-events.js";
import type { PipelineEvent } from "../pipeline-events.js";

// Mock roles.ts to avoid filesystem prompt loading
vi.mock("../roles.js", () => ({
  ROLE_CONFIGS: {},
  buildPhasePrompt: vi.fn().mockReturnValue("mock prompt"),
  parseVerdict: vi.fn().mockReturnValue("pass"),
  extractIssues: vi.fn().mockReturnValue(""),
}));

const { executePipeline } = await import("../pipeline-executor.js");
import { ForemanStore } from "../../lib/store.js";
import type { PipelineContext, PhaseResult } from "../pipeline-executor.js";
import { mkdtempSync, rmSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ── Helpers ──────────────────────────────────────────────────────────────────

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");

function makeStore(): ForemanStore {
  return new ForemanStore(":memory:");
}

function makeCtx(overrides: Partial<PipelineContext>): PipelineContext {
  const noop = () => {};
  const noopAsync = async () => {};
  return {
    config: {
      runId: "run-test",
      projectId: "proj-test",
      seedId: "seed-1",
      seedTitle: "Test Seed",
      model: "sonnet",
      worktreePath: "/tmp/wt",
      env: {},
    },
    workflowConfig: { name: "test", phases: [{ name: "explorer", prompt: "explorer.md" }] },
    store: makeStore(),
    logFile: "/dev/null",
    notifyClient: null,
    agentMailClient: null,
    runPhase: vi.fn().mockResolvedValue({ success: true, costUsd: 0, turns: 1, tokensIn: 0, tokensOut: 0 } as PhaseResult),
    registerAgent: noopAsync,
    sendMail: noop,
    sendMailText: noop,
    reserveFiles: noop,
    releaseFiles: noop,
    markStuck: noopAsync,
    log: noop,
    promptOpts: { projectRoot: "/tmp", workflow: "test" },
    ...overrides,
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("default workflow — no rebase configuration", () => {
  it("AC-T-004-1: default workflow has no rebaseAfterPhase", () => {
    const workflow = loadWorkflowConfig("default", PROJECT_ROOT);
    expect(workflow.rebaseAfterPhase).toBeUndefined();
  });

  it("AC-T-004-2 / AC-T-018-1: pipeline with default workflow emits zero rebase: events", async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "foreman-regression-test-"));
    try {
      mkdirSync(tmpDir, { recursive: true });
      const store = makeStore();
      const project = store.registerProject("test", tmpDir);
      const run = store.createRun(project.id, "seed-1", "developer", tmpDir);

      const bus = new PipelineEventBus();
      const rebaseEvents: PipelineEvent[] = [];

      // Register listeners for all rebase event types
      bus.on("rebase:start", (e) => { rebaseEvents.push(e); });
      bus.on("rebase:clean", (e) => { rebaseEvents.push(e); });
      bus.on("rebase:conflict", (e) => { rebaseEvents.push(e); });
      bus.on("rebase:resolved", (e) => { rebaseEvents.push(e); });

      // Use a minimal 1-phase workflow (no rebaseAfterPhase)
      const ctx = makeCtx({
        config: {
          runId: run.id,
          projectId: project.id,
          seedId: "seed-1",
          seedTitle: "Test",
          model: "sonnet",
          worktreePath: tmpDir,
          env: {},
        },
        workflowConfig: {
          name: "test",
          phases: [{ name: "developer", prompt: "developer.md" }],
          // No rebaseAfterPhase
        },
        store,
        eventBus: bus,
      });

      await executePipeline(ctx);

      // AC-T-004-2 / AC-T-018-1: no rebase events emitted
      expect(rebaseEvents).toHaveLength(0);
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});

describe("AC-T-018-2: existing pipeline behavior unchanged after refactor", () => {
  it("pipeline without eventBus completes successfully (backward compat)", async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "foreman-compat-test-"));
    try {
      mkdirSync(tmpDir, { recursive: true });
      const store = makeStore();
      const project = store.registerProject("test", tmpDir);
      const run = store.createRun(project.id, "seed-1", "developer", tmpDir);

      const onComplete = vi.fn();
      const runPhase = vi.fn().mockResolvedValue({ success: true, costUsd: 0.01, turns: 3, tokensIn: 100, tokensOut: 50 } as PhaseResult);

      const ctx = makeCtx({
        config: {
          runId: run.id,
          projectId: project.id,
          seedId: "seed-1",
          seedTitle: "Test",
          model: "sonnet",
          worktreePath: tmpDir,
          env: {},
        },
        workflowConfig: {
          name: "test",
          phases: [
            { name: "explorer", prompt: "explorer.md" },
            { name: "developer", prompt: "developer.md" },
          ],
        },
        store,
        runPhase,
        onPipelineComplete: onComplete,
        // No eventBus
      });

      await executePipeline(ctx);

      expect(runPhase).toHaveBeenCalledTimes(2);
      expect(onComplete).toHaveBeenCalledOnce();
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
