import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DaemonAlreadyRunningError, DaemonNotRunningError } from "../../lib/daemon-manager.js";

const {
  mockNodeDaemonAllowed,
  mockNodeDaemonDisabledMessage,
  mockExistsSync,
  mockReadFileSync,
  mockIsRunning,
  mockStatus,
  mockStart,
  mockStop,
} = vi.hoisted(() => ({
  mockNodeDaemonAllowed: vi.fn(),
  mockNodeDaemonDisabledMessage: vi.fn(),
  mockExistsSync: vi.fn(),
  mockReadFileSync: vi.fn(),
  mockIsRunning: vi.fn(),
  mockStatus: vi.fn(),
  mockStart: vi.fn(),
  mockStop: vi.fn(),
}));

vi.mock("../../lib/backend-mode.js", () => ({
  nodeDaemonAllowed: (...args: unknown[]) => mockNodeDaemonAllowed(...args),
  nodeDaemonDisabledMessage: (...args: unknown[]) => mockNodeDaemonDisabledMessage(...args),
}));

vi.mock("node:fs", async (importOriginal) => ({
  ...(await importOriginal<typeof import("node:fs")>()),
  existsSync: (...args: unknown[]) => mockExistsSync(...args),
  readFileSync: (...args: unknown[]) => mockReadFileSync(...args),
}));

vi.mock("../../lib/daemon-manager.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../lib/daemon-manager.js")>();
  return {
    ...actual,
    DaemonManager: vi.fn().mockImplementation(function MockDaemonManager(opts: { socketPath?: string; pidPath?: string }) {
      return {
        socketPath: opts.socketPath ?? "/tmp/foreman.sock",
        pidPath: opts.pidPath ?? "/tmp/foreman.pid",
        stderrPath: "/tmp/foreman.stderr.log",
        isRunning: mockIsRunning,
        status: mockStatus,
        start: mockStart,
        stop: mockStop,
      };
    }),
  };
});

class ExitError extends Error {
  constructor(readonly code?: number) {
    super(`process.exit(${code ?? ""})`);
  }
}

async function invokeSubcommand(args: string[]): Promise<ExitError | null> {
  try {
    const { daemonCommand } = await import("../commands/daemon.js");
    await daemonCommand.parseAsync(args, { from: "user" });
    return null;
  } catch (err) {
    if (err instanceof ExitError) return err;
    throw err;
  }
}

