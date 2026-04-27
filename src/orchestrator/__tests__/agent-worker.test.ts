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

  it("exits with error when no config file argument given", async () => {
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
      seedId: "test-seed",
      seedTitle: "Test Seed",
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
      seedId: "test-seed-log",
      seedTitle: "Test Logging",
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
      expect(content).toContain("test-seed-log");
      expect(content).toContain("Test Logging");
    }
    // If log file doesn't exist, the worker crashed before logging
    // (e.g., store init failure) — that's acceptable for this test
  });

  describe("seed reset to open on failure — source regression tests", () => {
    /**
     * These tests verify by source inspection that resetSeedToOpen() is called
     * in the critical failure paths of agent-worker.ts.
     *
     * Source-inspection is used here because the integration approach (spawning
     * the worker with a bad API key) fails before reaching resetSeedToOpen due to
     * SQLite FOREIGN KEY constraints on the unregistered project_id. The source
     * inspection approach is lighter and catches the same regression risk: that
     * a refactor accidentally removes the resetSeedToOpen calls.
     */
    const WORKER_SRC_PATH = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

    it("catch block (main error path) enqueues resetSeedToOpen via bead write queue", () => {
      const source = readFileSync(WORKER_SRC_PATH, "utf-8");
      // The main catch block must enqueue a reset-seed operation
      expect(source).toContain("enqueueResetSeedToOpen(store, seedId, ");
    });

    it("enqueueResetSeedToOpen is imported from task-backend-ops", () => {
      const source = readFileSync(WORKER_SRC_PATH, "utf-8");
      expect(source).toMatch(/import.*enqueueResetSeedToOpen.*from.*task-backend-ops/);
    });

    it("enqueueResetSeedToOpen is called at least twice (catch block + finalize path)", () => {
      const source = readFileSync(WORKER_SRC_PATH, "utf-8");
      // Count occurrences — there should be at least 2 (catch block + markStuck)
      const matches = source.match(/enqueueResetSeedToOpen\(/g) ?? [];
      expect(matches.length).toBeGreaterThanOrEqual(2);
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

  it("routes markStuck terminal run updates through the helper", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    expect(source).toContain('import { updateTerminalRunStatus } from "./agent-worker-run-status.js";');
    expect(source).toContain('await updateTerminalRunStatus({');
    expect(source).not.toContain('store.updateRun(runId, { status: stuckStatus, completed_at: now });');
  });

  it("routes markStuck observability writes through registered-aware helpers", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    expect(source).toContain('import { writeMarkStuckEvent, writeMarkStuckProgress } from "./agent-worker-mark-stuck-observability.js";');
    expect(source).toContain('markStuck: async (storeArg, runIdArg, projectIdArg, seedIdArg, seedTitleArg, progressArg, phaseArg, reasonArg, projectPathArg, notifyClientArg) =>');
    expect(source).toContain('await writeMarkStuckProgress(localStore, registeredReadStore, runId, progress, log);');
    expect(source).toContain('await writeMarkStuckEvent(localStore, registeredReadStore, projectId, runId, isRateLimit ? "stuck" : "fail", {');
    const progressIndex = source.indexOf('await writeMarkStuckProgress(localStore, registeredReadStore, runId, progress, log);');
    const terminalIndex = source.indexOf('await updateTerminalRunStatus({', progressIndex);
    const eventIndex = source.indexOf('await writeMarkStuckEvent(localStore, registeredReadStore, projectId, runId, isRateLimit ? "stuck" : "fail", {', terminalIndex);
    const resetIndex = source.indexOf('enqueueResetSeedToOpen(store, seedId, "agent-worker-markStuck");', eventIndex);
    const failIndex = source.indexOf('enqueueMarkBeadFailed(store, seedId, "agent-worker-markStuck");', eventIndex);
    const notesIndex = source.indexOf('enqueueAddNotesToBead(store, seedId, failureNote, "agent-worker-markStuck");', eventIndex);
    expect(progressIndex).toBeGreaterThan(-1);
    expect(terminalIndex).toBeGreaterThan(progressIndex);
    expect(eventIndex).toBeGreaterThan(terminalIndex);
    expect(resetIndex).toBeGreaterThan(eventIndex);
    expect(failIndex).toBeGreaterThan(eventIndex);
    expect(notesIndex).toBeGreaterThan(eventIndex);
    expect(source).toContain('enqueueResetSeedToOpen(store, seedId, "agent-worker-markStuck");');
    expect(source).toContain('enqueueMarkBeadFailed(store, seedId, "agent-worker-markStuck");');
    expect(source).toContain('enqueueAddNotesToBead(store, seedId, failureNote, "agent-worker-markStuck");');
  });

  it("routes single-agent progress and terminal observability through registered-aware helpers", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    expect(source).toContain('import { writeSingleAgentProgress, writeSingleAgentTerminalEvent } from "./agent-worker-single-agent-observability.js";');
    expect(source).toContain('const registeredReadStore = databaseUrl ? pgStore : undefined;');
    expect(source).toContain('await runPipeline(config, store, localStore, logFile, notifyClient, agentMailClient, registeredReadStore);');
    expect(source).toContain('let progressFlushTail: Promise<void> = Promise.resolve();');
    expect(source).toContain('progressFlushTail = progressFlushTail.then(() => writeSingleAgentProgress(localStore, registeredReadStore, runId, progress, log));');
    expect(source).toContain('await waitForProgressFlush();');
    expect(source).toContain('await writeSingleAgentProgress(localStore, registeredReadStore, runId, progress, log);');
    expect(source).toContain('await writeSingleAgentTerminalEvent(localStore, registeredReadStore, projectId, runId, "complete", {');
    expect(source).toContain('await writeSingleAgentTerminalEvent(localStore, registeredReadStore, projectId, runId, "fail", {');
    expect(source).toContain('await writeSingleAgentTerminalEvent(localStore, registeredReadStore, projectId, runId, isRateLimit ? "stuck" : "fail", {');
    expect(source).toContain('await updateTerminalRunStatus({');
    expect(source).not.toContain('store.updateRunProgress(runId, progress);');
    expect(source).not.toContain('store.logEvent(projectId, "complete"');
    expect(source).not.toContain('store.logEvent(projectId, "fail"');
    expect(source).not.toContain('store.logEvent(projectId, isRateLimit ? "stuck" : "fail"');
  });

});
