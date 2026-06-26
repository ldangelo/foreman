import { afterEach, describe, expect, it, vi } from "vitest";

const { mockEnsureRunning, mockDoctor } = vi.hoisted(() => ({
  mockEnsureRunning: vi.fn(async () => ({ running: true, url: "http://127.0.0.1:4766" })),
  mockDoctor: vi.fn(async () => ({ ok: true, body: { ok: true, checks: [] } })),
}));

vi.mock("../../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: class MockElixirServerManager {
    ensureRunning = mockEnsureRunning;
    doctor = mockDoctor;
  },
}));

import { runElixirDoctor } from "../doctor.js";

describe("Elixir doctor command", () => {
  afterEach(() => {
    vi.clearAllMocks();
    vi.restoreAllMocks();
  });

  it("runs Elixir server doctor and prints JSON output", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    const exitCode = await runElixirDoctor({ jsonOutput: true });

    expect(exitCode).toBe(0);
    expect(mockEnsureRunning).toHaveBeenCalledOnce();
    expect(mockDoctor).toHaveBeenCalledOnce();
    expect(JSON.parse(String(logSpy.mock.calls[0][0]))).toEqual({ ok: true, checks: [] });
  });

  it("fails closed for legacy maintenance flags in Elixir mode", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    const exitCode = await runElixirDoctor({ fix: true });

    expect(exitCode).toBe(1);
    expect(mockEnsureRunning).not.toHaveBeenCalled();
    expect(mockDoctor).not.toHaveBeenCalled();
    expect(errorSpy.mock.calls.map((call) => call.join("\n")).join("\n")).toContain("legacy Node/Postgres maintenance");
  });

  it("returns failure when Elixir server doctor fails", async () => {
    mockDoctor.mockResolvedValueOnce({ ok: false, error: "not healthy", body: { ok: false } } as never);
    vi.spyOn(console, "log").mockImplementation(() => undefined);

    const exitCode = await runElixirDoctor({ jsonOutput: true });

    expect(exitCode).toBe(1);
  });
});
