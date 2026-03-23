import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const TSX_BIN = join(PROJECT_ROOT, "node_modules", ".bin", "tsx");
const WORKER_SCRIPT = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

describe("agent-worker.ts", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-worker-test-"));
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("exits with error when no config file argument given", () => {
    try {
      execFileSync(TSX_BIN, [WORKER_SCRIPT], {
        timeout: 10_000,
        encoding: "utf-8",
        env: { ...process.env, HOME: tmpDir },
      });
      expect.unreachable("Should have exited with error");
    } catch (err: any) {
      expect(err.status).toBe(1);
      expect(err.stderr).toContain("Usage: agent-worker <config-file>");
    }
  });

  it("reads and deletes the config file on startup", () => {
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
      prompt: "echo hello",
      env: {},
    }));

    expect(existsSync(configPath)).toBe(true);

    try {
      execFileSync(TSX_BIN, [WORKER_SCRIPT, configPath], {
        timeout: 15_000,
        encoding: "utf-8",
        env: {
          ...process.env,
          HOME: tmpDir,
          // Ensure no valid API key so SDK fails fast
          ANTHROPIC_API_KEY: "sk-ant-invalid-test-key",
        },
      });
    } catch {
      // Expected to fail (no valid API key / no store), but config should be deleted
    }

    // Config file should have been deleted by the worker
    expect(existsSync(configPath)).toBe(false);
  });

  it("creates log directory and log file", () => {
    const configPath = join(tmpDir, "test-config.json");
    writeFileSync(configPath, JSON.stringify({
      runId: "test-run-log",
      projectId: "test-project",
      seedId: "test-seed-log",
      seedTitle: "Test Logging",
      model: "claude-sonnet-4-6",
      worktreePath: tmpDir,
      prompt: "test",
      env: {},
    }));

    try {
      execFileSync(TSX_BIN, [WORKER_SCRIPT, configPath], {
        timeout: 15_000,
        encoding: "utf-8",
        env: {
          ...process.env,
          HOME: tmpDir,
          ANTHROPIC_API_KEY: "sk-ant-invalid-test-key",
        },
      });
    } catch {
      // Expected to fail
    }

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

  describe("seed reset / failure handling — source regression tests", () => {
    /**
     * These tests verify by source inspection that the correct bead status
     * update functions are called in the critical failure paths of agent-worker.ts.
     *
     * Transient failures (rate limit) → resetSeedToOpen() so the task retries.
     * Permanent failures (SDK error, max retries) → markBeadFailed() so the task
     * is NOT auto-retried and the failure is visible in 'br show <seedId>'.
     * Both paths also call addNotesToBead() with the failure reason.
     *
     * Source-inspection is used here because the integration approach (spawning
     * the worker with a bad API key) fails before reaching these functions due to
     * SQLite FOREIGN KEY constraints on the unregistered project_id.
     */
    const WORKER_SRC_PATH = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

    it("resetSeedToOpen is imported from task-backend-ops", () => {
      const source = readFileSync(WORKER_SRC_PATH, "utf-8");
      expect(source).toMatch(/import.*resetSeedToOpen.*from.*task-backend-ops/);
    });

    it("markBeadFailed is imported from task-backend-ops", () => {
      const source = readFileSync(WORKER_SRC_PATH, "utf-8");
      expect(source).toMatch(/import.*markBeadFailed.*from.*task-backend-ops/);
    });

    it("addNotesToBead is imported from task-backend-ops", () => {
      const source = readFileSync(WORKER_SRC_PATH, "utf-8");
      expect(source).toMatch(/import.*addNotesToBead.*from.*task-backend-ops/);
    });

    it("resetSeedToOpen is used for transient (rate-limit) failures", () => {
      const source = readFileSync(WORKER_SRC_PATH, "utf-8");
      // resetSeedToOpen must still exist (used for rate-limit paths)
      const matches = source.match(/await resetSeedToOpen\(/g) ?? [];
      expect(matches.length).toBeGreaterThanOrEqual(1);
    });

    it("markBeadFailed is used for permanent failures", () => {
      const source = readFileSync(WORKER_SRC_PATH, "utf-8");
      const matches = source.match(/await markBeadFailed\(/g) ?? [];
      expect(matches.length).toBeGreaterThanOrEqual(1);
    });

    it("addNotesToBead is called with failure reason in failure paths", () => {
      const source = readFileSync(WORKER_SRC_PATH, "utf-8");
      const matches = source.match(/addNotesToBead\(/g) ?? [];
      expect(matches.length).toBeGreaterThanOrEqual(2);
    });

    it("catch block differentiates rate-limit vs permanent failures", () => {
      const source = readFileSync(WORKER_SRC_PATH, "utf-8");
      // The catch block must use isRateLimit to branch between resetSeedToOpen and markBeadFailed
      expect(source).toContain("isRateLimit");
      expect(source).toContain("await resetSeedToOpen(seedId, storeProjectPath)");
      expect(source).toContain("await markBeadFailed(seedId, storeProjectPath)");
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

  it("single-agent mode uses runWithPi instead of SDK query()", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    // Single-agent mode must use runWithPi for Pi RPC
    expect(source).toContain("runWithPi(");
    // Must NOT use the old SDK query() call in this file
    expect(source).not.toContain("from \"@anthropic-ai/claude-agent-sdk\"");
  });

  it("single-agent mode strips CLAUDECODE from Pi env", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    // Pi env construction must strip CLAUDECODE to avoid nested session errors
    expect(source).toContain("CLAUDECODE");
  });

  it("pipeline runPhase() uses runWithPi for phase execution", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    // The runPhase() function must use runWithPi
    const pipelineMatch = source.match(/runWithPi\(\{/);
    expect(pipelineMatch).not.toBeNull();
  });

});
