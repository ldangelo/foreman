import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Mock setup ──────────────────────────────────────────────────────────────
//
// We mock node:child_process so no real subprocess is spawned.
// vi.hoisted() ensures the mock variable is initialised before the module
// factory runs (vitest hoists vi.mock() calls to the top of the file).

const { mockExecFileSync, mockHomedir } = vi.hoisted(() => ({
  mockExecFileSync: vi.fn(),
  mockHomedir: vi.fn().mockReturnValue("/test/home"),
}));

vi.mock("node:child_process", () => ({
  execFileSync: mockExecFileSync,
}));

vi.mock("node:os", () => ({
  homedir: mockHomedir,
}));

import { closeSeed, resetSeedToOpen } from "../task-backend-ops.js";

// ── Helpers ──────────────────────────────────────────────────────────────────

const HOME = "/test/home";

// ── closeSeed ────────────────────────────────────────────────────────────────

describe("closeSeed — sd backend (default)", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    delete process.env.FOREMAN_TASK_BACKEND;
    process.env.HOME = HOME;
  });

  afterEach(() => {
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  // TRD-023: default changed from 'sd' to 'br'
  it("defaults to br backend when FOREMAN_TASK_BACKEND is not set", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));
    // env var is not set (deleted in beforeEach)

    closeSeed("task-xyz-999");

    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args[0]).toBe("close");
  });

});

describe("closeSeed — br backend", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    process.env.FOREMAN_TASK_BACKEND = "br";
    process.env.HOME = HOME;
  });

  afterEach(() => {
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  it("calls br close with seedId and --reason flag", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    closeSeed("bd-abc-001");

    expect(mockExecFileSync).toHaveBeenCalledOnce();
    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args).toEqual(["close", "bd-abc-001", "--reason", "Completed via pipeline"]);
  });

  it("uses ~/.local/bin/br path for br backend", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    closeSeed("bd-abc-001");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toBe(`${HOME}/.local/bin/br`);
  });

  it("does not call sd when backend is br", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    closeSeed("bd-abc-001");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).not.toContain("sd");
    expect(cmd).not.toContain(".bun");
  });

  it("does not throw when br close fails (error suppressed)", () => {
    mockExecFileSync.mockImplementation(() => { throw new Error("br binary missing"); });

    // Must not throw — errors should be caught and logged
    expect(() => closeSeed("bd-fail-002")).not.toThrow();
  });

  it("passes the correct --reason text", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    closeSeed("bd-reason-test");

    const [, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    const reasonIdx = args.indexOf("--reason");
    expect(reasonIdx).toBeGreaterThanOrEqual(0);
    expect(args[reasonIdx + 1]).toBe("Completed via pipeline");
  });
});

// ── resetSeedToOpen ──────────────────────────────────────────────────────────

describe("resetSeedToOpen — sd backend (default)", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    delete process.env.FOREMAN_TASK_BACKEND;
    process.env.HOME = HOME;
  });

  afterEach(() => {
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  // TRD-023: default changed from 'sd' to 'br'
  it("defaults to br backend when FOREMAN_TASK_BACKEND is not set", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    resetSeedToOpen("task-xyz-999");

    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args[0]).toBe("update");
    expect(args).toContain("open");
  });

});

describe("resetSeedToOpen — br backend", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    process.env.FOREMAN_TASK_BACKEND = "br";
    process.env.HOME = HOME;
  });

  afterEach(() => {
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  it("calls br update with --status open", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    resetSeedToOpen("bd-stuck-001");

    expect(mockExecFileSync).toHaveBeenCalledOnce();
    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args).toEqual(["update", "bd-stuck-001", "--status", "open"]);
  });

  it("uses ~/.local/bin/br path for br backend", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    resetSeedToOpen("bd-stuck-001");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toBe(`${HOME}/.local/bin/br`);
  });

  it("does not call sd when backend is br", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    resetSeedToOpen("bd-stuck-001");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).not.toContain("sd");
    expect(cmd).not.toContain(".bun");
  });

  it("does not throw when br update fails (error suppressed)", () => {
    mockExecFileSync.mockImplementation(() => { throw new Error("br binary missing"); });

    expect(() => resetSeedToOpen("bd-fail-002")).not.toThrow();
  });

  it("passes --status open as the status value", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    resetSeedToOpen("bd-status-test");

    const [, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    const statusIdx = args.indexOf("--status");
    expect(statusIdx).toBeGreaterThanOrEqual(0);
    expect(args[statusIdx + 1]).toBe("open");
  });
});

// ── HOME fallback ────────────────────────────────────────────────────────────

describe("closeSeed / resetSeedToOpen — homedir() path resolution", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    mockExecFileSync.mockReturnValue(Buffer.from(""));
    mockHomedir.mockReturnValue("/fallback/home");
  });

  afterEach(() => {
    delete process.env.FOREMAN_TASK_BACKEND;
    mockHomedir.mockReturnValue("/test/home");
  });

  it("closeSeed uses os.homedir() for br path", () => {
    process.env.FOREMAN_TASK_BACKEND = "br";

    closeSeed("bd-no-home");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toBe("/fallback/home/.local/bin/br");
  });

  it("resetSeedToOpen uses os.homedir() for br path", () => {
    process.env.FOREMAN_TASK_BACKEND = "br";

    resetSeedToOpen("bd-no-home");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toBe("/fallback/home/.local/bin/br");
  });
});
