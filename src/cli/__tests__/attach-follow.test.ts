import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir, homedir } from "node:os";
import { ForemanStore, type Run } from "../../lib/store.js";

/**
 * Tests for --follow mode (log-file tail based).
 */

// ── Mock child_process ────────────────────────────────────────────────

const mockSpawn = vi.fn();

vi.mock("node:child_process", () => ({
  spawn: (...args: unknown[]) => mockSpawn(...args),
}));

// ── Helpers ──────────────────────────────────────────────────────────

function createTestRun(
  store: ForemanStore,
  projectId: string,
  overrides: Partial<{
    seedId: string;
    status: Run["status"];
    sessionKey: string | null;
    worktreePath: string | null;
  }> = {},
): Run {
  const seedId = overrides.seedId ?? "test-seed";
  const run = store.createRun(projectId, seedId, "claude-sonnet-4-6", overrides.worktreePath ?? "/tmp/wt");
  const updates: Partial<Pick<Run, "status" | "session_key">> = {};
  if (overrides.status) updates.status = overrides.status;
  if (overrides.sessionKey !== undefined) updates.session_key = overrides.sessionKey;
  if (Object.keys(updates).length > 0) store.updateRun(run.id, updates);
  return store.getRun(run.id)!;
}

// ── Test suite ──────────────────────────────────────────────────────

describe("--follow mode (log file tail)", () => {
  let tmpDir: string;
  let store: ForemanStore;
  let projectId: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-follow-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
    const project = store.registerProject("test-project", tmpDir);
    projectId = project.id;
    mockSpawn.mockReset();
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("tails the log file with -f flag", async () => {
    const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

    const run = createTestRun(store, projectId, {
      seedId: "follow-test",
      status: "running",
    });

    const mockChild = {
      on: vi.fn((event: string, cb: (arg: unknown) => void) => {
        if (event === "exit") setTimeout(() => cb(0), 10);
        return mockChild;
      }),
      kill: vi.fn(),
    };
    mockSpawn.mockReturnValue(mockChild);

    const { attachAction } = await import("../commands/attach.js");
    const exitCode = await attachAction("follow-test", { follow: true }, store, tmpDir);

    const logPath = join(homedir(), ".foreman", "logs", `${run.id}.out`);
    expect(mockSpawn).toHaveBeenCalledWith(
      "tail",
      ["-f", logPath],
      expect.objectContaining({ stdio: "inherit" }),
    );
    expect(exitCode).toBe(0);

    consoleSpy.mockRestore();
  });

  it("prints log path header before following", async () => {
    const consoleErrSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    createTestRun(store, projectId, {
      seedId: "follow-header",
      status: "running",
    });

    const mockChild = {
      on: vi.fn((event: string, cb: (arg: unknown) => void) => {
        if (event === "exit") setTimeout(() => cb(0), 10);
        return mockChild;
      }),
      kill: vi.fn(),
    };
    mockSpawn.mockReturnValue(mockChild);

    const { attachAction } = await import("../commands/attach.js");
    await attachAction("follow-header", { follow: true }, store, tmpDir);

    const output = consoleErrSpy.mock.calls.map((c) => String(c[0])).join("\n");
    expect(output).toContain("follow-header");
    expect(output).toContain("Log:");

    consoleErrSpy.mockRestore();
  });

  it("returns interrupted exit code when AbortSignal fires (kills child)", async () => {
    const consoleErrSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    createTestRun(store, projectId, {
      seedId: "abort-follow",
      status: "running",
    });

    let exitCb: ((code: unknown) => void) | null = null;
    const mockChild = {
      on: vi.fn((event: string, cb: (arg: unknown) => void) => {
        if (event === "exit") exitCb = cb;
        return mockChild;
      }),
      kill: vi.fn(() => {
        // Simulate process exit after kill
        setTimeout(() => exitCb?.(0), 10);
      }),
    };
    mockSpawn.mockReturnValue(mockChild);

    const { attachAction } = await import("../commands/attach.js");

    const controller = new AbortController();
    const resultPromise = attachAction(
      "abort-follow",
      { follow: true, _signal: controller.signal },
      store,
      tmpDir,
    );

    // Abort after a short delay
    await new Promise((r) => setTimeout(r, 50));
    controller.abort();

    const exitCode = await resultPromise;
    expect(exitCode).toBe(130);
    expect(mockChild.kill).toHaveBeenCalledWith("SIGTERM");

    const output = consoleErrSpy.mock.calls.map((c) => String(c[0])).join("\n");
    expect(output).toContain("interrupted before the run reached a terminal state");

    consoleErrSpy.mockRestore();
  });

  it("handles error when log file does not exist", async () => {
    const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const consoleErrSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    createTestRun(store, projectId, {
      seedId: "no-log",
      status: "running",
    });

    const mockChild = {
      on: vi.fn((event: string, cb: (arg: unknown) => void) => {
        if (event === "error") setTimeout(() => cb(new Error("ENOENT")), 10);
        return mockChild;
      }),
      kill: vi.fn(),
    };
    mockSpawn.mockReturnValue(mockChild);

    const { attachAction } = await import("../commands/attach.js");
    const exitCode = await attachAction("no-log", { follow: true }, store, tmpDir);

    expect(exitCode).toBe(1);

    consoleSpy.mockRestore();
    consoleErrSpy.mockRestore();
  });
});
