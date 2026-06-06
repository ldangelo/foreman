import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { StructuredLogger, extractSessionId, createStructuredLogger } from "../structured-logger.js";

describe("StructuredLogger", () => {
  let consoleLogSpy: ReturnType<typeof vi.spyOn>;
  let consoleWarnSpy: ReturnType<typeof vi.spyOn>;
  let consoleErrorSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    consoleWarnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe("constructor", () => {
    it("should create a logger with empty context by default", () => {
      const logger = new StructuredLogger();
      logger.info("test message");

      expect(consoleLogSpy).toHaveBeenCalledTimes(1);
      const [jsonArg] = consoleLogSpy.mock.calls[0]!;
      const entry = JSON.parse(jsonArg as string);

      expect(entry.message).toBe("test message");
      expect(entry.level).toBe("info");
      expect(entry.issueId).toBeNull();
      expect(entry.runId).toBeNull();
      expect(entry.sessionId).toBeNull();
      expect(entry.attempt).toBeNull();
    });

    it("should set initial context values", () => {
      const logger = new StructuredLogger({
        issueId: "ABC-123",
        runId: "run-456",
        sessionId: "thread-abc-turn-1",
        attempt: 2,
      });
      logger.info("test");

      const [jsonArg] = consoleLogSpy.mock.calls[0]!;
      const entry = JSON.parse(jsonArg as string);

      expect(entry.issueId).toBe("ABC-123");
      expect(entry.issueIdentifier).toBe("ABC-123");
      expect(entry.runId).toBe("run-456");
      expect(entry.sessionId).toBe("thread-abc-turn-1");
      expect(entry.attempt).toBe(2);
    });
  });

  describe("info/warn/error", () => {
    it("should output info level to console.log", () => {
      const logger = new StructuredLogger();
      logger.info("info message");

      expect(consoleLogSpy).toHaveBeenCalledTimes(1);
      expect(consoleWarnSpy).not.toHaveBeenCalled();
      expect(consoleErrorSpy).not.toHaveBeenCalled();

      const [jsonArg] = consoleLogSpy.mock.calls[0]!;
      const entry = JSON.parse(jsonArg as string);
      expect(entry.level).toBe("info");
      expect(entry.message).toBe("info message");
    });

    it("should output warn level to console.warn", () => {
      const logger = new StructuredLogger();
      logger.warn("warn message");

      expect(consoleWarnSpy).toHaveBeenCalledTimes(1);
      expect(consoleLogSpy).not.toHaveBeenCalled();
      expect(consoleErrorSpy).not.toHaveBeenCalled();

      const [jsonArg] = consoleWarnSpy.mock.calls[0]!;
      const entry = JSON.parse(jsonArg as string);
      expect(entry.level).toBe("warn");
      expect(entry.message).toBe("warn message");
    });

    it("should output error level to console.error", () => {
      const logger = new StructuredLogger();
      logger.error("error message");

      expect(consoleErrorSpy).toHaveBeenCalledTimes(1);
      expect(consoleLogSpy).not.toHaveBeenCalled();
      expect(consoleWarnSpy).not.toHaveBeenCalled();

      const [jsonArg] = consoleErrorSpy.mock.calls[0]!;
      const entry = JSON.parse(jsonArg as string);
      expect(entry.level).toBe("error");
      expect(entry.message).toBe("error message");
    });

    it("should include timestamp in ISO format", () => {
      const logger = new StructuredLogger();
      logger.info("test");

      const [jsonArg] = consoleLogSpy.mock.calls[0]!;
      const entry = JSON.parse(jsonArg as string);

      expect(entry.timestamp).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.\d{3}Z$/);
    });

    it("should include all context fields in output", () => {
      const logger = new StructuredLogger({
        issueId: "ABC-123",
        issueIdentifier: "ABC-123",
        runId: "run-456",
        sessionId: "thread-abc-turn-1",
        attempt: 1,
      });
      logger.info("test");

      const [jsonArg] = consoleLogSpy.mock.calls[0]!;
      const entry = JSON.parse(jsonArg as string);

      expect(entry.issueId).toBe("ABC-123");
      expect(entry.issueIdentifier).toBe("ABC-123");
      expect(entry.runId).toBe("run-456");
      expect(entry.sessionId).toBe("thread-abc-turn-1");
      expect(entry.attempt).toBe(1);
    });
  });

  describe("setContext", () => {
    it("should update context values", () => {
      const logger = new StructuredLogger({ runId: "run-1" });
      logger.setContext({ runId: "run-2", sessionId: "session-1" });
      logger.info("test");

      const [jsonArg] = consoleLogSpy.mock.calls[0]!;
      const entry = JSON.parse(jsonArg as string);

      expect(entry.runId).toBe("run-2");
      expect(entry.sessionId).toBe("session-1");
    });

    it("should merge with existing context", () => {
      const logger = new StructuredLogger({
        issueId: "ABC-123",
        runId: "run-456",
      });
      logger.setContext({ sessionId: "thread-1" });
      logger.info("test");

      const [jsonArg] = consoleLogSpy.mock.calls[0]!;
      const entry = JSON.parse(jsonArg as string);

      expect(entry.issueId).toBe("ABC-123");
      expect(entry.runId).toBe("run-456");
      expect(entry.sessionId).toBe("thread-1");
    });
  });

  describe("child", () => {
    it("should create a child logger with additional context", () => {
      const parent = new StructuredLogger({
        issueId: "ABC-123",
        runId: "run-456",
      });
      const child = parent.child({ sessionId: "thread-1", attempt: 1 });

      child.info("test");

      const [jsonArg] = consoleLogSpy.mock.calls[0]!;
      const entry = JSON.parse(jsonArg as string);

      expect(entry.issueId).toBe("ABC-123");
      expect(entry.runId).toBe("run-456");
      expect(entry.sessionId).toBe("thread-1");
      expect(entry.attempt).toBe(1);
    });

    it("should not affect parent context when child has overrides", () => {
      const parent = new StructuredLogger({ runId: "run-parent" });
      const child = parent.child({ runId: "run-child" });

      parent.info("parent message");
      child.info("child message");

      const parentEntry = JSON.parse(consoleLogSpy.mock.calls[0]![0] as string);
      const childEntry = JSON.parse(consoleLogSpy.mock.calls[1]![0] as string);

      expect(parentEntry.runId).toBe("run-parent");
      expect(childEntry.runId).toBe("run-child");
    });
  });

  describe("contextOverrides in log methods", () => {
    it("should allow overriding context per-call", () => {
      const logger = new StructuredLogger({ issueId: "ABC-123" });
      logger.info("message 1");
      logger.info("message 2", { issueId: "XYZ-789" });

      const entry1 = JSON.parse(consoleLogSpy.mock.calls[0]![0] as string);
      const entry2 = JSON.parse(consoleLogSpy.mock.calls[1]![0] as string);

      expect(entry1.issueId).toBe("ABC-123");
      expect(entry2.issueId).toBe("XYZ-789");
    });
  });

  describe("null handling", () => {
    it("should output null for unset context fields", () => {
      const logger = new StructuredLogger();
      logger.info("test");

      const [jsonArg] = consoleLogSpy.mock.calls[0]!;
      const entry = JSON.parse(jsonArg as string);

      expect(entry.issueId).toBeNull();
      expect(entry.issueIdentifier).toBeNull();
      expect(entry.sessionId).toBeNull();
      expect(entry.runId).toBeNull();
      expect(entry.attempt).toBeNull();
    });

    it("should treat undefined as null", () => {
      const logger = new StructuredLogger({ issueId: undefined });
      logger.info("test");

      const [jsonArg] = consoleLogSpy.mock.calls[0]!;
      const entry = JSON.parse(jsonArg as string);

      expect(entry.issueId).toBeNull();
    });
  });
});

