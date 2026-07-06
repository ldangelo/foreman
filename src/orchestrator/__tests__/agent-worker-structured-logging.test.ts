import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { runTsxModule } from "../../test-support/tsx-subprocess.js";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const WORKER_SCRIPT = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

describe("agent-worker structured logging", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-structured-log-test-"));
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  /**
   * Verify that log() outputs structured JSON with all required fields.
   * This test spawns the worker with a config that causes early logging before
   * SDK initialization, capturing the JSON output format.
   */
  it("log() emits JSON with required fields when context is initialized", { timeout: 90_000 }, async () => {
    const configPath = join(tmpDir, "test-structured-log.json");
    writeFileSync(configPath, JSON.stringify({
      runId: "run-456",
      projectId: "test-project",
      taskId: "ABC-123",
      taskTitle: "Test Structured Logging",
      model: "claude-haiku-4-6",
      worktreePath: tmpDir,
      projectPath: tmpDir,
      prompt: "echo hello",
      env: {},
      attemptNumber: 1,
    }));

    const result = await runTsxModule(WORKER_SCRIPT, [configPath], {
      cwd: PROJECT_ROOT,
      timeout: 15_000,
      env: {
        ...process.env,
        HOME: tmpDir,
        ANTHROPIC_API_KEY: "sk-ant-invalid-test-key",
      },
    });

    // Parse each line of stderr as JSON and find structured log entries
    const lines = result.stderr.split("\n").filter(Boolean);
    const structuredLogs = lines
      .map((line) => {
        try { return JSON.parse(line); } catch { return null; }
      })
      .filter((obj): obj is Record<string, unknown> =>
        obj !== null &&
        typeof obj === "object" &&
        "level" in obj &&
        "timestamp" in obj &&
        "message" in obj
      );

    // Should have at least one structured log entry (worker started message)
    expect(structuredLogs.length).toBeGreaterThan(0);

    // Verify all required fields are present in structured logs
    for (const entry of structuredLogs) {
      expect(entry).toHaveProperty("level");
      expect(entry).toHaveProperty("timestamp");
      expect(entry).toHaveProperty("message");
      expect(entry).toHaveProperty("issueId");
      expect(entry).toHaveProperty("issueIdentifier");
      expect(entry).toHaveProperty("sessionId");
      expect(entry).toHaveProperty("runId");
      expect(entry).toHaveProperty("attempt");

      // Verify field values match config
      expect(entry["issueId"]).toBe("ABC-123");
      expect(entry["issueIdentifier"]).toBe("ABC-123");
      expect(entry["runId"]).toBe("run-456");
      expect(entry["attempt"]).toBe(1);
      expect(entry["sessionId"]).toBeNull(); // No resume session

      // Verify level is a valid string
      expect(typeof entry["level"]).toBe("string");
      expect(["info", "warn", "error"]).toContain(entry["level"]);

      // Verify timestamp is ISO format
      expect(entry["timestamp"]).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);
    }
  });

  it("log() includes sessionId when resume session is provided", async () => {
    const configPath = join(tmpDir, "test-session-log.json");
    writeFileSync(configPath, JSON.stringify({
      runId: "run-789",
      projectId: "test-project",
      taskId: "XYZ-456",
      taskTitle: "Test Session Logging",
      model: "claude-haiku-4-6",
      worktreePath: tmpDir,
      projectPath: tmpDir,
      prompt: "echo hello",
      env: {},
      resume: "thread-abc-turn-1",
      attemptNumber: 2,
    }));

    const result = await runTsxModule(WORKER_SCRIPT, [configPath], {
      cwd: PROJECT_ROOT,
      timeout: 15_000,
      env: {
        ...process.env,
        HOME: tmpDir,
        ANTHROPIC_API_KEY: "sk-ant-invalid-test-key",
      },
    });

    // Parse stderr for structured JSON entries
    const lines = result.stderr.split("\n").filter(Boolean);
    const structuredLogs = lines
      .map((line) => {
        try { return JSON.parse(line); } catch { return null; }
      })
      .filter((obj): obj is Record<string, unknown> =>
        obj !== null &&
        typeof obj === "object" &&
        "sessionId" in obj
      );

    // Verify sessionId is present and correct
    const sessionLog = structuredLogs.find((log) => log["sessionId"] === "thread-abc-turn-1");
    expect(sessionLog).toBeDefined();
    expect(sessionLog!["attempt"]).toBe(2);
    expect(sessionLog!["issueId"]).toBe("XYZ-456");
  });

  describe("initLogContext behavior", () => {
    it("sets all required context fields from WorkerConfig", () => {
      // Source inspection test for initLogContext implementation
      const workerSource = readFileSync(WORKER_SCRIPT, "utf-8");

      // Verify initLogContext function exists and uses correct field names
      expect(workerSource).toContain("function initLogContext(config: WorkerConfig): void");

      // Verify LogContext interface has all required fields
      expect(workerSource).toContain("interface LogContext");
      expect(workerSource).toContain("issueId:");
      expect(workerSource).toContain("issueIdentifier:");
      expect(workerSource).toContain("sessionId:");
      expect(workerSource).toContain("runId:");
      expect(workerSource).toContain("attempt:");

      // Verify initLogContext sets all fields correctly
      expect(workerSource).toContain("issueId: config.taskId");
      expect(workerSource).toContain("issueIdentifier: config.taskId");
      expect(workerSource).toContain("sessionId: config.resume ?? null");
      expect(workerSource).toContain("runId: config.runId");
      expect(workerSource).toContain("attempt: config.attemptNumber ?? 1");
    });

    it("defaults attempt to 1 when not provided", () => {
      const workerSource = readFileSync(WORKER_SCRIPT, "utf-8");
      expect(workerSource).toContain("attempt: config.attemptNumber ?? 1");
    });
  });

  describe("log() structured output format", () => {
    it("log() outputs valid JSON with all context fields", () => {
      const workerSource = readFileSync(WORKER_SCRIPT, "utf-8");

      // Verify log() function has structured JSON output
      expect(workerSource).toContain("function log(msg: string): void");
      expect(workerSource).toContain("const entry: Record<string, unknown> = {");
      expect(workerSource).toContain('level: "info"');
      expect(workerSource).toContain("timestamp: new Date().toISOString()");
      expect(workerSource).toContain("message: msg");
      expect(workerSource).toContain("issueId: logContext.issueId");
      expect(workerSource).toContain("issueIdentifier: logContext.issueIdentifier");
      expect(workerSource).toContain("sessionId: logContext.sessionId");
      expect(workerSource).toContain("runId: logContext.runId");
      expect(workerSource).toContain("attempt: logContext.attempt");
      expect(workerSource).toContain("console.error(JSON.stringify(entry))");
    });

    it("log() falls back to text format when logContext is null", () => {
      const workerSource = readFileSync(WORKER_SCRIPT, "utf-8");

      // Verify fallback path when logContext is not initialized
      expect(workerSource).toContain("if (logContext)");
      expect(workerSource).toContain("console.error(`[foreman-worker ${ts}] ${msg}`)");
    });
  });

  describe("WorkerConfig interface completeness", () => {
    it("WorkerConfig includes all required fields for structured logging", () => {
      const workerSource = readFileSync(WORKER_SCRIPT, "utf-8");

      // Verify WorkerConfig interface
      expect(workerSource).toContain("interface WorkerConfig");
      expect(workerSource).toContain("runId: string");
      expect(workerSource).toContain("taskId: string");
      expect(workerSource).toContain("attemptNumber?: number");
      expect(workerSource).toContain("resume?: string");
    });
  });
});

