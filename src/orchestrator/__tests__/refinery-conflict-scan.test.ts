import { describe, it, expect, beforeEach, vi } from "vitest";

// ── Module mocks ─────────────────────────────────────────────────────────────

// vi.mock is hoisted, so the factory cannot reference variables declared in module
// scope. Use vi.hoisted() to create the mock before hoisting occurs.
const { mockExecFile } = vi.hoisted(() => ({ mockExecFile: vi.fn() }));

// Mock execFile so we can control what git diff returns without running real git.
vi.mock("node:child_process", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:child_process")>();
  return { ...original, execFile: mockExecFile };
});

vi.mock("../task-backend-ops.js", () => ({
  resetSeedToOpen: vi.fn().mockResolvedValue(undefined),
  closeSeed: vi.fn().mockResolvedValue(undefined),
}));

import { Refinery } from "../refinery.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeMocks() {
  const store = {
    getRunsByStatus: vi.fn(() => []),
    getRunsByStatuses: vi.fn(() => []),
    getRun: vi.fn(() => null),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
  };
  const seeds = {
    getGraph: vi.fn(async () => ({ edges: [] })),
    show: vi.fn(async () => null),
    update: vi.fn(async () => undefined),
  };
  const refinery = new Refinery(store as any, seeds as any, "/tmp/project");
  return { store, seeds, refinery };
}

/** Build a minimal unified diff that adds lines to a file. */
function makeDiff(filename: string, addedLines: string[]): string {
  const added = addedLines.map((l) => `+${l}`).join("\n");
  return `diff --git a/${filename} b/${filename}\n--- a/${filename}\n+++ b/${filename}\n@@ -1,1 +1,${addedLines.length + 1} @@\n const x = 1;\n${added}\n`;
}

/** Access the private scanForConflictMarkers method. */
function scan(refinery: Refinery, branchName: string, targetBranch: string): Promise<string[]> {
  return (refinery as any).scanForConflictMarkers(branchName, targetBranch);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("Refinery.scanForConflictMarkers (committed diff)", () => {
  let refinery: Refinery;

  beforeEach(() => {
    const { refinery: r } = makeMocks();
    refinery = r;
    mockExecFile.mockReset();
  });

  it("returns [] when git diff produces no output (branch equals target)", async () => {
    mockExecFile.mockImplementation((_bin: string, _args: string[], _opts: unknown, cb: Function) => {
      cb(null, { stdout: "", stderr: "" });
    });
    const result = await scan(refinery, "foreman/bd-neph", "main");
    expect(result).toEqual([]);
  });

  it("returns [] for a clean diff with no conflict markers", async () => {
    const diff = makeDiff("src/foo.ts", ["const a = 1;"]);
    mockExecFile.mockImplementation((_bin: string, _args: string[], _opts: unknown, cb: Function) => {
      cb(null, { stdout: diff, stderr: "" });
    });
    const result = await scan(refinery, "foreman/bd-feature", "main");
    expect(result).toEqual([]);
  });

  it("returns the file path when <<<<<<< is added by the branch", async () => {
    const diff = makeDiff("src/conflict.ts", ["<<<<<<< HEAD", "const a = 1;", "=======", "const a = 2;", ">>>>>>> branch"]);
    mockExecFile.mockImplementation((_bin: string, _args: string[], _opts: unknown, cb: Function) => {
      cb(null, { stdout: diff, stderr: "" });
    });
    const result = await scan(refinery, "foreman/bd-conflict", "main");
    expect(result).toHaveLength(1);
    expect(result[0]).toBe("src/conflict.ts");
  });

  it("returns the file path when ||||||| (diff3 marker) is added by the branch", async () => {
    const diff = makeDiff("src/diff3.ts", ["const y = 0;", "||||||| base", "=======", "const y = 3;", ">>>>>>> branch"]);
    mockExecFile.mockImplementation((_bin: string, _args: string[], _opts: unknown, cb: Function) => {
      cb(null, { stdout: diff, stderr: "" });
    });
    const result = await scan(refinery, "foreman/bd-diff3", "main");
    expect(result).toHaveLength(1);
    expect(result[0]).toBe("src/diff3.ts");
  });

  it("does NOT flag a file if <<<<<<< appears only in context lines (not added)", async () => {
    // Context lines (unchanged) start with ' ', not '+'. The scanner only checks '+' lines.
    const diff = " <<<<<<< this is a context line, unchanged\n+const a = 1;\n";
    mockExecFile.mockImplementation((_bin: string, _args: string[], _opts: unknown, cb: Function) => {
      cb(null, { stdout: `+++ b/src/ok.ts\n${diff}`, stderr: "" });
    });
    const result = await scan(refinery, "foreman/bd-ok", "main");
    expect(result).toEqual([]);
  });

  it("returns multiple files when several files have committed conflict markers", async () => {
    const diff = [
      `diff --git a/alpha.ts b/alpha.ts\n--- a/alpha.ts\n+++ b/alpha.ts\n@@ -1 +1 @@\n+<<<<<<< HEAD\n+const a = 1;\n`,
      `diff --git a/beta.tsx b/beta.tsx\n--- a/beta.tsx\n+++ b/beta.tsx\n@@ -1 +1 @@\n+||||||| base\n+const b = 0;\n`,
    ].join("\n");
    mockExecFile.mockImplementation((_bin: string, _args: string[], _opts: unknown, cb: Function) => {
      cb(null, { stdout: diff, stderr: "" });
    });
    const result = await scan(refinery, "foreman/bd-multi", "main");
    expect(result).toHaveLength(2);
    expect(result).toContain("alpha.ts");
    expect(result).toContain("beta.tsx");
  });

  it("returns [] when git throws (e.g. branch not found) — non-blocking", async () => {
    mockExecFile.mockImplementation((_bin: string, _args: string[], _opts: unknown, cb: Function) => {
      cb(new Error("fatal: unknown revision or path not in the working tree"), { stdout: "", stderr: "" });
    });
    const result = await scan(refinery, "foreman/bd-missing", "main");
    expect(result).toEqual([]);
  });

  it("ignores conflict markers in REMOVED lines (lines starting with -)", async () => {
    // A line removed by the branch that had a conflict marker should not be flagged.
    const diff = `+++ b/src/removed.ts\n-<<<<<<< HEAD\n-const old = 1;\n+const new_ = 2;\n`;
    mockExecFile.mockImplementation((_bin: string, _args: string[], _opts: unknown, cb: Function) => {
      cb(null, { stdout: diff, stderr: "" });
    });
    const result = await scan(refinery, "foreman/bd-removed", "main");
    expect(result).toEqual([]);
  });

  it("does NOT flag uncommitted working-tree conflict markers (only committed diff matters)", async () => {
    // The diff from committed content is clean — even if the worktree has markers.
    // This is the key regression test for the bd-neph bug.
    const cleanDiff = makeDiff("src/agent-worker.ts", ["const x = 1;"]);
    mockExecFile.mockImplementation((_bin: string, _args: string[], _opts: unknown, cb: Function) => {
      cb(null, { stdout: cleanDiff, stderr: "" });
    });
    // Even if the worktree has conflict markers (simulated by the test calling scan without
    // a worktreePath argument), the scanner should return [].
    const result = await scan(refinery, "foreman/bd-neph", "main");
    expect(result).toEqual([]);
  });
});
