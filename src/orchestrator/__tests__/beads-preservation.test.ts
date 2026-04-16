import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Module mocks ──────────────────────────────────────────────────────────────

vi.mock("node:child_process", () => ({
  execFile: vi.fn(),
}));

vi.mock("node:fs", () => ({
  writeFileSync: vi.fn(),
  unlinkSync: vi.fn(),
  existsSync: vi.fn(() => false),
  mkdirSync: vi.fn(),
  renameSync: vi.fn(),
}));

import { execFile } from "node:child_process";
import { writeFileSync, unlinkSync } from "node:fs";
import { preserveBeadChanges } from "../refinery.js";
import type { VcsBackend } from "../../lib/vcs/index.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function mockGitSuccess(responses: Record<string, string>) {
  (execFile as any).mockImplementation(
    (_cmd: string, args: string[], _opts: any, callback: Function) => {
      const key = args.join(" ");
      for (const [pattern, stdout] of Object.entries(responses)) {
        if (key.includes(pattern)) {
          callback(null, { stdout, stderr: "" });
          return;
        }
      }
      callback(null, { stdout: "", stderr: "" });
    },
  );
}

function mockGitSequence(results: Array<{ stdout?: string; error?: Error }>) {
  let callIndex = 0;
  (execFile as any).mockImplementation(
    (_cmd: string, _args: string[], _opts: any, callback: Function) => {
      const result = results[callIndex] ?? { stdout: "" };
      callIndex++;
      if (result.error) {
        const err = result.error as any;
        err.stdout = "";
        err.stderr = result.error.message;
        callback(err);
      } else {
        callback(null, { stdout: result.stdout ?? "", stderr: "" });
      }
    },
  );
}

// ── preserveBeadChanges() tests ───────────────────────────────────────────────

describe("preserveBeadChanges()", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("extracts .seeds/ changes and applies them to target", async () => {
    const patchContent = "diff --git a/.seeds/issues.jsonl b/.seeds/issues.jsonl\n+some bead data\n";

    mockGitSuccess({
      "diff main...foreman/seed-abc -- .seeds/": patchContent,
      "apply --index": "",
      "commit -m": "",
    });

    const result = await preserveBeadChanges(
      "/tmp/project",
      "foreman/seed-abc",
      "main",
    );

    expect(result.preserved).toBe(true);
    expect(vi.mocked(writeFileSync)).toHaveBeenCalled();
  });

  it("does nothing when no .seeds/ changes exist", async () => {
    mockGitSuccess({
      "diff main...foreman/seed-abc -- .seeds/": "",
    });

    const result = await preserveBeadChanges(
      "/tmp/project",
      "foreman/seed-abc",
      "main",
    );

    expect(result.preserved).toBe(false);
    expect(result.error).toBeUndefined();
  });

  it("logs warning on patch failure but does not throw", async () => {
    const patchContent = "diff --git a/.seeds/issues.jsonl b/.seeds/issues.jsonl\n+data\n";

    let callIndex = 0;
    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        callIndex++;
        if (args.includes("apply")) {
          const err = new Error("patch does not apply") as any;
          err.stdout = "";
          err.stderr = "patch does not apply";
          err.code = "MQ-019";
          callback(err);
          return;
        }
        if (args.includes("diff")) {
          callback(null, { stdout: patchContent, stderr: "" });
          return;
        }
        callback(null, { stdout: "", stderr: "" });
      },
    );

    const result = await preserveBeadChanges(
      "/tmp/project",
      "foreman/seed-fail",
      "main",
    );

    expect(result.preserved).toBe(false);
    expect(result.error).toContain("patch does not apply");
  });

  it("always cleans up temp file even on failure", async () => {
    const patchContent = "diff --git a/.seeds/x b/.seeds/x\n+data\n";

    let callIndex = 0;
    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        callIndex++;
        if (args.includes("apply")) {
          callback(new Error("apply failed"));
          return;
        }
        if (args.includes("diff")) {
          callback(null, { stdout: patchContent, stderr: "" });
          return;
        }
        callback(null, { stdout: "", stderr: "" });
      },
    );

    await preserveBeadChanges("/tmp/project", "foreman/seed-cleanup", "main");

    // unlinkSync should be called for temp file cleanup
    expect(vi.mocked(unlinkSync)).toHaveBeenCalled();
  });

  it("preserves only .seeds/ directory changes", async () => {
    // The diff command should specifically filter to .seeds/
    const calls: string[][] = [];
    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        calls.push(args);
        callback(null, { stdout: "", stderr: "" });
      },
    );

    await preserveBeadChanges("/tmp/project", "foreman/seed-only", "main");

    const diffCall = calls.find((c) => c.includes("diff"));
    expect(diffCall).toBeDefined();
    expect(diffCall).toContain(".seeds/");
  });

  it("uses jj backend methods instead of raw git when a jj backend is provided", async () => {
    const vcs: VcsBackend = {
      name: "jujutsu",
      getRepoRoot: vi.fn(),
      getMainRepoRoot: vi.fn(),
      detectDefaultBranch: vi.fn(),
      getCurrentBranch: vi.fn(),
      checkoutBranch: vi.fn(),
      branchExists: vi.fn(),
      branchExistsOnRemote: vi.fn(),
      deleteBranch: vi.fn(),
      createWorkspace: vi.fn(),
      removeWorkspace: vi.fn(),
      listWorkspaces: vi.fn(),
      stageAll: vi.fn(),
      commit: vi.fn().mockResolvedValue(undefined),
      push: vi.fn(),
      pull: vi.fn(),
      rebase: vi.fn(),
      abortRebase: vi.fn(),
      merge: vi.fn(),
      getHeadId: vi.fn(),
      resolveRef: vi.fn(),
      fetch: vi.fn(),
      diff: vi.fn(),
      getChangedFiles: vi.fn().mockResolvedValue([".seeds/issues.jsonl", "src/foo.ts"]),
      getRefCommitTimestamp: vi.fn(),
      getModifiedFiles: vi.fn(),
      getConflictingFiles: vi.fn(),
      status: vi.fn(),
      cleanWorkingTree: vi.fn(),
      mergeWithoutCommit: vi.fn(),
      commitNoEdit: vi.fn(),
      abortMerge: vi.fn(),
      stageFile: vi.fn().mockResolvedValue(undefined),
      checkoutFile: vi.fn(),
      showFile: vi.fn().mockResolvedValue("seed data"),
      resetHard: vi.fn(),
      removeFile: vi.fn(),
      rebaseContinue: vi.fn(),
      removeFromIndex: vi.fn(),
      getMergeBase: vi.fn(),
      getUntrackedFiles: vi.fn(),
      isAncestor: vi.fn(),
      getFinalizeCommands: vi.fn(),
    } as unknown as VcsBackend;

    const result = await preserveBeadChanges(
      "/tmp/project",
      "foreman/seed-jj",
      "main",
      vcs,
    );

    expect(result.preserved).toBe(true);
    expect(vcs.getChangedFiles).toHaveBeenCalledWith("/tmp/project", "main", "foreman/seed-jj");
    expect(vcs.showFile).toHaveBeenCalledWith("/tmp/project", "foreman/seed-jj", ".seeds/issues.jsonl");
    expect(vcs.stageFile).toHaveBeenCalledWith("/tmp/project", ".seeds/issues.jsonl");
    expect(vcs.commit).toHaveBeenCalledWith("/tmp/project", "chore: preserve seed changes from seed-jj");
    expect((execFile as any).mock.calls).toHaveLength(0);
  });
});