describe("structured logging format matches proposed specification", () => {
  const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
  const WORKER_SCRIPT = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

  it("proposed JSON format fields are all implemented", () => {
    const workerSource = readFileSync(WORKER_SCRIPT, "utf-8");

    // Proposed format:
    // {
    //   "level": "info",
    //   "timestamp": "2026-06-02T10:30:00.000Z",
    //   "message": "Dispatching task",
    //   "issueId": "ABC-123",
    //   "issueIdentifier": "ABC-123",
    //   "sessionId": "thread-abc-turn-1",
    //   "runId": "run-456",
    //   "attempt": 1
    // }

    // Verify all fields are present in log() output (keys don't have quotes in TypeScript object literal)
    expect(workerSource).toContain('level: "info"');
    expect(workerSource).toContain("timestamp: new Date().toISOString()");
    expect(workerSource).toContain("message: msg");
    expect(workerSource).toContain("issueId: logContext.issueId");
    expect(workerSource).toContain("issueIdentifier: logContext.issueIdentifier");
    expect(workerSource).toContain("sessionId: logContext.sessionId");
    expect(workerSource).toContain("runId: logContext.runId");
    expect(workerSource).toContain("attempt: logContext.attempt");
  });

  it("timestamp format is ISO 8601 with milliseconds", () => {
    const workerSource = readFileSync(WORKER_SCRIPT, "utf-8");
    // Using toISOString() produces: "2026-06-02T10:30:00.000Z" (ISO 8601 with milliseconds)
    expect(workerSource).toContain("new Date().toISOString()");
  });
});