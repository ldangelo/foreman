import { afterEach, describe, expect, it, vi } from "vitest";

const { mockEnsureRunning, mockDoctor, mockPurgeLogsElixirDryRun } = vi.hoisted(() => ({
  mockEnsureRunning: vi.fn(async () => ({ running: true, url: "http://127.0.0.1:4766" })),
  mockDoctor: vi.fn(async () => ({ ok: true, body: { ok: true, checks: { db: { ok: true, message: "event store readable" } }, metrics: { projection_lag: 0 } } })),
  mockPurgeLogsElixirDryRun: vi.fn(async () => 0),
}));

vi.mock("../../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: class MockElixirServerManager {
    ensureRunning = mockEnsureRunning;
    doctor = mockDoctor;
  },
}));

vi.mock("../purge-logs.js", () => ({
  purgeLogsAction: vi.fn(),
  purgeLogsElixirDryRun: mockPurgeLogsElixirDryRun,
}));

import { runElixirDoctor } from "../doctor.js";

describe("Elixir doctor command", () => {
  afterEach(() => {
    vi.clearAllMocks();
    vi.restoreAllMocks();
  });

  it("renders human output by default", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    const exitCode = await runElixirDoctor({});

    expect(exitCode).toBe(0);
    expect(mockEnsureRunning).toHaveBeenCalledOnce();
    expect(mockDoctor).toHaveBeenCalledOnce();
    const output = logSpy.mock.calls.map((call) => call.join(" ")).join("\n");
    expect(output).toContain("Elixir server doctor: PASS");
    expect(output).toContain("Health checks:");
    expect(output).toContain("db");
    expect(output).not.toContain('"checks"');
  });

  it("runs Elixir server doctor and prints JSON output", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    const exitCode = await runElixirDoctor({ jsonOutput: true });

    expect(exitCode).toBe(0);
    expect(mockEnsureRunning).toHaveBeenCalledOnce();
    expect(mockDoctor).toHaveBeenCalledOnce();
    expect(JSON.parse(String(logSpy.mock.calls[0][0]))).toEqual({ ok: true, checks: { db: { ok: true, message: "event store readable" } }, metrics: { projection_lag: 0 } });
  });

  it("prints raw Elixir doctor output", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    const exitCode = await runElixirDoctor({ rawOutput: true });

    expect(exitCode).toBe(0);
    expect(JSON.parse(String(logSpy.mock.calls[0][0]))).toEqual({ ok: true, checks: { db: { ok: true, message: "event store readable" } }, metrics: { projection_lag: 0 } });
  });

  it("fails closed for legacy maintenance flags in Elixir mode", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    const exitCode = await runElixirDoctor({ fix: true });

    expect(exitCode).toBe(1);
    expect(mockEnsureRunning).not.toHaveBeenCalled();
    expect(mockDoctor).not.toHaveBeenCalled();
    expect(errorSpy.mock.calls.map((call) => call.join("\n")).join("\n")).toContain("legacy Node/Postgres maintenance");
  });

  it("delegates clean-log dry-run to Elixir purge preview", async () => {
    const exitCode = await runElixirDoctor({ cleanLogs: true, dryRun: true, logDays: 30 });

    expect(exitCode).toBe(0);
    expect(mockPurgeLogsElixirDryRun).toHaveBeenCalledWith({ dryRun: true, days: 30 });
    expect(mockEnsureRunning).not.toHaveBeenCalled();
    expect(mockDoctor).not.toHaveBeenCalled();
  });

  it("returns failure when Elixir server doctor fails", async () => {
    mockDoctor.mockResolvedValueOnce({ ok: false, error: "not healthy", body: { ok: false } } as never);
    vi.spyOn(console, "log").mockImplementation(() => undefined);

    const exitCode = await runElixirDoctor({ jsonOutput: true });

    expect(exitCode).toBe(1);
  });
});
