import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DaemonNotRunningError } from "../../lib/daemon-manager.js";

const {
  mockIsRunning,
  mockStatus,
  mockStop,
} = vi.hoisted(() => ({
  mockIsRunning: vi.fn(),
  mockStatus: vi.fn(),
  mockStop: vi.fn(),
}));

vi.mock("../../lib/daemon-manager.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../lib/daemon-manager.js")>();
  return {
    ...actual,
    DaemonManager: vi.fn().mockImplementation(function MockDaemonManager(opts: { socketPath?: string; pidPath?: string }) {
      return {
        socketPath: opts.socketPath ?? "/tmp/foreman.sock",
        pidPath: opts.pidPath ?? "/tmp/foreman.pid",
        isRunning: mockIsRunning,
        status: mockStatus,
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
    vi.resetModules();
    vi.clearAllMocks();
    mockIsRunning.mockReturnValue(false);
    mockStatus.mockReturnValue({ running: false, pid: null, socketPath: "/tmp/foreman.sock" });
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new ExitError(code);
    }) as never);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("removes daemon start without legacy backend guidance", async () => {
    const exit = await invokeSubcommand(["start", "--socket-path", "/tmp/foreman.sock"]);

    expect(exit?.code).toBe(1);
    expect(exitSpy).toHaveBeenCalledWith(1);
    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("removed after the Elixir backend cutover");
    expect(rendered).toContain("foreman server start");
    expect(rendered).not.toContain("FOREMAN_BACKEND=node");
  });

  it("removes daemon restart without legacy backend guidance", async () => {
    const exit = await invokeSubcommand(["restart"]);

    expect(exit?.code).toBe(1);
    expect(exitSpy).toHaveBeenCalledWith(1);
    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("removed after the Elixir backend cutover");
    expect(rendered).not.toContain("FOREMAN_BACKEND=node");
  });

  it("renders daemon status as JSON for stray legacy process inspection", async () => {
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

  it("stops a stray legacy daemon successfully", async () => {
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
});
