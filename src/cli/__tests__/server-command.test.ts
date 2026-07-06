import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockEnsureRunning,
  mockStatus,
  mockHealth,
  mockDoctor,
  mockStop,
} = vi.hoisted(() => ({
  mockEnsureRunning: vi.fn(),
  mockStatus: vi.fn(),
  mockHealth: vi.fn(),
  mockDoctor: vi.fn(),
  mockStop: vi.fn(),
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn().mockImplementation(function MockElixirServerManager() {
    return {
      ensureRunning: mockEnsureRunning,
      status: mockStatus,
      health: mockHealth,
      doctor: mockDoctor,
      stop: mockStop,
    };
  }),
}));

import { serverCommand } from "../commands/server.js";

async function runServer(args: string[]): Promise<void> {
  await serverCommand.parseAsync(args, { from: "user" });
}

describe("server command", () => {
  let exitSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1234 });
    mockStatus.mockReturnValue({ running: true, url: "http://127.0.0.1:4766", pid: 1234 });
    mockHealth.mockResolvedValue({ ok: true });
    mockDoctor.mockResolvedValue({ ok: true, body: { checks: ["ok"] } });
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("starts the Elixir server and prints url/pid", async () => {
    await runServer(["start", "--port", "4766"]);

    expect(mockEnsureRunning).toHaveBeenCalledOnce();
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("✓ Elixir server running");
    expect(rendered).toContain("http://127.0.0.1:4766");
    expect(rendered).toContain("1234");
  });

  it("fails start with a friendly error", async () => {
    mockEnsureRunning.mockRejectedValue(new Error("boot failed"));

    await expect(runServer(["start"])).rejects.toThrow("process.exit(1)");

    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("failed to start Elixir server: boot failed");
  });

  it("shows running status when health is ok", async () => {
    await runServer(["status"]);

    expect(mockStatus).toHaveBeenCalledOnce();
    expect(mockHealth).toHaveBeenCalledOnce();
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("● running");
    expect(rendered).toContain("URL: http://127.0.0.1:4766");
  });

  it("shows stopped status when health is not ok", async () => {
    mockHealth.mockResolvedValue({ ok: false });
    mockStatus.mockReturnValue({ running: false, url: "http://127.0.0.1:4766", pid: null });

    await runServer(["status"]);

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("○ stopped");
    expect(rendered).not.toContain("PID:");
  });

  it("runs doctor with auto-start by default", async () => {
    await runServer(["doctor"]);

    expect(mockEnsureRunning).toHaveBeenCalledOnce();
    expect(mockDoctor).toHaveBeenCalledOnce();
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Elixir server doctor: PASS");
    expect(rendered).toContain("checks");
  });

  it("skips auto-start for doctor when --no-auto-start is passed", async () => {
    await runServer(["doctor", "--no-auto-start"]);

    expect(mockEnsureRunning).not.toHaveBeenCalled();
    expect(mockDoctor).toHaveBeenCalledOnce();
  });

  it("fails doctor when readiness check is not ok", async () => {
    mockDoctor.mockResolvedValue({ ok: false, error: "missing env", body: { hint: "set FOO" } });

    await expect(runServer(["doctor"])).rejects.toThrow("process.exit(1)");

    expect(exitSpy).toHaveBeenCalledWith(1);
    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Elixir server doctor: FAIL");
    expect(rendered).toContain("missing env");
  });

  it("stops the Elixir server", async () => {
    await runServer(["stop"]);

    expect(mockStop).toHaveBeenCalledOnce();
    expect(vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("✓ Elixir server stopped");
  });
});
