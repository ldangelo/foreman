import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { installBundledPrompts } from "../../lib/prompt-loader.js";

const successResult = {
  success: true,
  costUsd: 0.01,
  turns: 3,
  tokensIn: 100,
  tokensOut: 50,
};

describe("executePipeline command phase contract enforcement", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-command-contract-"));
    process.env["FOREMAN_HOME"] = tmpDir;
    mkdirSync(join(tmpDir, "prompts", "default"), { recursive: true });
    installBundledPrompts(tmpDir, true);
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
  });

  it("fails immediately when a command phase succeeds without its required artifact", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const markStuck = vi.fn().mockResolvedValue(undefined);
    const runPhase = vi.fn().mockResolvedValue({
      ...successResult,
      commandHonored: false,
      traceWarnings: ["Expected artifact missing: DEVELOPER_REPORT.md"],
    });

    await executePipeline({
      config: {
        runId: "run-contract-1",
        projectId: "proj-contract-1",
        taskId: "task-contract-1",
        taskTitle: "Command contract",
        model: "anthropic/claude-sonnet-4-6",
        worktreePath: tmpDir,
        env: {},
      },
      workflowConfig: {
        name: "bug",
        phases: [
          { name: "fix", command: "/ensemble:fix-issue Broken thing", artifact: "DEVELOPER_REPORT.md" },
          { name: "test", command: "/ensemble:test-issue Broken thing", artifact: "TEST_RESULTS.md" },
        ],
      } as never,
      store: {
        updateRunProgress: vi.fn(),
        logEvent: vi.fn(),
      } as never,
      logFile: join(tmpDir, "pipeline.log"),
      notifyClient: null,
      agentMailClient: null,
      runPhase,
      registerAgent: vi.fn().mockResolvedValue(undefined),
      sendMail: vi.fn(),
      sendMailText: vi.fn(),
      reserveFiles: vi.fn(),
      releaseFiles: vi.fn(),
      markStuck,
      log: vi.fn(),
      promptOpts: { projectRoot: tmpDir, workflow: "default" },
    });

    expect(runPhase).toHaveBeenCalledTimes(1);
    expect(markStuck).toHaveBeenCalledTimes(1);
    expect(markStuck.mock.calls[0]?.[7]).toContain("Command phase contract violated");
    expect(markStuck.mock.calls[0]?.[7]).toContain("Expected artifact missing: DEVELOPER_REPORT.md");
  });

  it("emits durable terminal failure events before marking a failed phase stuck", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const calls: string[] = [];
    const logEvent = vi.fn().mockImplementation(async (eventType: string) => {
      calls.push(eventType);
    });
    const markStuck = vi.fn().mockImplementation(async () => {
      calls.push("markStuck");
    });
    const runPhase = vi.fn().mockResolvedValue({
      success: false,
      costUsd: 0.01,
      turns: 30,
      tokensIn: 100,
      tokensOut: 50,
      error: "Phase exceeded maxTurns (30)",
    });

    await executePipeline({
      config: {
        runId: "run-terminal-1",
        projectId: "proj-terminal-1",
        taskId: "task-terminal-1",
        taskTitle: "Terminal event contract",
        model: "anthropic/claude-sonnet-4-6",
        worktreePath: tmpDir,
        env: {},
      },
      workflowConfig: {
        name: "bug",
        phases: [
          { name: "explorer", prompt: "explorer.md", maxTurns: 30 },
        ],
      } as never,
      store: {
        updateRunProgress: vi.fn(),
        logEvent: vi.fn(),
      } as never,
      logFile: join(tmpDir, "pipeline.log"),
      notifyClient: null,
      agentMailClient: null,
      runPhase,
      registerAgent: vi.fn().mockResolvedValue(undefined),
      sendMail: vi.fn(),
      sendMailText: vi.fn(),
      reserveFiles: vi.fn(),
      releaseFiles: vi.fn(),
      markStuck,
      log: vi.fn(),
      observabilityWriter: { logEvent },
      promptOpts: { projectRoot: tmpDir, workflow: "default" },
    });

    expect(calls.slice(-4)).toEqual(["phase-failed", "run-failed", "task-updated", "markStuck"]);
    expect(logEvent).toHaveBeenCalledWith("phase-failed", expect.objectContaining({
      run_id: "run-terminal-1",
      task_id: "task-terminal-1",
      phase: "explorer",
      reason: "Phase exceeded maxTurns (30)",
      status: "failed",
    }));
    expect(logEvent).toHaveBeenCalledWith("run-failed", expect.objectContaining({
      run_id: "run-terminal-1",
      task_id: "task-terminal-1",
      phase: "explorer",
      reason: "Phase exceeded maxTurns (30)",
      status: "failed",
    }));
    expect(logEvent).toHaveBeenCalledWith("task-updated", expect.objectContaining({
      run_id: "run-terminal-1",
      task_id: "task-terminal-1",
      phase: "explorer",
      reason: "Phase exceeded maxTurns (30)",
      status: "failed",
    }));
    expect(markStuck).toHaveBeenCalledTimes(1);
  });

  it("emits terminal failure events when a failed phase is finalized through onPipelineComplete", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const calls: string[] = [];
    const logEvent = vi.fn().mockImplementation(async (eventType: string) => {
      calls.push(eventType);
    });
    const onPipelineComplete = vi.fn().mockImplementation(async () => {
      calls.push("onPipelineComplete");
    });
    const runPhase = vi.fn().mockResolvedValue({
      success: false,
      costUsd: 0.01,
      turns: 30,
      tokensIn: 100,
      tokensOut: 50,
      error: "Phase exceeded maxTurns (30)",
    });

    await executePipeline({
      config: {
        runId: "run-terminal-2",
        projectId: "proj-terminal-2",
        taskId: "task-terminal-2",
        taskTitle: "Terminal event callback contract",
        model: "anthropic/claude-sonnet-4-6",
        worktreePath: tmpDir,
        env: {},
      },
      workflowConfig: {
        name: "bug",
        phases: [
          { name: "explorer", prompt: "explorer.md", maxTurns: 30 },
        ],
      } as never,
      store: {
        updateRunProgress: vi.fn(),
        logEvent: vi.fn(),
      } as never,
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
      log: vi.fn(),
      observabilityWriter: { logEvent },
      onPipelineComplete,
      promptOpts: { projectRoot: tmpDir, workflow: "default" },
    });

    expect(calls.slice(-4)).toEqual(["phase-failed", "run-failed", "task-updated", "onPipelineComplete"]);
    expect(logEvent).toHaveBeenCalledWith("phase-failed", expect.objectContaining({
      run_id: "run-terminal-2",
      task_id: "task-terminal-2",
      phase: "explorer",
      reason: "Phase exceeded maxTurns (30)",
      status: "failed",
    }));
    expect(logEvent).toHaveBeenCalledWith("run-failed", expect.objectContaining({
      run_id: "run-terminal-2",
      task_id: "task-terminal-2",
      phase: "explorer",
      reason: "Phase exceeded maxTurns (30)",
      status: "failed",
    }));
    expect(logEvent).toHaveBeenCalledWith("task-updated", expect.objectContaining({
      run_id: "run-terminal-2",
      task_id: "task-terminal-2",
      phase: "explorer",
      reason: "Phase exceeded maxTurns (30)",
      status: "failed",
    }));
    expect(onPipelineComplete).toHaveBeenCalledWith(expect.objectContaining({ success: false }));
  });

  it("fails immediately when a command phase attempts git commit outside finalize", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const markStuck = vi.fn().mockResolvedValue(undefined);
    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      if (phaseName === "fix") {
        writeFileSync(join(tmpDir, "DEVELOPER_REPORT.md"), "# done\n");
        return {
          ...successResult,
          commandHonored: false,
          traceWarnings: ["Blocked git commit during non-finalize phase"],
        };
      }
      return successResult;
    });

    await executePipeline({
      config: {
        runId: "run-contract-2",
        projectId: "proj-contract-2",
        taskId: "task-contract-2",
        taskTitle: "Command contract",
        model: "anthropic/claude-sonnet-4-6",
        worktreePath: tmpDir,
        env: {},
      },
      workflowConfig: {
        name: "bug",
        phases: [
          { name: "fix", command: "/ensemble:fix-issue Broken thing", artifact: "DEVELOPER_REPORT.md" },
          { name: "test", command: "/ensemble:test-issue Broken thing", artifact: "TEST_RESULTS.md" },
        ],
      } as never,
      store: {
        updateRunProgress: vi.fn(),
        logEvent: vi.fn(),
      } as never,
      logFile: join(tmpDir, "pipeline.log"),
      notifyClient: null,
      agentMailClient: null,
      runPhase,
      registerAgent: vi.fn().mockResolvedValue(undefined),
      sendMail: vi.fn(),
      sendMailText: vi.fn(),
      reserveFiles: vi.fn(),
      releaseFiles: vi.fn(),
      markStuck,
      log: vi.fn(),
      promptOpts: { projectRoot: tmpDir, workflow: "default" },
    });

    expect(runPhase).toHaveBeenCalledTimes(1);
    expect(markStuck).toHaveBeenCalledTimes(1);
    expect(markStuck.mock.calls[0]?.[7]).toContain("Command phase contract violated");
    expect(markStuck.mock.calls[0]?.[7]).toContain("Blocked git commit during non-finalize phase");
  });
});
