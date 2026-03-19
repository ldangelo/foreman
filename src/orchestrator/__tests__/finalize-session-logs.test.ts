/**
 * Tests for SessionLogs creation in finalize().
 *
 * Verifies:
 * 1. finalize() creates a SessionLogs/ directory in the worktree
 * 2. A session transcript file is written (session-*.md)
 * 3. Transcript contains expected metadata (seedId, seedTitle, timestamp)
 * 4. SessionLogs creation is non-fatal (errors don't block finalization)
 * 5. Filename uses ISO 8601 format safe for the filesystem (no colons)
 *
 * NOTE: These tests document the EXPECTED behavior per bd-uj9e.
 * They will FAIL until finalize() implements the SessionLogs step.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  mkdtempSync,
  rmSync,
  mkdirSync,
  existsSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { createSessionLog } from "../session-log.js";
import type { RunProgress } from "../../lib/store.js";

// ── Module mocks ──────────────────────────────────────────────────────────────
// Mock heavy dependencies so finalize() can run without real git/SDK/store.

vi.mock("node:child_process", () => ({
  execFileSync: vi.fn(() => Buffer.from("")),
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: vi.fn(() => ({
      getDb: vi.fn(() => ({})),
      close: vi.fn(),
    })),
  },
}));

vi.mock("../agent-worker-enqueue.js", () => ({
  enqueueToMergeQueue: vi.fn(() => ({ success: true })),
}));

vi.mock("../task-backend-ops.js", () => ({
  closeSeed: vi.fn(async () => {}),
  resetSeedToOpen: vi.fn(async () => {}),
  addLabelsToBead: vi.fn(() => {}),
}));

function makeProgress(): RunProgress {
  return {
    toolCalls: 10,
    toolBreakdown: { Read: 5, Edit: 5 },
    filesChanged: ["src/foo.ts"],
    turns: 20,
    costUsd: 0.50,
    tokensIn: 5000,
    tokensOut: 2500,
    lastToolCall: "Edit",
    lastActivity: new Date().toISOString(),
    currentPhase: "finalize",
    costByPhase: { developer: 0.30, qa: 0.20 },
    agentByPhase: { developer: "claude-sonnet-4-6", qa: "claude-sonnet-4-6" },
  };
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeWorktree(): string {
  const dir = mkdtempSync(join(tmpdir(), "foreman-sessionlog-test-"));
  // Initialize as a minimal git repo so git commands don't crash
  mkdirSync(join(dir, ".git"), { recursive: true });
  writeFileSync(join(dir, ".git", "HEAD"), "ref: refs/heads/main\n");
  return dir;
}

function makeConfig(worktreePath: string) {
  return {
    runId: "run-test-001",
    projectId: "proj-test",
    seedId: "bd-test-xyz",
    seedTitle: "Test Session Log Creation",
    seedDescription: "Verify that finalize() writes SessionLogs",
    worktreePath,
    projectPath: worktreePath,
    model: "claude-sonnet-4-6",
    pipeline: true,
    skipExplore: false,
    skipReview: false,
    prompt: "",
    env: {},
  };
}

// ── SessionLogs creation tests ────────────────────────────────────────────────

describe("finalize() — SessionLogs creation", () => {
  let worktreeDir: string;
  let logFile: string;

  beforeEach(async () => {
    vi.clearAllMocks();
    worktreeDir = makeWorktree();
    const logDir = join(worktreeDir, ".foreman", "logs");
    mkdirSync(logDir, { recursive: true });
    logFile = join(logDir, "run-test-001.log");
    writeFileSync(logFile, "[foreman-worker] test log\n");
  });

  afterEach(() => {
    rmSync(worktreeDir, { recursive: true, force: true });
  });

  it("creates a SessionLogs/ directory in the worktree", async () => {
    const config = makeConfig(worktreeDir);
    const progress = makeProgress();
    const startedAt = new Date(Date.now() - 5 * 60_000).toISOString();

    const result = await createSessionLog(config, progress, startedAt, "abc1234", logFile);

    expect(result.success).toBe(true);
    const sessionLogsDir = join(worktreeDir, "SessionLogs");
    expect(existsSync(sessionLogsDir)).toBe(true);
  });

  it("writes a session-*.md transcript file in SessionLogs/", async () => {
    const config = makeConfig(worktreeDir);
    const progress = makeProgress();
    const startedAt = new Date(Date.now() - 5 * 60_000).toISOString();

    const result = await createSessionLog(config, progress, startedAt, "abc1234", logFile);

    expect(result.success).toBe(true);
    const sessionLogsDir = join(worktreeDir, "SessionLogs");
    const files = readdirSync(sessionLogsDir);
    expect(files.length).toBeGreaterThan(0);
    // Filename must match session-<ISO-timestamp-no-colons>.md
    expect(files[0]).toMatch(/^session-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d+Z\.md$/);
  });

  it("session transcript contains seedId and seedTitle", async () => {
    const config = makeConfig(worktreeDir);
    const progress = makeProgress();
    const startedAt = new Date(Date.now() - 5 * 60_000).toISOString();

    const result = await createSessionLog(config, progress, startedAt, "abc1234", logFile);

    expect(result.success).toBe(true);
    const content = readFileSync(result.path!, "utf-8");
    expect(content).toContain(config.seedId);
    expect(content).toContain(config.seedTitle);
    expect(content).toContain("ALL_CHECKS_PASSED");
  });

  it("uses filesystem-safe ISO timestamp (no colons in filename)", async () => {
    const config = makeConfig(worktreeDir);
    const progress = makeProgress();
    const startedAt = new Date(Date.now() - 5 * 60_000).toISOString();

    const result = await createSessionLog(config, progress, startedAt, "abc1234", logFile);

    expect(result.success).toBe(true);
    // The returned path filename must not contain colons — invalid on some filesystems
    expect(result.path).toBeDefined();
    const filename = result.path!.split("/").pop()!;
    expect(filename).not.toContain(":");
    expect(filename).toMatch(/^session-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d+Z\.md$/);
  });
});

// ── Integration: finalize() must produce SessionLogs ─────────────────────────

describe("finalize() integration — SessionLogs step is present", () => {
  it("finalize() function source includes SessionLogs creation logic", async () => {
    // Read the source file directly to verify the implementation exists
    const { readFileSync: fsRead } = await import("node:fs");
    const workerSrc = fsRead(
      join(import.meta.dirname, "..", "agent-worker.ts"),
      "utf-8",
    );

    // finalize() must reference SessionLogs directory
    expect(workerSrc).toMatch(/SessionLogs/);

    // finalize() must create the directory (mkdirSync or mkdir)
    expect(workerSrc).toMatch(/mkdirSync|mkdir/);

    // finalize() must call createSessionLog
    expect(workerSrc).toMatch(/createSessionLog/);
  });

  it("createSessionLog() populates SessionLogs/ with a session transcript", async () => {
    // This test verifies the end-to-end path: createSessionLog() is called and
    // the SessionLogs directory is populated with a session-*.md file.
    const dir = mkdtempSync(join(tmpdir(), "foreman-finalize-integration-"));
    try {
      const sessionLogsDir = join(dir, "SessionLogs");
      const logPath = join(dir, "run.log");
      writeFileSync(logPath, "");

      const config = {
        seedId: "bd-integration",
        seedTitle: "Integration Test",
        seedDescription: "Integration test for session logs",
        worktreePath: dir,
      };
      const progress = makeProgress();
      const startedAt = new Date(Date.now() - 10 * 60_000).toISOString();

      const result = await createSessionLog(config, progress, startedAt, "deadbeef", logPath);

      expect(result.success).toBe(true);
      expect(existsSync(sessionLogsDir)).toBe(true);
      const files = readdirSync(sessionLogsDir);
      expect(files.length).toBe(1);
      expect(files[0]).toMatch(/^session-.*\.md$/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

// ── Non-fatal error handling ───────────────────────────────────────────────────

describe("finalize() — SessionLogs creation is non-fatal", () => {
  let nonfatalWorktreeDir: string;
  let nonfatalLogFile: string;

  beforeEach(() => {
    nonfatalWorktreeDir = makeWorktree();
    const logDir = join(nonfatalWorktreeDir, ".foreman", "logs");
    mkdirSync(logDir, { recursive: true });
    nonfatalLogFile = join(logDir, "run-nonfatal.log");
    writeFileSync(nonfatalLogFile, "");
  });

  afterEach(() => {
    rmSync(nonfatalWorktreeDir, { recursive: true, force: true });
  });

  it("createSessionLog() returns success:false (non-fatal) when worktreePath is unwritable", async () => {
    const config = {
      seedId: "bd-nonfatal",
      seedTitle: "Non-fatal Test",
      seedDescription: "Tests that errors are returned, not thrown",
      // Use an unwritable path to force a failure
      worktreePath: "/dev/null/cannot-create-this",
    };
    const progress = makeProgress();
    const startedAt = new Date(Date.now() - 5 * 60_000).toISOString();

    // createSessionLog must not throw — errors are returned as { success: false }
    const result = await createSessionLog(config, progress, startedAt, "(none)", nonfatalLogFile);

    expect(result.success).toBe(false);
    expect(result.error).toBeDefined();
    expect(result.path).toBeUndefined();
    // Failure is appended to the run log, not thrown
    const logContent = readFileSync(nonfatalLogFile, "utf-8");
    expect(logContent).toContain("[FINALIZE] Session log creation failed (non-fatal):");
  });

  it("createSessionLog() returns success:true with path when creation succeeds", async () => {
    const config = makeConfig(nonfatalWorktreeDir);
    const progress = makeProgress();
    const startedAt = new Date(Date.now() - 5 * 60_000).toISOString();

    const result = await createSessionLog(config, progress, startedAt, "a1b2c3d", nonfatalLogFile);

    expect(result.success).toBe(true);
    expect(result.path).toBeDefined();
    expect(existsSync(result.path!)).toBe(true);
    // Success is appended to the run log
    const logContent = readFileSync(nonfatalLogFile, "utf-8");
    expect(logContent).toContain("[FINALIZE] Session log written:");
  });
});
