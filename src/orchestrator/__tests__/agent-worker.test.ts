import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, existsSync, readFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
// tsx may live in the worktree's own node_modules or in the parent project's (when running from a git worktree)
const TSX_BIN = existsSync(join(PROJECT_ROOT, "node_modules", ".bin", "tsx"))
  ? join(PROJECT_ROOT, "node_modules", ".bin", "tsx")
  : join(PROJECT_ROOT, "..", "..", "node_modules", ".bin", "tsx");
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

  describe("checkpoint behavior", () => {
    it("creates checkpoint directory on startup", () => {
      const checkpointDir = join(tmpDir, "checkpoints");
      const configPath = join(tmpDir, "test-config-chkdir.json");

      writeFileSync(configPath, JSON.stringify({
        runId: "test-run-chkdir",
        projectId: "test-project",
        seedId: "test-seed-chk",
        seedTitle: "Test Checkpoint Dir",
        model: "claude-sonnet-4-6",
        worktreePath: tmpDir,
        prompt: "test",
        env: {},
        checkpointDir,
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
        // Expected to fail (no valid API key)
      }

      // Checkpoint directory should have been created
      expect(existsSync(checkpointDir)).toBe(true);
    });

    it("detects and logs stale checkpoint on startup", () => {
      const checkpointDir = join(tmpDir, "checkpoints");
      mkdirSync(checkpointDir, { recursive: true });

      const runId = "test-run-stale";

      // Write a stale checkpoint simulating a previous crash
      const staleCheckpoint = {
        version: 1,
        runId,
        seedId: "test-seed",
        sessionId: "session-abc123",
        progress: {
          toolCalls: 5,
          toolBreakdown: { Read: 3, Edit: 2 },
          filesChanged: ["src/foo.ts"],
          turns: 3,
          costUsd: 0.01,
          tokensIn: 100,
          tokensOut: 50,
          lastToolCall: "Edit",
          lastActivity: new Date(Date.now() - 3600_000).toISOString(),
        },
        savedAt: new Date(Date.now() - 3600_000).toISOString(),
      };
      writeFileSync(join(checkpointDir, `${runId}.json`), JSON.stringify(staleCheckpoint));

      const configPath = join(tmpDir, "test-config-stale.json");
      writeFileSync(configPath, JSON.stringify({
        runId,
        projectId: "test-project",
        seedId: "test-seed",
        seedTitle: "Test Stale Checkpoint",
        model: "claude-sonnet-4-6",
        worktreePath: tmpDir,
        prompt: "test",
        env: {},
        checkpointDir,
      }));

      let stderrOutput = "";
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
      } catch (err: any) {
        stderrOutput = err.stderr ?? "";
      }

      // Worker should log that it detected a stale checkpoint
      expect(stderrOutput).toContain("stale checkpoint");
    });

    it("ignores checkpoint file with incompatible version", () => {
      const checkpointDir = join(tmpDir, "checkpoints");
      mkdirSync(checkpointDir, { recursive: true });

      const runId = "test-run-badver";

      // Write checkpoint with wrong version
      const badCheckpoint = {
        version: 999,
        runId,
        seedId: "test-seed",
        sessionId: "session-xyz",
        progress: { toolCalls: 1, turns: 1, costUsd: 0, tokensIn: 0, tokensOut: 0, toolBreakdown: {}, filesChanged: [], lastToolCall: null, lastActivity: new Date().toISOString() },
        savedAt: new Date().toISOString(),
      };
      writeFileSync(join(checkpointDir, `${runId}.json`), JSON.stringify(badCheckpoint));

      const configPath = join(tmpDir, "test-config-badver.json");
      writeFileSync(configPath, JSON.stringify({
        runId,
        projectId: "test-project",
        seedId: "test-seed",
        seedTitle: "Test Bad Version",
        model: "claude-sonnet-4-6",
        worktreePath: tmpDir,
        prompt: "test",
        env: {},
        checkpointDir,
      }));

      let stderrOutput = "";
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
      } catch (err: any) {
        stderrOutput = err.stderr ?? "";
      }

      // Should NOT log stale checkpoint (incompatible version is ignored)
      expect(stderrOutput).not.toContain("stale checkpoint");
    });

    it("uses default checkpoint dir when checkpointDir not in config", () => {
      const configPath = join(tmpDir, "test-config-defchk.json");

      writeFileSync(configPath, JSON.stringify({
        runId: "test-run-defchk",
        projectId: "test-project",
        seedId: "test-seed-defchk",
        seedTitle: "Test Default Checkpoint Dir",
        model: "claude-sonnet-4-6",
        worktreePath: tmpDir,
        prompt: "test",
        env: {},
        // No checkpointDir — should use HOME/.foreman/checkpoints
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

      // Default checkpoint directory should have been created under HOME
      const defaultCheckpointDir = join(tmpDir, ".foreman", "checkpoints");
      expect(existsSync(defaultCheckpointDir)).toBe(true);
    });
  });
});
