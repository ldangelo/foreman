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

import { closeSeed, resetSeedToOpen, addLabelsToBead, addNotesToBead } from "../task-backend-ops.js";

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

  it("calls br close --no-db --force with seedId (beads_rust#204 workaround)", async () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    await closeSeed("bd-abc-001");

    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args[0]).toBe("close");
    expect(args).toContain("--no-db");
    expect(args).toContain("--force");
    expect(args).toContain("bd-abc-001");
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

  it("passes --no-db --force flags for JSONL-direct close (beads_rust#204)", async () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    await closeSeed("bd-reason-test");

    const [, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(args[0]).toBe("close");
    expect(args).toContain("--no-db");
    expect(args).toContain("--force");
  });

  it("defaults to br backend when FOREMAN_TASK_BACKEND is not set", async () => {
    delete process.env.FOREMAN_TASK_BACKEND;
    mockExecFileSync.mockReturnValue(Buffer.from(""));
    await closeSeed("task-xyz-999");
    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args[0]).toBe("close");
  });

  it("calls execFileSync twice for close (br close + sqlite3 cache clear)", async () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    await closeSeed("bd-flush-test", "/my/project");

    // Two execFileSync calls:
    // 1. br close --no-db --force (write to JSONL)
    // 2. sqlite3 ... DELETE FROM blocked_issues_cache; (clear cache)
    expect(mockExecFileSync).toHaveBeenCalledTimes(2);
    const [, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(args[0]).toBe("close");
    expect(args).toContain("--no-db");

    // Second call should be sqlite3 to clear blocked_issues_cache
    const [sqlite3Cmd, sqlite3Args] = mockExecFileSync.mock.calls[1] as [string, string[], unknown];
    expect(sqlite3Cmd).toBe("sqlite3");
    expect((sqlite3Args as string[]).some((a: string) => a.includes("blocked_issues_cache"))).toBe(true);
  });

  it("does not throw when close --no-db fails (error suppressed)", async () => {
    mockExecFileSync.mockImplementation(() => {
      throw new Error("close failed");
    });

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

// ── addNotesToBead ────────────────────────────────────────────────────────────

describe("addNotesToBead — br backend", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    process.env.HOME = HOME;
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  it("calls br update with --notes flag and the provided text", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    addNotesToBead("bd-notes-001", "Some failure reason");

    expect(mockExecFileSync).toHaveBeenCalledWith(
      `${HOME}/.local/bin/br`,
      ["update", "bd-notes-001", "--notes", "Some failure reason"],
      expect.objectContaining({ stdio: "pipe" }),
    );
  });

  it("uses ~/.local/bin/br path", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    addNotesToBead("bd-notes-002", "Failure note");

    const [cmd] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toBe(`${HOME}/.local/bin/br`);
  });

  it("does nothing when notes string is empty", () => {
    addNotesToBead("bd-notes-003", "");

    expect(mockExecFileSync).not.toHaveBeenCalled();
  });

  it("does not throw when br update --notes fails (error suppressed)", () => {
    mockExecFileSync.mockImplementation(() => { throw new Error("br binary missing"); });

    expect(() => addNotesToBead("bd-notes-004", "Some note")).not.toThrow();
  });

  it("calls br sync --flush-only after adding notes", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    addNotesToBead("bd-notes-005", "Some note", "/my/project");

    expect(mockExecFileSync).toHaveBeenCalledTimes(2);
    const [, syncArgs, syncOpts] = mockExecFileSync.mock.calls[1] as [string, string[], Record<string, unknown>];
    expect(syncArgs).toEqual(["sync", "--flush-only"]);
    expect(syncOpts).toMatchObject({ cwd: "/my/project" });
  });

  it("calls br sync --flush-only without cwd when projectPath not provided", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    addNotesToBead("bd-notes-006", "Some note");

    expect(mockExecFileSync).toHaveBeenCalledTimes(2);
    const [, syncArgs, syncOpts] = mockExecFileSync.mock.calls[1] as [string, string[], Record<string, unknown>];
    expect(syncArgs).toEqual(["sync", "--flush-only"]);
    expect(syncOpts).not.toHaveProperty("cwd");
  });

  it("does not throw when br sync --flush-only fails (flush is non-fatal)", () => {
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (args[0] === "sync") throw new Error("sync failed");
      return Buffer.from("");
    });

    expect(() => addNotesToBead("bd-notes-007", "Some note", "/my/project")).not.toThrow();
  });

  it("does not call br sync --flush-only when br update fails", () => {
    mockExecFileSync.mockImplementation(() => { throw new Error("br binary missing"); });

    addNotesToBead("bd-notes-008", "Some note");

    const syncCalls = mockExecFileSync.mock.calls.filter(
      (call) => Array.isArray(call[1]) && (call[1] as string[])[0] === "sync",
    );
    expect(syncCalls).toHaveLength(0);
  });

  it("passes projectPath as cwd to execFileSync", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    addNotesToBead("bd-notes-009", "Failure note", "/my/project/root");

    const [, , opts] = mockExecFileSync.mock.calls[0] as [string, string[], Record<string, unknown>];
    expect(opts.cwd).toBe("/my/project/root");
  });

  it("omits cwd when projectPath is not provided", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    addNotesToBead("bd-notes-010", "Failure note");

    const [, , opts] = mockExecFileSync.mock.calls[0] as [string, string[], Record<string, unknown>];
    expect(opts.cwd).toBeUndefined();
  });

  it("truncates very long notes to 2000 characters with ellipsis", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    const longNote = "x".repeat(3000);
    addNotesToBead("bd-notes-011", longNote);

    const [, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    const notesIdx = args.indexOf("--notes");
    const noteValue = args[notesIdx + 1];
    expect(noteValue.length).toBe(2001); // 2000 chars + "…"
    expect(noteValue.endsWith("…")).toBe(true);
  });

  it("passes notes without truncation when under 2000 characters", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    const note = "Short failure reason";
    addNotesToBead("bd-notes-012", note);

    const [, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    const notesIdx = args.indexOf("--notes");
    expect(args[notesIdx + 1]).toBe(note);
  });
});

