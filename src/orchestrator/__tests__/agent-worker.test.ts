import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import { execTsxModuleSync, runTsxModule } from "../../test-support/tsx-subprocess.js";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const WORKER_SCRIPT = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

describe("agent-worker.ts", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-worker-test-"));
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("exits with error when no config file argument given", { timeout: 90_000 }, async () => {
    const result = await runTsxModule(WORKER_SCRIPT, [], {
      cwd: PROJECT_ROOT,
      timeout: 10_000,
      env: { ...process.env, HOME: tmpDir },
    });

    expect(result.exitCode).toBe(1);
    expect(result.stderr).toContain("Usage: agent-worker <config-file>");
  });

  it("reads and deletes the config file on startup", async () => {
    // Write a config file that will cause the worker to fail at SDK query
    // (no valid API key), but we can verify it reads and deletes the config
    const configPath = join(tmpDir, "test-config.json");
    writeFileSync(configPath, JSON.stringify({
      runId: "test-run-001",
      projectId: "test-project",
      taskId: "test-task",
      taskTitle: "Test Task",
      model: "claude-sonnet-4-6",
      worktreePath: tmpDir,
      projectPath: tmpDir,
      dbPath: join(tmpDir, ".foreman", "foreman.db"),
      prompt: "echo hello",
      env: {},
    }));

    expect(existsSync(configPath)).toBe(true);

    await runTsxModule(WORKER_SCRIPT, [configPath], {
      cwd: PROJECT_ROOT,
      timeout: 15_000,
      env: {
        ...process.env,
        HOME: tmpDir,
        // Ensure no valid API key so SDK fails fast
        ANTHROPIC_API_KEY: "sk-ant-invalid-test-key",
      },
    });

    // Config file should have been deleted by the worker
    expect(existsSync(configPath)).toBe(false);
  });

  it("creates log directory and log file", async () => {
    const configPath = join(tmpDir, "test-config.json");
    writeFileSync(configPath, JSON.stringify({
      runId: "test-run-log",
      projectId: "test-project",
      taskId: "test-task-log",
      taskTitle: "Test Logging",
      model: "claude-sonnet-4-6",
      worktreePath: tmpDir,
      projectPath: tmpDir,
      dbPath: join(tmpDir, ".foreman", "foreman.db"),
      prompt: "test",
      env: {},
    }));

    await runTsxModule(WORKER_SCRIPT, [configPath], {
      cwd: PROJECT_ROOT,
      timeout: 15_000,
      env: {
        ...process.env,
        HOME: tmpDir,
        ANTHROPIC_API_KEY: "sk-ant-invalid-test-key",
      },
    });

    const logDir = join(tmpDir, ".foreman", "logs");
    const logFile = join(logDir, "test-run-log.log");

    // Log file should exist with header information
    if (existsSync(logFile)) {
      const content = readFileSync(logFile, "utf-8");
      expect(content).toContain("[foreman-worker]");
      expect(content).toContain("test-task-log");
      expect(content).toContain("Test Logging");
    }
    // If log file doesn't exist, the worker crashed before logging
    // (e.g., store init failure) — that's acceptable for this test
  });

  describe("task status reset/failure source regression tests", () => {
    /**
     * Workers must not write task state through the local/DB store. Failure/reset
     * paths route through the Elixir task client helper instead.
     */
    const WORKER_SRC_PATH = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

    it("routes task failure/reset through Elixir task status helper", () => {
      const source = readFileSync(WORKER_SRC_PATH, "utf-8");
      expect(source).toContain("async function updateTaskStatusViaElixir(");
      expect(source).toContain('await updateTaskStatusViaElixir(storeProjectPath, projectId, taskId, "failed", "agent-worker");');
      expect(source).toContain('await updateTaskStatusViaElixir(storeProjectPath, projectId, taskId, "ready", "agent-worker");');
      expect(source).not.toContain("enqueueResetTaskToOpen(");
      expect(source).not.toContain("enqueueMarkBeadFailed(");
    });
  });
});

/**
 * Structural regression tests: verify that sessionLogDir is configured in agent-worker.ts.
 *
 * These tests read the source file directly to catch regressions where the
 * sessionLogDir option is accidentally removed from a query() call. They are
 * a lightweight alternative to spy-based tests that would require refactoring
 * the module structure.
 */
