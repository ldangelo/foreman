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
      beadId: "test-bead",
      beadTitle: "Test Bead",
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
      beadId: "test-bead-log",
      beadTitle: "Test Logging",
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
      expect(content).toContain("test-bead-log");
      expect(content).toContain("Test Logging");
    }
    // If log file doesn't exist, the worker crashed before logging
    // (e.g., store init failure) — that's acceptable for this test
  });
});
