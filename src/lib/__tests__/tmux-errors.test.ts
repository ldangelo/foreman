import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

/**
 * AT-T042: Error path tests for all TMUX error codes (TMUX-001 through TMUX-012).
 *
 * Verifies each error code is triggered by the correct scenario and that all
 * error paths degrade gracefully (no unhandled exceptions).
 */

// ── Mock Setup ──────────────────────────────────────────────────────────────

vi.mock("node:child_process", () => {
  const mockExecFile = vi.fn();
  return { execFile: mockExecFile };
});

vi.mock("node:util", () => ({
  promisify: vi.fn((fn: unknown) => fn),
}));

const { execFile: mockExecFile } = await import("node:child_process");
const typedMock = mockExecFile as unknown as ReturnType<typeof vi.fn>;

let TmuxClient: typeof import("../tmux.js").TmuxClient;
let tmuxSessionName: typeof import("../tmux.js").tmuxSessionName;

// ── Helpers ─────────────────────────────────────────────────────────────────

function makeExecError(message: string, code?: number): Error {
  const err = new Error(message) as Error & { code?: number };
  if (code !== undefined) err.code = code;
  return err;
}

// ── Tests ───────────────────────────────────────────────────────────────────

describe("TMUX Error Codes", () => {
  const originalEnv = process.env;

  beforeEach(async () => {
    vi.resetModules();
    vi.doMock("node:child_process", () => ({
      execFile: typedMock,
    }));
    vi.doMock("node:util", () => ({
      promisify: vi.fn((fn: unknown) => fn),
    }));
    const mod = await import("../tmux.js");
    TmuxClient = mod.TmuxClient;
    tmuxSessionName = mod.tmuxSessionName;
    typedMock.mockReset();
    process.env = { ...originalEnv };
    delete process.env.FOREMAN_TMUX_DISABLED;
  });

  afterEach(() => {
    process.env = originalEnv;
    vi.restoreAllMocks();
  });

  // ── TMUX-001: tmux binary not found → fallback to detached ──────────

  describe("TMUX-001: tmux binary not found", () => {
    it("isAvailable() returns false when 'which tmux' fails", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("command not found", 1));
      const client = new TmuxClient();
      const result = await client.isAvailable();
      expect(result).toBe(false);
    });

    it("does not throw — graceful degradation", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("ENOENT: no such file"));
      const client = new TmuxClient();
      await expect(client.isAvailable()).resolves.toBe(false);
    });

    it("caches the false result so subsequent calls do not retry", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("not found"));
      const client = new TmuxClient();
      await client.isAvailable();
      await client.isAvailable();
      await client.isAvailable();
      // Only one call to which tmux
      expect(typedMock).toHaveBeenCalledTimes(1);
    });
  });

  // ── TMUX-002: tmux new-session failed → fallback + warning ──────────

  describe("TMUX-002: tmux new-session failed", () => {
    it("createSession returns { created: false } on failure", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("duplicate session: foreman-abc"));
      const client = new TmuxClient();

      const stderrSpy = vi.spyOn(process.stderr, "write").mockImplementation(() => true);

      const result = await client.createSession({
        sessionName: "foreman-abc",
        command: "echo hello",
        cwd: "/tmp",
      });

      expect(result.created).toBe(false);
      expect(result.sessionName).toBe("foreman-abc");
      stderrSpy.mockRestore();
    });

    it("logs TMUX-002 warning to stderr", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("server exited unexpectedly"));
      const client = new TmuxClient();

      const stderrSpy = vi.spyOn(process.stderr, "write").mockImplementation(() => true);

      await client.createSession({
        sessionName: "foreman-test",
        command: "echo hello",
        cwd: "/tmp",
      });

      expect(stderrSpy).toHaveBeenCalled();
      const output = stderrSpy.mock.calls[0][0] as string;
      expect(output).toContain("TMUX-002");
      expect(output).toContain("foreman-test");
      expect(output).toContain("server exited unexpectedly");
      stderrSpy.mockRestore();
    });

    it("does not throw — graceful degradation", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("tmux server crashed"));
      const client = new TmuxClient();
      const stderrSpy = vi.spyOn(process.stderr, "write").mockImplementation(() => true);

      await expect(
        client.createSession({
          sessionName: "foreman-crash",
          command: "echo hello",
          cwd: "/tmp",
        }),
      ).resolves.toEqual({ sessionName: "foreman-crash", created: false });

      stderrSpy.mockRestore();
    });

    it("handles non-Error throwable in catch", async () => {
      typedMock.mockRejectedValueOnce("string error");
      const client = new TmuxClient();
      const stderrSpy = vi.spyOn(process.stderr, "write").mockImplementation(() => true);

      const result = await client.createSession({
        sessionName: "foreman-str",
        command: "echo hello",
        cwd: "/tmp",
      });

      expect(result.created).toBe(false);
      const output = stderrSpy.mock.calls[0][0] as string;
      expect(output).toContain("string error");
      stderrSpy.mockRestore();
    });

    it("handles timeout errors from execFile", async () => {
      const err = makeExecError("TIMEOUT") as Error & { killed: boolean; signal: string };
      err.killed = true;
      err.signal = "SIGTERM";
      typedMock.mockRejectedValueOnce(err);
      const client = new TmuxClient();
      const stderrSpy = vi.spyOn(process.stderr, "write").mockImplementation(() => true);

      const result = await client.createSession({
        sessionName: "foreman-timeout",
        command: "echo hello",
        cwd: "/tmp",
      });

      expect(result.created).toBe(false);
      stderrSpy.mockRestore();
    });
  });

  // ── TMUX-003: tmux attach-session failed → fallback to claude --resume
  // Note: attach-session is handled by the CLI attach command, not TmuxClient.
  // We test the underlying hasSession() returning false (which triggers the fallback).

  describe("TMUX-003: attach-session failure scenario", () => {
    it("hasSession returns false when session does not exist", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("session not found", 1));
      const client = new TmuxClient();
      const result = await client.hasSession("foreman-dead");
      expect(result).toBe(false);
    });

    it("does not throw on has-session failure — graceful check", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("can't find session: foreman-dead"));
      const client = new TmuxClient();
      await expect(client.hasSession("foreman-dead")).resolves.toBe(false);
    });
  });

  // ── TMUX-004: capture-pane failed → fallback to tailing log file ────

  describe("TMUX-004: capture-pane failed", () => {
    it("capturePaneOutput returns empty array on failure", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("session not found"));
      const client = new TmuxClient();
      const result = await client.capturePaneOutput("foreman-gone");
      expect(result).toEqual([]);
    });

    it("does not throw — returns empty array gracefully", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("can't find pane"));
      const client = new TmuxClient();
      await expect(client.capturePaneOutput("foreman-broken")).resolves.toEqual([]);
    });

    it("handles timeout during capture-pane", async () => {
      const err = makeExecError("TIMEOUT") as Error & { killed: boolean };
      err.killed = true;
      typedMock.mockRejectedValueOnce(err);
      const client = new TmuxClient();
      const result = await client.capturePaneOutput("foreman-slow");
      expect(result).toEqual([]);
    });

    it("returns empty array for whitespace-only output", async () => {
      typedMock.mockResolvedValueOnce({ stdout: "   \n  \n", stderr: "" });
      const client = new TmuxClient();
      const result = await client.capturePaneOutput("foreman-blank");
      expect(result).toEqual([]);
    });
  });

  // ── TMUX-005: kill-session failed → log warning, session may be dead ─

  describe("TMUX-005: kill-session failed", () => {
    it("killSession returns false when session does not exist", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("session not found"));
      const client = new TmuxClient();
      const result = await client.killSession("foreman-nonexistent");
      expect(result).toBe(false);
    });

    it("does not throw — returns false gracefully", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("can't find session: foreman-x"));
      const client = new TmuxClient();
      await expect(client.killSession("foreman-x")).resolves.toBe(false);
    });

    it("handles tmux server not running error", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("no server running on /tmp/tmux-1000/default"));
      const client = new TmuxClient();
      const result = await client.killSession("foreman-orphan");
      expect(result).toBe(false);
    });

    it("handles timeout during kill", async () => {
      const err = makeExecError("TIMEOUT") as Error & { killed: boolean };
      err.killed = true;
      typedMock.mockRejectedValueOnce(err);
      const client = new TmuxClient();
      const result = await client.killSession("foreman-hung");
      expect(result).toBe(false);
    });
  });

  // ── TMUX-006: has-session reports dead session → mark stuck ──────────
  // Note: The actual "mark stuck" logic is in monitor.ts. Here we verify
  // hasSession() correctly returns false for dead sessions.

  describe("TMUX-006: has-session reports dead session", () => {
    it("returns false for a session that has exited", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("session not found", 1));
      const client = new TmuxClient();
      const result = await client.hasSession("foreman-dead-run");
      expect(result).toBe(false);
    });

    it("handles server crash during has-session check", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("server exited unexpectedly"));
      const client = new TmuxClient();
      const result = await client.hasSession("foreman-crashed");
      expect(result).toBe(false);
    });
  });

  // ── TMUX-007: orphaned session detected → report in doctor ──────────
  // Tested via listForemanSessions() returning sessions not matched by active runs.

  describe("TMUX-007: orphaned session detection", () => {
    it("listForemanSessions returns sessions that may be orphaned", async () => {
      const output = [
        "foreman-orphan1 1710000000 0 1",
        "foreman-orphan2 1710000100 0 1",
        "non-foreman 1710000200 0 1",
      ].join("\n");
      typedMock.mockResolvedValueOnce({ stdout: output, stderr: "" });

      const client = new TmuxClient();
      const sessions = await client.listForemanSessions();
      // Only foreman-* sessions returned for orphan detection
      expect(sessions).toHaveLength(2);
      expect(sessions.every((s) => s.sessionName.startsWith("foreman-"))).toBe(true);
    });

    it("returns empty array when tmux server is not running", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("no server running"));
      const client = new TmuxClient();
      const sessions = await client.listForemanSessions();
      expect(sessions).toEqual([]);
    });
  });

  // ── TMUX-008: ghost run detected → report in doctor ─────────────────
  // Ghost = active run record with dead tmux session. hasSession returns false.

  describe("TMUX-008: ghost run detection", () => {
    it("hasSession returns false for ghost run's session name", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("session not found"));
      const client = new TmuxClient();
      const alive = await client.hasSession("foreman-ghost-seed");
      expect(alive).toBe(false);
    });
  });

  // ── TMUX-009: session name collision → kill stale before create ──────

  describe("TMUX-009: session name collision", () => {
    it("killSession succeeds for stale session before new creation", async () => {
      // First call: kill the stale session
      typedMock.mockResolvedValueOnce({ stdout: "", stderr: "" });
      const client = new TmuxClient();
      const killed = await client.killSession("foreman-stale");
      expect(killed).toBe(true);
    });

    it("createSession succeeds after stale session cleanup", async () => {
      const client = new TmuxClient();
      // kill old
      typedMock.mockResolvedValueOnce({ stdout: "", stderr: "" });
      await client.killSession("foreman-reuse");

      // create new
      typedMock.mockResolvedValueOnce({ stdout: "", stderr: "" });
      const result = await client.createSession({
        sessionName: "foreman-reuse",
        command: "echo new",
        cwd: "/tmp",
      });
      expect(result.created).toBe(true);
    });

    it("handles case where stale session does not exist (no-op)", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("session not found"));
      const client = new TmuxClient();
      const killed = await client.killSession("foreman-no-stale");
      expect(killed).toBe(false);
      // Should still be able to create
      typedMock.mockResolvedValueOnce({ stdout: "", stderr: "" });
      const result = await client.createSession({
        sessionName: "foreman-no-stale",
        command: "echo new",
        cwd: "/tmp",
      });
      expect(result.created).toBe(true);
    });
  });

  // ── TMUX-010: tmux version too old → warn in doctor ──────────────────

  describe("TMUX-010: tmux version too old", () => {
    it("getTmuxVersion returns version string for comparison", async () => {
      typedMock.mockResolvedValueOnce({ stdout: "tmux 2.9\n", stderr: "" });
      const client = new TmuxClient();
      const version = await client.getTmuxVersion();
      expect(version).toBe("2.9");
      // Caller (doctor.ts) compares against "3.0"
    });

    it("returns null when tmux is not installed", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("command not found"));
      const client = new TmuxClient();
      const version = await client.getTmuxVersion();
      expect(version).toBeNull();
    });

    it("returns null for completely unexpected output format", async () => {
      typedMock.mockResolvedValueOnce({ stdout: "not-tmux-output\n", stderr: "" });
      const client = new TmuxClient();
      const version = await client.getTmuxVersion();
      expect(version).toBeNull();
    });

    it("returns raw string for non-numeric version (caller must validate)", async () => {
      // "tmux next-3.5-rc" matches the regex ^tmux\s+(\S+)$ — captures "next-3.5-rc"
      typedMock.mockResolvedValueOnce({ stdout: "tmux next-3.5-rc\n", stderr: "" });
      const client = new TmuxClient();
      const version = await client.getTmuxVersion();
      expect(version).toBe("next-3.5-rc");
    });

    it("returns version for well-formed output with letter suffix", async () => {
      typedMock.mockResolvedValueOnce({ stdout: "tmux 3.3a\n", stderr: "" });
      const client = new TmuxClient();
      const version = await client.getTmuxVersion();
      expect(version).toBe("3.3a");
    });
  });

  // ── TMUX-011: FOREMAN_TMUX_DISABLED → skip tmux ──────────────────────

  describe("TMUX-011: FOREMAN_TMUX_DISABLED", () => {
    it("isAvailable returns false immediately when env var is set", async () => {
      process.env.FOREMAN_TMUX_DISABLED = "true";
      vi.resetModules();
      vi.doMock("node:child_process", () => ({ execFile: typedMock }));
      vi.doMock("node:util", () => ({ promisify: vi.fn((fn: unknown) => fn) }));
      const mod = await import("../tmux.js");
      const client = new mod.TmuxClient();

      const result = await client.isAvailable();
      expect(result).toBe(false);
      // Should not call which tmux at all
      expect(typedMock).not.toHaveBeenCalled();
    });

    it("does not cache the disabled state — respects env at call time", async () => {
      // First call with disabled
      process.env.FOREMAN_TMUX_DISABLED = "true";
      vi.resetModules();
      vi.doMock("node:child_process", () => ({ execFile: typedMock }));
      vi.doMock("node:util", () => ({ promisify: vi.fn((fn: unknown) => fn) }));
      const mod = await import("../tmux.js");
      const client = new mod.TmuxClient();

      const result1 = await client.isAvailable();
      expect(result1).toBe(false);

      // After removing the env var, the cached value is still false
      // (because FOREMAN_TMUX_DISABLED=true returns false before caching)
      // But the cache was never set, so removing env var and calling again
      // will actually attempt the which check
      delete process.env.FOREMAN_TMUX_DISABLED;
      typedMock.mockResolvedValueOnce({ stdout: "/usr/bin/tmux\n", stderr: "" });
      // The cache is still null because the early return doesn't set it
      const result2 = await client.isAvailable();
      expect(result2).toBe(true);
    });

    it("other env values do not disable tmux", async () => {
      process.env.FOREMAN_TMUX_DISABLED = "false";
      vi.resetModules();
      vi.doMock("node:child_process", () => ({ execFile: typedMock }));
      vi.doMock("node:util", () => ({ promisify: vi.fn((fn: unknown) => fn) }));
      typedMock.mockReset();
      typedMock.mockResolvedValueOnce({ stdout: "/usr/bin/tmux\n", stderr: "" });
      const mod = await import("../tmux.js");
      const client = new mod.TmuxClient();

      const result = await client.isAvailable();
      expect(result).toBe(true);
    });

    it("empty string does not disable tmux", async () => {
      process.env.FOREMAN_TMUX_DISABLED = "";
      vi.resetModules();
      vi.doMock("node:child_process", () => ({ execFile: typedMock }));
      vi.doMock("node:util", () => ({ promisify: vi.fn((fn: unknown) => fn) }));
      typedMock.mockReset();
      typedMock.mockResolvedValueOnce({ stdout: "/usr/bin/tmux\n", stderr: "" });
      const mod = await import("../tmux.js");
      const client = new mod.TmuxClient();

      const result = await client.isAvailable();
      expect(result).toBe(true);
    });
  });

  // ── TMUX-012: follow mode interrupted → clean exit ───────────────────
  // Follow mode uses capturePaneOutput() in a loop. Interruption is handled
  // by the CLI layer via AbortController. Here we verify the underlying
  // capturePaneOutput does not leave resources dangling.

  describe("TMUX-012: follow mode interruption safety", () => {
    it("capturePaneOutput resolves cleanly even during rapid polling", async () => {
      const client = new TmuxClient();

      // Simulate multiple rapid capture-pane calls
      typedMock.mockResolvedValueOnce({ stdout: "line1\n", stderr: "" });
      typedMock.mockResolvedValueOnce({ stdout: "line1\nline2\n", stderr: "" });
      typedMock.mockRejectedValueOnce(makeExecError("session ended"));

      const r1 = await client.capturePaneOutput("foreman-follow");
      expect(r1).toEqual(["line1"]);

      const r2 = await client.capturePaneOutput("foreman-follow");
      expect(r2).toEqual(["line1", "line2"]);

      // Session ended mid-poll — returns empty, no throw
      const r3 = await client.capturePaneOutput("foreman-follow");
      expect(r3).toEqual([]);
    });

    it("hasSession returns false when session ends (follow loop exit signal)", async () => {
      typedMock.mockRejectedValueOnce(makeExecError("session not found"));
      const client = new TmuxClient();
      const alive = await client.hasSession("foreman-follow-done");
      expect(alive).toBe(false);
    });
  });

  // ── Cross-cutting: no unhandled exceptions ───────────────────────────

  describe("No unhandled exceptions on any method failure", () => {
    it("isAvailable never throws", async () => {
      typedMock.mockRejectedValueOnce(new TypeError("unexpected type error"));
      const client = new TmuxClient();
      await expect(client.isAvailable()).resolves.toBe(false);
    });

    it("createSession never throws", async () => {
      typedMock.mockRejectedValueOnce(new RangeError("out of range"));
      const client = new TmuxClient();
      const stderrSpy = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
      await expect(
        client.createSession({ sessionName: "x", command: "y", cwd: "/tmp" }),
      ).resolves.toEqual({ sessionName: "x", created: false });
      stderrSpy.mockRestore();
    });

    it("killSession never throws", async () => {
      typedMock.mockRejectedValueOnce(new URIError("weird error"));
      const client = new TmuxClient();
      await expect(client.killSession("x")).resolves.toBe(false);
    });

    it("hasSession never throws", async () => {
      typedMock.mockRejectedValueOnce(new SyntaxError("parse error"));
      const client = new TmuxClient();
      await expect(client.hasSession("x")).resolves.toBe(false);
    });

    it("capturePaneOutput never throws", async () => {
      typedMock.mockRejectedValueOnce(new EvalError("eval error"));
      const client = new TmuxClient();
      await expect(client.capturePaneOutput("x")).resolves.toEqual([]);
    });

    it("listForemanSessions never throws", async () => {
      typedMock.mockRejectedValueOnce(new Error("segfault-like error"));
      const client = new TmuxClient();
      await expect(client.listForemanSessions()).resolves.toEqual([]);
    });

    it("getTmuxVersion never throws", async () => {
      typedMock.mockRejectedValueOnce(new Error("pipe broken"));
      const client = new TmuxClient();
      await expect(client.getTmuxVersion()).resolves.toBeNull();
    });
  });
});