describe("daemon command actions", () => {
  let exitSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.useFakeTimers();
    vi.resetModules();
    vi.clearAllMocks();
    mockNodeDaemonAllowed.mockReturnValue(true);
    mockNodeDaemonDisabledMessage.mockReturnValue("Node daemon disabled in Elixir mode");
    mockExistsSync.mockReset();
    mockReadFileSync.mockReset();
    mockIsRunning.mockReset();
    mockStatus.mockReset();
    mockStart.mockReset();
    mockStop.mockReset();
    mockExistsSync.mockReturnValue(false);
    mockReadFileSync.mockReturnValue("");
    mockIsRunning.mockReturnValue(false);
    mockStatus.mockReturnValue({ running: false, pid: null, socketPath: "/tmp/foreman.sock" });
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new ExitError(code);
    }) as never);
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("fails closed on daemon start when node daemon mode is disabled", async () => {
    mockNodeDaemonAllowed.mockReturnValue(false);

    const exit = await invokeSubcommand(["start"]);

    expect(exit?.code).toBe(1);
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("Node daemon disabled in Elixir mode");
  });

  it("reports an already running daemon before trying to start", async () => {
    mockIsRunning.mockReturnValue(true);
    mockStatus.mockReturnValue({ running: true, pid: 1234, socketPath: "/tmp/foreman.sock" });

    const exit = await invokeSubcommand(["start", "--socket-path", "/tmp/foreman.sock"]);

    expect(exit?.code).toBe(1);
    expect(mockStart).not.toHaveBeenCalled();
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("daemon is already running");
  });

  it("shows a stderr excerpt when the daemon exits before startup completes", async () => {
    mockIsRunning
      .mockReturnValueOnce(false)
      .mockReturnValueOnce(false);
    mockExistsSync.mockReturnValue(true);
    mockReadFileSync.mockReturnValue("line1\nline2\nline3\nline4\nline5\nline6\n");

    const run = invokeSubcommand(["start"]);
    await vi.runAllTimersAsync();
    const exit = await run;

    expect(exit?.code).toBe(1);
    expect(mockStart).toHaveBeenCalledOnce();
    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("daemon exited before startup completed");
    expect(rendered).toContain("line2\nline3\nline4\nline5\nline6");
  });

  it("handles DaemonAlreadyRunningError races during start", async () => {
    mockIsRunning.mockReturnValue(false);
    mockStart.mockImplementation(() => {
      throw new DaemonAlreadyRunningError(4321);
    });

    const exit = await invokeSubcommand(["start"]);

    expect(exit?.code).toBe(1);
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("PID: 4321");
  });

  it("renders daemon status as JSON", async () => {
    mockStatus.mockReturnValue({ running: true, pid: 999, socketPath: "/tmp/custom.sock" });

    await invokeSubcommand(["status", "--json", "--socket-path", "/tmp/custom.sock"]);

    expect(vi.mocked(console.log)).toHaveBeenCalledWith(JSON.stringify({
      running: true,
      pid: 999,
      socketPath: "/tmp/custom.sock",
    }, null, 2));
  });

  it("renders daemon status in text mode", async () => {
    mockStatus.mockReturnValue({ running: false, pid: null, socketPath: "/tmp/custom.sock" });

    await invokeSubcommand(["status", "--socket-path", "/tmp/custom.sock"]);

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Daemon status:");
    expect(rendered).toContain("/tmp/custom.sock");
  });

  it("fails stop when the daemon is not running", async () => {
    mockIsRunning.mockReturnValue(false);

    const exit = await invokeSubcommand(["stop"]);

    expect(exit?.code).toBe(1);
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("daemon is not running");
  });

  it("stops the daemon successfully", async () => {
    mockIsRunning.mockReturnValue(true);

    const exit = await invokeSubcommand(["stop", "--socket-path", "/tmp/custom.sock"]);

    expect(exit).toBeNull();
    expect(mockStop).toHaveBeenCalledOnce();
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("✓ Daemon stopped.");
    expect(rendered).toContain("/tmp/custom.sock");
  });

  it("reports generic stop failures", async () => {
    mockIsRunning.mockReturnValue(true);
    mockStop.mockImplementation(() => {
      throw new Error("permission denied");
    });

    const exit = await invokeSubcommand(["stop"]);

    expect(exit?.code).toBe(1);
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("failed to stop daemon: permission denied");
  });

  it("fails restart when node daemon mode is disabled", async () => {
    mockNodeDaemonAllowed.mockReturnValue(false);

    const exit = await invokeSubcommand(["restart"]);

    expect(exit?.code).toBe(1);
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(mockStart).not.toHaveBeenCalled();
  });

  it("restarts even when stop emits a warning", async () => {
    vi.useRealTimers();
    mockIsRunning.mockReturnValue(true);
    mockStop.mockImplementation(() => {
      throw new Error("stuck pid");
    });

    const exit = await invokeSubcommand(["restart", "--socket-path", "/tmp/custom.sock"]);

    expect(exit).toBeNull();
    expect(mockStart).toHaveBeenCalledOnce();
    const renderedErr = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    const renderedLog = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(renderedErr).toContain("Warning: stop failed: stuck pid");
    expect(renderedLog).toContain("✓ Daemon started.");
  });

  it("reports generic start failures during restart", async () => {
    mockIsRunning.mockReturnValue(false);
    mockStart.mockImplementation(() => {
      throw new Error("boot failed");
    });

    const exit = await invokeSubcommand(["restart"]);

    expect(exit?.code).toBe(1);
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("failed to start daemon: boot failed");
  });

  it("maps DaemonNotRunningError during stop to the friendly message", async () => {
    mockIsRunning.mockReturnValue(true);
    mockStop.mockImplementation(() => {
      throw new DaemonNotRunningError();
    });

    const exit = await invokeSubcommand(["stop"]);

    expect(exit?.code).toBe(1);
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("daemon is not running");
  });

  it("reports generic start failures on start", async () => {
    mockIsRunning.mockReturnValue(false);
    mockStart.mockImplementation(() => {
      throw new Error("boom");
    });

    const exit = await invokeSubcommand(["start"]);

    expect(exit?.code).toBe(1);
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("failed to start daemon: boom");
  });
});
