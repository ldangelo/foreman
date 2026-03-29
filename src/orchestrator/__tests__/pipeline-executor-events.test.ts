/**
 * Tests for pipeline-executor.ts event emission (TRD-002-TEST).
 *
 * Verifies:
 * - AC-T-002-1: phase:start fires before each phase, phase:complete after
 * - AC-T-002-2: phase:fail + pipeline:fail emitted on phase failure
 * - AC-T-002-3: existing pipeline behavior unchanged (no-regression)
 * - AC-T-002-4: handler errors don't block subsequent phases
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { PipelineEventBus } from "../pipeline-events.js";
import type { PipelineEvent } from "../pipeline-events.js";
import type { PipelineContext, PhaseResult } from "../pipeline-executor.js";
import type { WorkflowConfig } from "../../lib/workflow-loader.js";
import { ForemanStore } from "../../lib/store.js";

// Mock roles.ts so buildPhasePrompt never hits the filesystem
vi.mock("../roles.js", () => ({
  ROLE_CONFIGS: {},
  buildPhasePrompt: vi.fn().mockReturnValue("mock prompt"),
  parseVerdict: vi.fn().mockReturnValue("pass"),
  extractIssues: vi.fn().mockReturnValue(""),
}));

// Import after mocking
const { executePipeline } = await import("../pipeline-executor.js");

// ── Helpers ──────────────────────────────────────────────────────────────────

function makeTmpDir(): string {
  return mkdtempSync(join(tmpdir(), "foreman-pe-events-test-"));
}

function makeStore(): ForemanStore {
  return new ForemanStore(":memory:");
}

function makeWorkflow(phaseNames: string[]): WorkflowConfig {
  return {
    name: "test",
    phases: phaseNames.map((name) => ({
      name,
      prompt: `${name}.md`,
      skipIfArtifact: undefined,
      artifact: `${name.toUpperCase()}_REPORT.md`,
    })),
  };
}

function makeSuccessPhaseResult(): PhaseResult {
  return { success: true, costUsd: 0.01, turns: 5, tokensIn: 100, tokensOut: 50 };
}

function makeFailPhaseResult(error = "phase error"): PhaseResult {
  return { success: false, costUsd: 0, turns: 1, tokensIn: 10, tokensOut: 0, error };
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
    workflowConfig: makeWorkflow(["explorer", "developer"]),
    store: makeStore(),
    logFile: "/dev/null",
    notifyClient: null,
    agentMailClient: null,
    runPhase: vi.fn().mockResolvedValue(makeSuccessPhaseResult()),
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

describe("pipeline-executor — event emission", () => {
  let tmpDir: string;

  // Each test uses a temp dir for worktree path (not actually needed but good practice)
  beforeEach(() => {
    tmpDir = makeTmpDir();
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("AC-T-002-1: phase:start fires before each phase, phase:complete fires after", async () => {
    const bus = new PipelineEventBus();
    const events: PipelineEvent[] = [];

    bus.on("phase:start", (e) => { events.push(e); });
    bus.on("phase:complete", (e) => { events.push(e); });
    bus.on("pipeline:complete", (e) => { events.push(e); });

    const store = makeStore();
    const project = store.registerProject("test", tmpDir);
    const run = store.createRun(project.id, "seed-1", "developer", tmpDir);

    const runPhase = vi.fn().mockResolvedValue(makeSuccessPhaseResult());
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
      workflowConfig: makeWorkflow(["explorer", "developer"]),
      store,
      runPhase,
      eventBus: bus,
    });

    await executePipeline(ctx);

    const types = events.map((e) => e.type);
    // Expected: phase:start(explorer), phase:complete(explorer),
    //           phase:start(developer), phase:complete(developer),
    //           pipeline:complete
    expect(types[0]).toBe("phase:start");
    expect((events[0] as Extract<PipelineEvent, {type: "phase:start"}>).phase).toBe("explorer");
    expect(types[1]).toBe("phase:complete");
    expect((events[1] as Extract<PipelineEvent, {type: "phase:complete"}>).phase).toBe("explorer");
    expect(types[2]).toBe("phase:start");
    expect((events[2] as Extract<PipelineEvent, {type: "phase:start"}>).phase).toBe("developer");
    expect(types[3]).toBe("phase:complete");
    expect(types[4]).toBe("pipeline:complete");
  });

  it("AC-T-002-2: phase:fail and pipeline:fail emitted on phase failure", async () => {
    const bus = new PipelineEventBus();
    const events: PipelineEvent[] = [];

    bus.on("phase:start", (e) => { events.push(e); });
    bus.on("phase:fail", (e) => { events.push(e); });
    bus.on("pipeline:fail", (e) => { events.push(e); });

    const store = makeStore();
    const project = store.registerProject("test", tmpDir + "-fail");
    mkdirSync(tmpDir + "-fail", { recursive: true });
    const run = store.createRun(project.id, "seed-1", "developer", tmpDir + "-fail");

    const runPhase = vi.fn().mockResolvedValue(makeFailPhaseResult("explorer blew up"));
    const ctx = makeCtx({
      config: {
        runId: run.id,
        projectId: project.id,
        seedId: "seed-1",
        seedTitle: "Test",
        model: "sonnet",
        worktreePath: tmpDir + "-fail",
        env: {},
      },
      workflowConfig: makeWorkflow(["explorer"]),
      store,
      runPhase,
      eventBus: bus,
    });

    await executePipeline(ctx);

    const failEvent = events.find((e) => e.type === "phase:fail");
    expect(failEvent).toBeDefined();
    const pf = failEvent as Extract<PipelineEvent, {type: "phase:fail"}>;
    expect(pf.phase).toBe("explorer");
    expect(pf.error).toContain("explorer blew up");
    expect(pf.retryable).toBe(true);

    const pipelineFailEvent = events.find((e) => e.type === "pipeline:fail");
    expect(pipelineFailEvent).toBeDefined();
  });

  it("AC-T-002-4: handler error does not block next phase", async () => {
    const bus = new PipelineEventBus();
    const phasesStarted: string[] = [];

    // First phase:complete handler throws — should not block second phase:start
    let firstComplete = true;
    bus.on("phase:complete", () => {
      if (firstComplete) {
        firstComplete = false;
        throw new Error("handler exploded");
      }
    });
    bus.on("phase:start", (e) => { phasesStarted.push(e.phase); });

    const store = makeStore();
    const project = store.registerProject("test", tmpDir + "-handler");
    mkdirSync(tmpDir + "-handler", { recursive: true });
    const run = store.createRun(project.id, "seed-1", "developer", tmpDir + "-handler");

    const runPhase = vi.fn().mockResolvedValue(makeSuccessPhaseResult());
    const ctx = makeCtx({
      config: {
        runId: run.id,
        projectId: project.id,
        seedId: "seed-1",
        seedTitle: "Test",
        model: "sonnet",
        worktreePath: tmpDir + "-handler",
        env: {},
      },
      workflowConfig: makeWorkflow(["phase-a", "phase-b"]),
      store,
      runPhase,
      eventBus: bus,
    });

    // Should not throw despite handler error
    await expect(executePipeline(ctx)).resolves.not.toThrow();

    // Both phases should have been started
    expect(phasesStarted).toContain("phase-a");
    expect(phasesStarted).toContain("phase-b");
  });

  it("AC-T-002-3: pipeline works correctly without eventBus (backward compat)", async () => {
    const store = makeStore();
    const project = store.registerProject("test", tmpDir + "-nobus");
    mkdirSync(tmpDir + "-nobus", { recursive: true });
    const run = store.createRun(project.id, "seed-1", "developer", tmpDir + "-nobus");

    const onComplete = vi.fn();
    const runPhase = vi.fn().mockResolvedValue(makeSuccessPhaseResult());
    const ctx = makeCtx({
      config: {
        runId: run.id,
        projectId: project.id,
        seedId: "seed-1",
        seedTitle: "Test",
        model: "sonnet",
        worktreePath: tmpDir + "-nobus",
        env: {},
      },
      workflowConfig: makeWorkflow(["explorer"]),
      store,
      runPhase,
      onPipelineComplete: onComplete,
      // No eventBus — should work exactly as before
    });

    await executePipeline(ctx);

    expect(runPhase).toHaveBeenCalledOnce();
    expect(onComplete).toHaveBeenCalledOnce();
  });
});