// ── addLabelsToBead ───────────────────────────────────────────────────────────

describe("addLabelsToBead — br backend", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    process.env.HOME = HOME;
    delete process.env.FOREMAN_TASK_BACKEND;
  });

  it("calls br update with --add-label flag (preserves existing labels)", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    addLabelsToBead("bd-abc-001", ["phase:explorer"]);

    // First call is update, second is sync --flush-only
    expect(mockExecFileSync).toHaveBeenCalledTimes(2);
    const [cmd, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(cmd).toContain("br");
    expect(args).toEqual(["update", "bd-abc-001", "--add-label", "phase:explorer"]);
  });

  it("passes each label as a separate --add-label argument", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    addLabelsToBead("bd-abc-002", ["phase:developer", "phase:qa"]);

    const [, args] = mockExecFileSync.mock.calls[0] as [string, string[], unknown];
    expect(args).toContain("--add-label");
    expect(args).toContain("phase:developer");
    expect(args).toContain("phase:qa");
    // Both labels present via separate --add-label flags
    const addLabelCount = args.filter((a) => a === "--add-label").length;
    expect(addLabelCount).toBe(2);
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

  it("calls br sync --flush-only after adding labels", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    addLabelsToBead("bd-flush-label", ["phase:explorer"], "/my/project");

    // execFileSync called twice: first for update, then for sync --flush-only
    expect(mockExecFileSync).toHaveBeenCalledTimes(2);
    const [, syncArgs, syncOpts] = mockExecFileSync.mock.calls[1] as [string, string[], Record<string, unknown>];
    expect(syncArgs).toEqual(["sync", "--flush-only"]);
    expect(syncOpts).toMatchObject({ cwd: "/my/project" });
  });

  it("calls br sync --flush-only with correct cwd when projectPath is not provided", () => {
    mockExecFileSync.mockReturnValue(Buffer.from(""));

    addLabelsToBead("bd-flush-label-no-path", ["phase:qa"]);

    expect(mockExecFileSync).toHaveBeenCalledTimes(2);
    const [, syncArgs, syncOpts] = mockExecFileSync.mock.calls[1] as [string, string[], Record<string, unknown>];
    expect(syncArgs).toEqual(["sync", "--flush-only"]);
    expect(syncOpts).not.toHaveProperty("cwd");
  });

  it("does not throw when br sync --flush-only fails (flush is non-fatal)", () => {
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (args[0] === "sync") throw new Error("sync failed");
      return Buffer.from("");
    });

    // Must not throw even if flush fails
    expect(() => addLabelsToBead("bd-flush-fail", ["phase:reviewer"], "/my/project")).not.toThrow();
  });

  it("does not call br sync --flush-only when br update --labels fails", () => {
    mockExecFileSync.mockImplementation(() => { throw new Error("br binary missing"); });

    addLabelsToBead("bd-label-fail-no-flush", ["phase:explorer"]);

    // Only the (failed) update call was made — sync should not have been called
    const syncCalls = mockExecFileSync.mock.calls.filter(
      (call) => Array.isArray(call[1]) && (call[1] as string[])[0] === "sync",
    );
    expect(syncCalls).toHaveLength(0);
  });
});
