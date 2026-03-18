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

vi.mock("node:child_process", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  return { ...actual, execFileSync: mockExecFileSync };
});

vi.mock("node:os", () => ({
  homedir: mockHomedir,
}));

vi.mock("../../lib/beads-rust.js", () => ({
  execBr: mockExecBr,
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

  it("calls br close with seedId and --reason flag", async () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    await closeSeed("bd-abc-001");

    // First call is close, second is sync --flush-only
    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args).toEqual(["close", "bd-abc-001", "--reason", "Completed via pipeline"]);
  });

  it("uses ~/.local/bin/br path for br backend", async () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    await closeSeed("bd-abc-001");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toBe(`${HOME}/.local/bin/br`);
  });

  it("does not call sd when backend is br", async () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    await closeSeed("bd-abc-001");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).not.toContain("sd");
    expect(cmd).not.toContain(".bun");
  });

  it("does not throw when br close fails (error suppressed)", async () => {
    mockExecFileSync.mockImplementation(() => { throw new Error("br binary missing"); });

    // Must not reject — errors should be caught and logged
    await expect(closeSeed("bd-fail-002")).resolves.toBeUndefined();
  });

  it("passes the correct --reason text", async () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    await closeSeed("bd-reason-test");

    const [, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    const reasonIdx = args.indexOf("--reason");
    expect(reasonIdx).toBeGreaterThanOrEqual(0);
    expect(args[reasonIdx + 1]).toBe("Completed via pipeline");
  });

  it("defaults to br backend when FOREMAN_TASK_BACKEND is not set", async () => {
    delete process.env.FOREMAN_TASK_BACKEND;
    mockExecFileSync.mockReturnValue(Buffer.from(""));
    await closeSeed("task-xyz-999");
    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args[0]).toBe("close");
  });

  it("calls br sync --flush-only after closing seed", async () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    await closeSeed("bd-flush-test", "/my/project");

    // execFileSync called twice: first for close, then for sync --flush-only
    expect(mockExecFileSync).toHaveBeenCalledTimes(2);
    const [, syncArgs, syncOpts] = mockExecFileSync.mock.calls[1] as [string, string[], Record<string, unknown>];
    expect(syncArgs).toEqual(["sync", "--flush-only"]);
    expect(syncOpts).toMatchObject({ cwd: "/my/project" });
  });

  it("calls br sync --flush-only with undefined projectPath when not provided", async () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    await closeSeed("bd-flush-no-path");

    expect(mockExecFileSync).toHaveBeenCalledTimes(2);
    const [, syncArgs, syncOpts] = mockExecFileSync.mock.calls[1] as [string, string[], Record<string, unknown>];
    expect(syncArgs).toEqual(["sync", "--flush-only"]);
    expect(syncOpts).not.toHaveProperty("cwd");
  });

  it("does not throw when br sync --flush-only fails (flush is non-fatal)", async () => {
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (args[0] === "sync") throw new Error("sync failed");
      return Buffer.from("");
    });

    // Must not reject even if flush fails
    await expect(closeSeed("bd-fail-sync", "/my/project")).resolves.toBeUndefined();
  });

  it("does not call br sync --flush-only when br close fails", async () => {
    mockExecFileSync.mockImplementation(() => { throw new Error("br binary missing"); });

    await closeSeed("bd-close-fail-no-flush");

    // Only the (failed) close call was made — sync should not have been called
    const syncCalls = mockExecFileSync.mock.calls.filter(
      (call) => Array.isArray(call[1]) && (call[1] as string[])[0] === "sync",
    );
    expect(syncCalls).toHaveLength(0);
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

  it("calls br update with --status open", async () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    await resetSeedToOpen("bd-stuck-001");

    // First call is update, second is sync --flush-only
    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args).toEqual(["update", "bd-stuck-001", "--status", "open"]);
  });

  it("uses ~/.local/bin/br path for br backend", async () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    await resetSeedToOpen("bd-stuck-001");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toBe(`${HOME}/.local/bin/br`);
  });

  it("does not call sd when backend is br", async () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    await resetSeedToOpen("bd-stuck-001");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).not.toContain("sd");
    expect(cmd).not.toContain(".bun");
  });

  it("does not throw when br update fails (error suppressed)", async () => {
    mockExecFileSync.mockImplementation(() => { throw new Error("br binary missing"); });

    // Must not reject — errors should be caught and logged
    await expect(resetSeedToOpen("bd-fail-002")).resolves.toBeUndefined();
  });

  it("passes --status open as the status value", async () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    await resetSeedToOpen("bd-status-test");

    const [, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    const statusIdx = args.indexOf("--status");
    expect(statusIdx).toBeGreaterThanOrEqual(0);
    expect(args[statusIdx + 1]).toBe("open");
  });

  it("defaults to br backend when FOREMAN_TASK_BACKEND is not set", async () => {
    delete process.env.FOREMAN_TASK_BACKEND;
    mockExecFileSync.mockReturnValue(Buffer.from(""));
    await resetSeedToOpen("task-xyz-999");
    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args[0]).toBe("update");
    expect(args).toContain("open");
  });

  it("calls br sync --flush-only after resetting seed to open", async () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    await resetSeedToOpen("bd-reset-flush-test", "/my/project");

    expect(mockExecFileSync).toHaveBeenCalledTimes(2);
    const [, syncArgs, syncOpts] = mockExecFileSync.mock.calls[1] as [string, string[], Record<string, unknown>];
    expect(syncArgs).toEqual(["sync", "--flush-only"]);
    expect(syncOpts).toMatchObject({ cwd: "/my/project" });
  });

  it("calls br sync --flush-only with undefined projectPath when not provided", async () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    await resetSeedToOpen("bd-reset-flush-no-path");

    expect(mockExecFileSync).toHaveBeenCalledTimes(2);
    const [, syncArgs, syncOpts] = mockExecFileSync.mock.calls[1] as [string, string[], Record<string, unknown>];
    expect(syncArgs).toEqual(["sync", "--flush-only"]);
    expect(syncOpts).not.toHaveProperty("cwd");
  });

  it("does not throw when br sync --flush-only fails (flush is non-fatal)", async () => {
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (args[0] === "sync") throw new Error("sync failed");
      return Buffer.from("");
    });

    // Must not reject even if flush fails
    await expect(resetSeedToOpen("bd-reset-fail-sync", "/my/project")).resolves.toBeUndefined();
  });

  it("does not call br sync --flush-only when br update fails", async () => {
    mockExecFileSync.mockImplementation(() => { throw new Error("br binary missing"); });

    await resetSeedToOpen("bd-reset-update-fail-no-flush");

    const syncCalls = mockExecFileSync.mock.calls.filter(
      (call) => Array.isArray(call[1]) && (call[1] as string[])[0] === "sync",
    );
    expect(syncCalls).toHaveLength(0);
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

  it("passes projectPath as cwd to execFileSync", async () => {
    await closeSeed("bd-cwd-001", "/my/project/root");

    const [, , opts] = mockExecFileSync.mock.calls[0] as [string, string[], Record<string, unknown>];
    expect(opts.cwd).toBe("/my/project/root");
  });

  it("omits cwd when projectPath is not provided", async () => {
    await closeSeed("bd-cwd-002");

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

  it("passes projectPath as cwd to execFileSync", async () => {
    await resetSeedToOpen("bd-reset-cwd-001", "/my/project/root");

    const [, , opts] = mockExecFileSync.mock.calls[0] as [string, string[], Record<string, unknown>];
    expect(opts.cwd).toBe("/my/project/root");
  });

  it("omits cwd when projectPath is not provided", async () => {
    await resetSeedToOpen("bd-reset-cwd-002");

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

  it("closeSeed uses os.homedir() for br path", async () => {
    process.env.FOREMAN_TASK_BACKEND = "br";

    await closeSeed("bd-no-home");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toBe("/fallback/home/.local/bin/br");
  });

  it("resetSeedToOpen uses os.homedir() for br path", async () => {
    process.env.FOREMAN_TASK_BACKEND = "br";

    await resetSeedToOpen("bd-no-home");

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