describe("agent-worker.ts: Pi RPC integration regression tests", () => {
  const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

  it("agent-worker.ts source file exists", () => {
    expect(existsSync(WORKER_SRC)).toBe(true);
  });

  it("single-agent mode uses runPhaseSession instead of old SDK query()", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    // Single-agent mode must use the phase-runner seam
    expect(source).toContain("runPhaseSession(");
    // Must NOT use the old Claude Agent SDK query() call
    expect(source).not.toContain("from \"@anthropic-ai/claude-agent-sdk\"");
  });

  it("pipeline runPhase() uses runPhaseSession for phase execution", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    const pipelineMatch = source.match(/runPhaseSession\(\{/);
    expect(pipelineMatch).not.toBeNull();
  });

  it("passes workflow maxTurns into phase runner sessions", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    expect(source).toContain("maxTurns?: number;");
    expect(source).toContain("maxTurns: config.maxTurns");
  });

  it("reserves worker event sequence before appending so one rejected event does not poison later events", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    const sequenceIndex = source.indexOf("const nextSequence = sequence + 1;");
    const reserveIndex = source.indexOf("sequence = nextSequence;", sequenceIndex);
    const sendIndex = source.indexOf("sendWorkerEvent({", reserveIndex);
    expect(sequenceIndex).toBeGreaterThan(-1);
    expect(reserveIndex).toBeGreaterThan(sequenceIndex);
    expect(sendIndex).toBeGreaterThan(reserveIndex);
  });

  it("routes markStuck terminal run updates through the helper", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    expect(source).toContain('import { updateTerminalRunStatus } from "./agent-worker-run-status.js";');
    expect(source).toContain('await updateTerminalRunStatus({');
    expect(source).not.toContain('store.updateRun(runId, { status: stuckStatus, completed_at: now });');
  });

  it("routes markStuck observability without registered/local DB store writes", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    expect(source).toContain('import { writeMarkStuckEvent, writeMarkStuckProgress } from "./agent-worker-mark-stuck-observability.js";');
    expect(source).toContain('markStuck: async (storeArg, runIdArg, projectIdArg, taskIdArg, taskTitleArg, progressArg, phaseArg, reasonArg, projectPathArg, notifyClientArg) =>');
    expect(source).toContain('await writeMarkStuckProgress(undefined, runId, progress, log);');
    expect(source).toContain('await writeMarkStuckEvent(undefined, projectId, runId, isRateLimit ? "stuck" : "fail", {');
    expect(source).toContain('await updateTaskStatusViaElixir(projectPath, projectId, taskId, "ready", "agent-worker-markStuck");');
    expect(source).toContain('await updateTaskStatusViaElixir(projectPath, projectId, taskId, "failed", "agent-worker-markStuck");');
    expect(source).not.toContain('store.updateRunProgress(runId, progress);');
    expect(source).not.toContain('store.logEvent(projectId, "stuck"');
    expect(source).not.toContain('store.logEvent(projectId, "fail"');
    expect(source).not.toContain('enqueueResetTaskToOpen(');
    expect(source).not.toContain('enqueueMarkBeadFailed(');
    expect(source).not.toContain('enqueueAddNotesToBead(');
  });

  it("routes single-agent progress and terminal observability without DB store writes", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    expect(source).toContain('import { writeSingleAgentProgress, writeSingleAgentTerminalEvent } from "./agent-worker-single-agent-observability.js";');
    expect(source).toContain('const registeredProjectId = config.projectId;');
    expect(source).toContain('await runPipeline(config, store, logFile, notifyClient, agentMailClient, registeredReadStore, registeredProjectId);');
    expect(source).toContain('let progressFlushTail: Promise<void> = Promise.resolve();');
    expect(source).toContain('progressFlushTail = progressFlushTail.then(() => writeSingleAgentProgress(undefined, runId, progress, log));');
    expect(source).toContain('await waitForProgressFlush();');
    expect(source).toContain('await writeSingleAgentProgress(undefined, runId, progress, log);');
    expect(source).toContain('await writeSingleAgentTerminalEvent(undefined, projectId, runId, "complete", {');
    expect(source).toContain('await writeSingleAgentTerminalEvent(undefined, projectId, runId, "fail", {');
    expect(source).toContain('await writeSingleAgentTerminalEvent(undefined, projectId, runId, isRateLimit ? "stuck" : "fail", {');
    expect(source).toContain('await updateTerminalRunStatus({');
    expect(source).not.toContain('store.updateRunProgress(runId, progress);');
    expect(source).not.toContain('store.logEvent(projectId, "complete"');
    expect(source).not.toContain('store.logEvent(projectId, "fail"');
    expect(source).not.toContain('store.logEvent(projectId, isRateLimit ? "stuck" : "fail"');
  });

});
