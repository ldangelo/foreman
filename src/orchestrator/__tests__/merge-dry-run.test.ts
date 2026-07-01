import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Module mocks ──────────────────────────────────────────────────────────────

vi.mock("node:child_process", () => ({
  execFile: vi.fn(),
}));

import { execFile } from "node:child_process";
import { dryRunMerge, type DryRunEntry } from "../refinery.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function mockExecFileImpl(responses: Record<string, string>) {
  (execFile as any).mockImplementation(
    (_cmd: string, args: string[], _opts: any, callback: Function) => {
      const key = args.join(" ");
      for (const [pattern, stdout] of Object.entries(responses)) {
        if (key.includes(pattern)) {
          callback(null, { stdout, stderr: "" });
          return;
        }
      }
      // Default: empty success
      callback(null, { stdout: "", stderr: "" });
    },
  );
}

function mockExecFileSequence(results: Array<{ stdout: string; stderr?: string; error?: Error }>) {
  let callIndex = 0;
  (execFile as any).mockImplementation(
    (_cmd: string, _args: string[], _opts: any, callback: Function) => {
      const result = results[callIndex] ?? { stdout: "", stderr: "" };
      callIndex++;
      if (result.error) {
        const err = result.error as any;
        err.stdout = result.stdout ?? "";
        err.stderr = result.stderr ?? "";
        callback(err);
      } else {
        callback(null, { stdout: result.stdout, stderr: result.stderr ?? "" });
      }
    },
  );
}

// ── dryRunMerge() tests ───────────────────────────────────────────────────────

describe("dryRunMerge()", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("shows diff stats for each branch", async () => {
    // Responses keyed by argument substring
    mockExecFileImpl({
      "merge-base main foreman/task-abc": "base123",
      "diff --stat main...foreman/task-abc": " src/foo.ts | 10 ++++\n 1 file changed, 10 insertions(+)\n",
      "merge-tree": "", // no conflicts
    });

    const branches = [
      { branchName: "foreman/task-abc", taskId: "task-abc" },
    ];

    const result = await dryRunMerge("/tmp/project", "main", branches);

    expect(result).toHaveLength(1);
    expect(result[0].taskId).toBe("task-abc");
    expect(result[0].diffStat).toContain("src/foo.ts");
    expect(result[0].hasConflicts).toBe(false);
  });

  it("detects conflicts via git merge-tree", async () => {
    mockExecFileImpl({
      "merge-base main foreman/task-conflict": "base456",
      "diff --stat main...foreman/task-conflict": " src/bar.ts | 5 ++\n",
      "merge-tree": "changed in both\n  base   100644 aaa src/bar.ts\n  our    100644 bbb src/bar.ts\n  their  100644 ccc src/bar.ts\n",
    });

    const branches = [
      { branchName: "foreman/task-conflict", taskId: "task-conflict" },
    ];

    const result = await dryRunMerge("/tmp/project", "main", branches);

    expect(result[0].hasConflicts).toBe(true);
  });

  it("filters by task ID when provided", async () => {
    mockExecFileImpl({
      "merge-base": "base789",
      "diff --stat": " src/x.ts | 1 +\n",
      "merge-tree": "",
    });

    const branches = [
      { branchName: "foreman/task-a", taskId: "task-a" },
      { branchName: "foreman/task-b", taskId: "task-b" },
    ];

    const result = await dryRunMerge("/tmp/project", "main", branches, "task-a");

    expect(result).toHaveLength(1);
    expect(result[0].taskId).toBe("task-a");
  });

  it("does not modify git state", async () => {
    const calls: string[][] = [];
    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        calls.push(args);
        callback(null, { stdout: "", stderr: "" });
      },
    );

    const branches = [
      { branchName: "foreman/task-x", taskId: "task-x" },
    ];

    await dryRunMerge("/tmp/project", "main", branches);

    // Verify no checkout, merge, rebase, reset, or commit commands
    const mutatingCommands = ["checkout", "merge", "rebase", "reset", "commit", "push"];
    for (const callArgs of calls) {
      for (const cmd of mutatingCommands) {
        expect(callArgs).not.toContain(cmd);
      }
    }
  });

  it("includes estimated resolution tier when conflict_patterns data is available", async () => {
    mockExecFileImpl({
      "merge-base main foreman/task-tier": "baseT",
      "diff --stat main...foreman/task-tier": " src/z.ts | 3 ++\n",
      "merge-tree": "changed in both\n  base 100644 aaa src/z.ts\n  our 100644 bbb src/z.ts\n  their 100644 ccc src/z.ts\n",
    });

    const branches = [
      { branchName: "foreman/task-tier", taskId: "task-tier" },
    ];

    const conflictPatterns = new Map<string, number>([
      ["src/z.ts", 1],
    ]);

    const result = await dryRunMerge("/tmp/project", "main", branches, undefined, conflictPatterns);

    expect(result[0].hasConflicts).toBe(true);
    expect(result[0].estimatedTier).toBe(1);
  });

  it("omits resolution tier when no conflict_patterns data exists", async () => {
    mockExecFileImpl({
      "merge-base": "baseN",
      "diff --stat": " src/y.ts | 2 +\n",
      "merge-tree": "changed in both\n",
    });

    const branches = [
      { branchName: "foreman/task-no-tier", taskId: "task-no-tier" },
    ];

    const result = await dryRunMerge("/tmp/project", "main", branches);

    expect(result[0].estimatedTier).toBeUndefined();
  });

  it("handles merge-base failure gracefully", async () => {
    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        if (args.includes("merge-base")) {
          const err = new Error("no common ancestor") as any;
          err.stdout = "";
          err.stderr = "no common ancestor";
          callback(err);
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const branches = [
      { branchName: "foreman/task-err", taskId: "task-err" },
    ];

    const result = await dryRunMerge("/tmp/project", "main", branches);

    expect(result[0].error).toContain("no common ancestor");
  });
});
