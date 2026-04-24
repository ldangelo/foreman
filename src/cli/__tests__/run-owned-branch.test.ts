import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const { mockExecFileSync } = vi.hoisted(() => ({
  mockExecFileSync: vi.fn(),
}));

vi.mock("node:child_process", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  return { ...actual, execFileSync: mockExecFileSync };
});

import { collectRuntimeAssetIssues, isIgnorableControllerPath, resolveOwnedControllerBranch } from "../commands/run.js";
import type { VcsBackend } from "../../lib/vcs/interface.js";

function makeJjVcs(overrides: Partial<VcsBackend> = {}): VcsBackend {
  return {
    name: "jujutsu",
    getRepoRoot: vi.fn().mockResolvedValue("/repo"),
    getMainRepoRoot: vi.fn().mockResolvedValue("/repo"),
    detectDefaultBranch: vi.fn().mockResolvedValue("dev"),
    getCurrentBranch: vi.fn().mockResolvedValue("wzplklnookuz"),
    checkoutBranch: vi.fn().mockResolvedValue(undefined),
    branchExists: vi.fn().mockResolvedValue(false),
    branchExistsOnRemote: vi.fn().mockResolvedValue(false),
    deleteBranch: vi.fn().mockResolvedValue({ deleted: false, wasFullyMerged: false }),
    createWorkspace: vi.fn().mockResolvedValue({ workspacePath: "/workspace", branchName: "foreman/test" }),
    removeWorkspace: vi.fn().mockResolvedValue(undefined),
    listWorkspaces: vi.fn().mockResolvedValue([]),
    stageAll: vi.fn().mockResolvedValue(undefined),
    commit: vi.fn().mockResolvedValue(undefined),
    push: vi.fn().mockResolvedValue(undefined),
    pull: vi.fn().mockResolvedValue(undefined),
    rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    abortRebase: vi.fn().mockResolvedValue(undefined),
    merge: vi.fn().mockResolvedValue({ success: true, conflictingFiles: [] }),
    getHeadId: vi.fn().mockResolvedValue("abc123"),
    resolveRef: vi.fn().mockResolvedValue("abc123"),
    fetch: vi.fn().mockResolvedValue(undefined),
    diff: vi.fn().mockResolvedValue(""),
    getChangedFiles: vi.fn().mockResolvedValue([]),
    getRefCommitTimestamp: vi.fn().mockResolvedValue(null),
    getModifiedFiles: vi.fn().mockResolvedValue([]),
    getConflictingFiles: vi.fn().mockResolvedValue([]),
    status: vi.fn().mockResolvedValue(""),
    cleanWorkingTree: vi.fn().mockResolvedValue(undefined),
    mergeWithoutCommit: vi.fn().mockResolvedValue({ success: true, conflictingFiles: [] }),
    commitNoEdit: vi.fn().mockResolvedValue(undefined),
    abortMerge: vi.fn().mockResolvedValue(undefined),
    stageFile: vi.fn().mockResolvedValue(undefined),
    checkoutFile: vi.fn().mockResolvedValue(undefined),
    showFile: vi.fn().mockResolvedValue(""),
    resetHard: vi.fn().mockResolvedValue(undefined),
    removeFile: vi.fn().mockResolvedValue(undefined),
    rebaseContinue: vi.fn().mockResolvedValue(undefined),
    removeFromIndex: vi.fn().mockResolvedValue(undefined),
    getMergeBase: vi.fn().mockResolvedValue(""),
    getUntrackedFiles: vi.fn().mockResolvedValue([]),
    isAncestor: vi.fn().mockResolvedValue(false),
    getFinalizeCommands: vi.fn().mockReturnValue({
      stageCommand: "",
      commitCommand: "",
      pushCommand: "",
      integrateTargetCommand: "",
      branchVerifyCommand: "",
      cleanCommand: "",
      restoreTrackedStateCommand: "",
    }),
    ...overrides,
  } as VcsBackend;
}

describe("isIgnorableControllerPath", () => {
  it("ignores runtime state paths", () => {
    expect(isIgnorableControllerPath(".omx/state/ralph.json")).toBe(true);
    expect(isIgnorableControllerPath(".beads/issues.jsonl")).toBe(true);
    expect(isIgnorableControllerPath(".foreman/log.txt")).toBe(true);
    expect(isIgnorableControllerPath("storage.sqlite3-wal")).toBe(true);
  });
});

describe("resolveOwnedControllerBranch", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("creates the foreman-controller bookmark and moves to a mutable child change on it", async () => {
    const vcs = makeJjVcs();

    const result = await resolveOwnedControllerBranch(vcs, "/repo");

    expect(mockExecFileSync).toHaveBeenNthCalledWith(
      1,
      "jj",
      ["bookmark", "create", "foreman-controller", "-r", "dev"],
      expect.objectContaining({ cwd: "/repo" }),
    );
    expect(mockExecFileSync).toHaveBeenNthCalledWith(
      2,
      "jj",
      ["new", "foreman-controller"],
      expect.objectContaining({ cwd: "/repo" }),
    );
    expect(result).toMatchObject({
      currentBranch: "foreman-controller",
      defaultBranch: "dev",
      targetBranch: "dev",
      usedOwnedBranch: true,
    });
  });

  it("throws when non-ignorable dirty files are present", async () => {
    const vcs = makeJjVcs({
      getModifiedFiles: vi.fn().mockResolvedValue(["src/cli/index.ts"]),
    });

    await expect(resolveOwnedControllerBranch(vcs, "/repo")).rejects.toThrow(
      /Foreman-owned branch requires a clean controller checkout/,
    );
  });
});

describe("collectRuntimeAssetIssues", () => {
  const tempDirs: string[] = [];

  function makeProject(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-run-assets-"));
    tempDirs.push(dir);
    process.env["FOREMAN_HOME"] = dir;
    mkdirSync(join(dir, "prompts", "default"), { recursive: true });
    mkdirSync(join(dir, "workflows"), { recursive: true });
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
    delete process.env["FOREMAN_HOME"];
  });

  it("flags stale global prompts before dispatch", () => {
    const projectRoot = makeProject();
    writeFileSync(
      join(projectRoot, "prompts", "default", "developer.md"),
      "# stale prompt without new placeholders",
      "utf8",
    );

    const issues = collectRuntimeAssetIssues(projectRoot, {});
    expect(issues.some((issue) => issue.includes("stale prompts"))).toBe(true);
  });
});
