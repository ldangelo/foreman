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

import { closeSeed, resetSeedToOpen, addLabelsToBead } from "../task-backend-ops.js";

// ── Helpers ──────────────────────────────────────────────────────────────────

const HOME = "/test/home";

// ── closeSeed ────────────────────────────────────────────────────────────────

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

  it("defaults to br backend when FOREMAN_TASK_BACKEND is not set", () => {
    delete process.env.FOREMAN_TASK_BACKEND;
    mockExecFileSync.mockReturnValue(Buffer.from(""));
    closeSeed("task-xyz-999");
    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args[0]).toBe("close");
  });
});

// ── resetSeedToOpen ──────────────────────────────────────────────────────────

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

  it("defaults to br backend when FOREMAN_TASK_BACKEND is not set", () => {
    delete process.env.FOREMAN_TASK_BACKEND;
    mockExecFileSync.mockReturnValue(Buffer.from(""));
    resetSeedToOpen("task-xyz-999");
    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args[0]).toBe("update");
    expect(args).toContain("open");
  });
});

// ── projectPath (cwd) — the core bug fix ─────────────────────────────────────
//
// br reads .beads/ from the CWD. Worker processes run from the worktree
// directory, which has no .beads/ directory.  Without an explicit cwd the
// br subprocess silently fails (error is caught), so beads are never closed.
// Fix: closeSeed / resetSeedToOpen must accept a projectPath and forward it
// as the cwd in execFileSync options.

describe("closeSeed — projectPath forwarded as cwd", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    mockExecFileSync.mockReturnValue(Buffer.from(""));
    process.env.HOME = HOME;
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  it("passes projectPath as cwd to execFileSync", () => {
    closeSeed("bd-cwd-001", "/my/project/root");

    const [, , opts] = mockExecFileSync.mock.calls[0] as [string, string[], Record<string, unknown>];
    expect(opts.cwd).toBe("/my/project/root");
  });

  it("omits cwd when projectPath is not provided", () => {
    closeSeed("bd-cwd-002");

    const [, , opts] = mockExecFileSync.mock.calls[0] as [string, string[], Record<string, unknown>];
    expect(opts.cwd).toBeUndefined();
  });
});

describe("resetSeedToOpen — projectPath forwarded as cwd", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    mockExecFileSync.mockReturnValue(Buffer.from(""));
    process.env.HOME = HOME;
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  it("passes projectPath as cwd to execFileSync", () => {
    resetSeedToOpen("bd-reset-cwd-001", "/my/project/root");

    const [, , opts] = mockExecFileSync.mock.calls[0] as [string, string[], Record<string, unknown>];
    expect(opts.cwd).toBe("/my/project/root");
  });

  it("omits cwd when projectPath is not provided", () => {
    resetSeedToOpen("bd-reset-cwd-002");

    const [, , opts] = mockExecFileSync.mock.calls[0] as [string, string[], Record<string, unknown>];
    expect(opts.cwd).toBeUndefined();
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

// ── addLabelsToBead ───────────────────────────────────────────────────────────

describe("addLabelsToBead — br backend", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    process.env.HOME = HOME;
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  it("calls br update with --labels flag and comma-separated labels", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    addLabelsToBead("bd-abc-001", ["phase:explorer"]);

    expect(mockExecFileSync).toHaveBeenCalledOnce();
    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args).toEqual(["update", "bd-abc-001", "--labels", "phase:explorer"]);
  });

  it("joins multiple labels with comma", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    addLabelsToBead("bd-abc-002", ["phase:developer", "phase:qa"]);

    const [, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    const labelsIdx = args.indexOf("--labels");
    expect(labelsIdx).toBeGreaterThanOrEqual(0);
    expect(args[labelsIdx + 1]).toBe("phase:developer,phase:qa");
  });

  it("uses ~/.local/bin/br path", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    addLabelsToBead("bd-abc-003", ["phase:reviewer"]);

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toBe(`${HOME}/.local/bin/br`);
  });

  it("does not throw when br update --labels fails (error suppressed)", () => {
    mockExecFileSync.mockImplementation(() => { throw new Error("br binary missing"); });

    expect(() => addLabelsToBead("bd-fail-003", ["phase:explorer"])).not.toThrow();
  });

  it("does nothing when labels array is empty", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    addLabelsToBead("bd-abc-004", []);

    expect(mockExecFileSync).not.toHaveBeenCalled();
  });

  it("passes projectPath as cwd to execFileSync", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    addLabelsToBead("bd-cwd-003", ["phase:explorer"], "/my/project/root");

    const [, , opts] = mockExecFileSync.mock.calls[0] as [string, string[], Record<string, unknown>];
    expect(opts.cwd).toBe("/my/project/root");
  });

  it("omits cwd when projectPath is not provided", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    addLabelsToBead("bd-cwd-004", ["phase:qa"]);

    const [, , opts] = mockExecFileSync.mock.calls[0] as [string, string[], Record<string, unknown>];
    expect(opts.cwd).toBeUndefined();
  });
});