describe("extractSessionId", () => {
  it("should extract session ID from valid session key", () => {
    const sessionKey = "foreman:sdk:anthropic/claude-sonnet-4-6:run-456:pid-123:session-thread-abc-turn-1";
    const sessionId = extractSessionId(sessionKey);
    expect(sessionId).toBe("thread-abc-turn-1");
  });

  it("should extract session ID without pid segment", () => {
    const sessionKey = "foreman:sdk:anthropic/claude-sonnet-4-6:run-456:session-thread-abc-turn-1";
    const sessionId = extractSessionId(sessionKey);
    expect(sessionId).toBe("thread-abc-turn-1");
  });

  it("should return null for null input", () => {
    expect(extractSessionId(null)).toBeNull();
  });

  it("should return null for empty string", () => {
    expect(extractSessionId("")).toBeNull();
  });

  it("should return null for session key without session segment", () => {
    const sessionKey = "foreman:sdk:anthropic/claude-sonnet-4-6:run-456";
    expect(extractSessionId(sessionKey)).toBeNull();
  });

  it("should handle session ID with special characters", () => {
    const sessionKey = "foreman:sdk:anthropic/claude-sonnet-4-6:run-456:session-my-session_123";
    const sessionId = extractSessionId(sessionKey);
    expect(sessionId).toBe("my-session_123");
  });
});

describe("createStructuredLogger", () => {
  let consoleLogSpy: ReturnType<typeof vi.spyOn>;
  const originalEnv = process.env;

  beforeEach(() => {
    consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    process.env = { ...originalEnv };
  });

  afterEach(() => {
    vi.restoreAllMocks();
    process.env = originalEnv;
  });

  it("should read FOREMAN_RUN_ID from env", () => {
    process.env["FOREMAN_RUN_ID"] = "env-run-id";
    const logger = createStructuredLogger();

    logger.info("test");
    const [jsonArg] = consoleLogSpy.mock.calls[0]!;
    const entry = JSON.parse(jsonArg as string);

    expect(entry.runId).toBe("env-run-id");
  });

  it("should read FOREMAN_SEED_ID from env for issueId and issueIdentifier", () => {
    process.env["FOREMAN_SEED_ID"] = "bd-abc123";
    const logger = createStructuredLogger();

    logger.info("test");
    const [jsonArg] = consoleLogSpy.mock.calls[0]!;
    const entry = JSON.parse(jsonArg as string);

    expect(entry.issueId).toBe("bd-abc123");
    expect(entry.issueIdentifier).toBe("bd-abc123");
  });

  it("should prefer explicit context over env vars", () => {
    process.env["FOREMAN_RUN_ID"] = "env-run-id";
    const logger = createStructuredLogger({ runId: "explicit-run-id" });

    logger.info("test");
    const [jsonArg] = consoleLogSpy.mock.calls[0]!;
    const entry = JSON.parse(jsonArg as string);

    expect(entry.runId).toBe("explicit-run-id");
  });

  it("should merge explicit context with env vars", () => {
    process.env["FOREMAN_RUN_ID"] = "env-run-id";
    const logger = createStructuredLogger({ issueId: "explicit-issue-id" });

    logger.info("test");
    const [jsonArg] = consoleLogSpy.mock.calls[0]!;
    const entry = JSON.parse(jsonArg as string);

    expect(entry.runId).toBe("env-run-id");
    expect(entry.issueId).toBe("explicit-issue-id");
  });
});