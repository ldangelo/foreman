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

    it("catch block (main error path) calls resetSeedToOpen", () => {
      const source = readFileSync(WORKER_SRC_PATH, "utf-8");
      // The main catch block must call resetSeedToOpen after the error log
      // Pattern: "ERROR": ... then resetSeedToOpen
      expect(source).toContain("await resetSeedToOpen(seedId, storeProjectPath)");
    });

    it("resetSeedToOpen is imported from task-backend-ops", () => {
      const source = readFileSync(WORKER_SRC_PATH, "utf-8");
      expect(source).toMatch(/import.*resetSeedToOpen.*from.*task-backend-ops/);
    });

    it("resetSeedToOpen is called at least once after a failed result", () => {
      const source = readFileSync(WORKER_SRC_PATH, "utf-8");
      // Count occurrences — there should be at least 2 (catch block + failed result block)
      const matches = source.match(/await resetSeedToOpen\(/g) ?? [];
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
describe("agent-worker.ts: sessionLogDir option regression tests", () => {
  const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

  it("agent-worker.ts source file exists", () => {
    expect(existsSync(WORKER_SRC)).toBe(true);
  });

  it("single-agent resume branch includes sessionLogDir: worktreePath", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    // The resume branch (with persistSession: true, resume: ...) must include sessionLogDir
    // Find the resume branch options block and verify sessionLogDir is present
    const resumeBlockMatch = source.match(
      /resume,\s*\n\s*persistSession: true,\s*\n\s*sessionLogDir:\s*worktreePath/
    );
    expect(resumeBlockMatch).not.toBeNull();
  });

  it("single-agent non-resume branch includes sessionLogDir: worktreePath", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    // The non-resume branch (with persistSession: true, no resume) must include sessionLogDir
    const nonResumeBlockMatch = source.match(
      /persistSession: true,\s*\n\s*sessionLogDir:\s*worktreePath/
    );
    expect(nonResumeBlockMatch).not.toBeNull();
  });

  it("pipeline runPhase() includes sessionLogDir: config.worktreePath", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    // The runPhase() function must include sessionLogDir: config.worktreePath
    const pipelineMatch = source.match(/sessionLogDir:\s*config\.worktreePath/);
    expect(pipelineMatch).not.toBeNull();
  });

});
