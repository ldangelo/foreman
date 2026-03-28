/**
 * git-shim.test.ts — Backward Compatibility Verification for git.ts shim
 *
 * Verifies TRD-011: After git.ts is refactored into a thin shim delegating
 * to GitBackend, this file validates that:
 *
 *   AC-T-011-1: Existing function exports from git.ts remain importable and
 *               behave identically to the pre-shim implementation.
 *
 *   AC-T-011-2: Old function names (createWorktree, removeWorktree, etc.)
 *               delegate to the corresponding GitBackend methods
 *               (createWorkspace, removeWorkspace, etc.).
 *
 *   AC-T-011-3: Old type exports (Worktree, MergeResult, DeleteBranchResult)
 *               are structurally compatible with the new vcs/types equivalents
 *               (Workspace, MergeResult, DeleteBranchResult).
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  mkdtempSync,
  existsSync,
  writeFileSync,
  rmSync,
  realpathSync,
} from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ── Type imports from git.ts (old API) ──────────────────────────────────────
import type { Worktree, MergeResult, DeleteBranchResult } from "../git.js";

// ── GitBackend import for prototype spying ────────────────────────────────────
import { GitBackend } from "../vcs/git-backend.js";

// ── Type imports from vcs/types.ts (new API) ─────────────────────────────────
import type { Workspace } from "../vcs/types.js";
import type { MergeResult as VcsMergeResult } from "../vcs/types.js";
import type { DeleteBranchResult as VcsDeleteBranchResult } from "../vcs/types.js";

// ── Function imports from git.ts (old public API) ────────────────────────────
import {
  createWorktree,
  removeWorktree,
  listWorktrees,
  mergeWorktree,
  gitBranchExists,
  branchExistsOnOrigin,
  deleteBranch,
  getRepoRoot,
  getMainRepoRoot,
  detectDefaultBranch,
  getCurrentBranch,
  checkoutBranch,
  detectPackageManager,
  installDependencies,
  runSetupSteps,
  runSetupWithCache,
} from "../git.js";

// ── Helpers ──────────────────────────────────────────────────────────────────

function makeTempRepo(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-shim-test-")));
  execFileSync("git", ["init", "--initial-branch=main"], { cwd: dir });
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
  execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
  writeFileSync(join(dir, "README.md"), "# init\n");
  execFileSync("git", ["add", "."], { cwd: dir });
  execFileSync("git", ["commit", "-m", "initial commit"], { cwd: dir });
  return dir;
}

const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
  tempDirs.length = 0;
  vi.restoreAllMocks();
});

// ═══════════════════════════════════════════════════════════════════════════
// AC-T-011-1: Existing API exports remain importable and functional
// ═══════════════════════════════════════════════════════════════════════════

describe("AC-T-011-1: Exported functions exist and are callable", () => {
  it("createWorktree is exported as a function", () => {
    expect(typeof createWorktree).toBe("function");
  });

  it("removeWorktree is exported as a function", () => {
    expect(typeof removeWorktree).toBe("function");
  });

  it("listWorktrees is exported as a function", () => {
    expect(typeof listWorktrees).toBe("function");
  });

  it("mergeWorktree is exported as a function", () => {
    expect(typeof mergeWorktree).toBe("function");
  });

  it("gitBranchExists is exported as a function", () => {
    expect(typeof gitBranchExists).toBe("function");
  });

  it("branchExistsOnOrigin is exported as a function", () => {
    expect(typeof branchExistsOnOrigin).toBe("function");
  });

  it("deleteBranch is exported as a function", () => {
    expect(typeof deleteBranch).toBe("function");
  });

  it("getRepoRoot is exported as a function", () => {
    expect(typeof getRepoRoot).toBe("function");
  });

  it("getMainRepoRoot is exported as a function", () => {
    expect(typeof getMainRepoRoot).toBe("function");
  });

  it("detectDefaultBranch is exported as a function", () => {
    expect(typeof detectDefaultBranch).toBe("function");
  });

  it("getCurrentBranch is exported as a function", () => {
    expect(typeof getCurrentBranch).toBe("function");
  });

  it("checkoutBranch is exported as a function", () => {
    expect(typeof checkoutBranch).toBe("function");
  });

  it("detectPackageManager is exported as a function", () => {
    expect(typeof detectPackageManager).toBe("function");
  });

  it("installDependencies is exported as a function", () => {
    expect(typeof installDependencies).toBe("function");
  });

  it("runSetupSteps is exported as a function", () => {
    expect(typeof runSetupSteps).toBe("function");
  });

  it("runSetupWithCache is exported as a function", () => {
    expect(typeof runSetupWithCache).toBe("function");
  });
});

describe("AC-T-011-1: Existing function behaviour is preserved", () => {
  it("createWorktree returns { worktreePath, branchName }", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const result = await createWorktree(repo, "shim-seed-001");

    expect(result).toHaveProperty("worktreePath");
    expect(result).toHaveProperty("branchName");
    expect(result.branchName).toBe("foreman/shim-seed-001");
    expect(result.worktreePath).toBe(join(repo, ".foreman-worktrees", "shim-seed-001"));
    expect(existsSync(result.worktreePath)).toBe(true);
  });

  it("removeWorktree removes the worktree directory", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const { worktreePath } = await createWorktree(repo, "shim-seed-002");
    expect(existsSync(worktreePath)).toBe(true);

    await removeWorktree(repo, worktreePath);
    expect(existsSync(worktreePath)).toBe(false);
  });

  it("listWorktrees returns Worktree[] with path/branch/head/bare fields", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    await createWorktree(repo, "shim-seed-003");

    const worktrees = await listWorktrees(repo);
    expect(Array.isArray(worktrees)).toBe(true);
    expect(worktrees.length).toBeGreaterThanOrEqual(2);

    const wt = worktrees.find((w) => w.branch === "foreman/shim-seed-003");
    expect(wt).toBeDefined();
    // Verify all required fields of the Worktree interface are present
    expect(typeof wt!.path).toBe("string");
    expect(typeof wt!.branch).toBe("string");
    expect(typeof wt!.head).toBe("string");
    expect(typeof wt!.bare).toBe("boolean");
  });

  it("gitBranchExists returns false for non-existent branch", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const exists = await gitBranchExists(repo, "no-such-branch");
    expect(exists).toBe(false);
  });

  it("gitBranchExists returns true for existing branch", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    await createWorktree(repo, "shim-seed-004");
    const exists = await gitBranchExists(repo, "foreman/shim-seed-004");
    expect(exists).toBe(true);
  });

  it("detectDefaultBranch returns current branch for fresh repo", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const branch = await detectDefaultBranch(repo);
    // Fresh repo with --initial-branch=main should return "main"
    expect(branch).toBe("main");
  });

  it("getCurrentBranch returns the active branch name", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const branch = await getCurrentBranch(repo);
    expect(branch).toBe("main");
  });

  it("getRepoRoot resolves to the repo root", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const root = await getRepoRoot(repo);
    expect(root).toBe(repo);
  });

  it("mergeWorktree returns { success: boolean }", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const { worktreePath, branchName } = await createWorktree(repo, "shim-merge-001");
    writeFileSync(join(worktreePath, "feature.txt"), "hello\n");
    execFileSync("git", ["add", "feature.txt"], { cwd: worktreePath });
    execFileSync("git", ["commit", "-m", "add feature"], { cwd: worktreePath });

    const result = await mergeWorktree(repo, branchName);
    expect(result).toHaveProperty("success");
    expect(result.success).toBe(true);
  });

  it("deleteBranch returns { deleted: boolean, wasFullyMerged: boolean }", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    // Try to delete a non-existent branch — returns deleted: false, wasFullyMerged: true
    const result = await deleteBranch(repo, "no-such-branch");
    expect(result).toHaveProperty("deleted");
    expect(result).toHaveProperty("wasFullyMerged");
    expect(result.deleted).toBe(false);
    expect(result.wasFullyMerged).toBe(true);
  });
});

// ═══════════════════════════════════════════════════════════════════════════
// AC-T-011-2: Old functions delegate to GitBackend methods
// ═══════════════════════════════════════════════════════════════════════════

describe("AC-T-011-2: Function delegation to GitBackend", () => {
  /**
   * These tests verify the shim contract: each old function should delegate
   * to the corresponding GitBackend method. The tests use vi.mock to intercept
   * GitBackend construction/method calls.
   *
   * NOTE: These tests are written as the TDD "RED" spec for TRD-011.
   * They will pass only once git.ts has been converted to a thin shim
   * that creates a GitBackend instance and delegates calls to it.
   *
   * TRD-011 implementation checklist:
   *   - git.ts imports GitBackend from ./vcs/git-backend.js
   *   - git.ts uses a per-call or singleton GitBackend instance
   *   - createWorktree() calls backend.createWorkspace() and maps workspacePath → worktreePath
   *   - removeWorktree() calls backend.removeWorkspace()
   *   - listWorktrees() calls backend.listWorkspaces() and maps Workspace[] → Worktree[]
   *   - mergeWorktree() calls backend.merge()
   *   - gitBranchExists() calls backend.branchExists()
   *   - branchExistsOnOrigin() calls backend.branchExistsOnRemote()
   *   - deleteBranch() calls backend.deleteBranch()
   *   - getRepoRoot() calls backend.getRepoRoot()
   *   - getMainRepoRoot() calls backend.getMainRepoRoot()
   *   - detectDefaultBranch() calls backend.detectDefaultBranch()
   *   - getCurrentBranch() calls backend.getCurrentBranch()
   *   - checkoutBranch() calls backend.checkoutBranch()
   */

  it("createWorktree result has worktreePath field (old API shape)", async () => {
    // After shim: createWorktree must return { worktreePath, branchName }
    // (mapping from GitBackend's WorkspaceResult.workspacePath to old worktreePath)
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const result = await createWorktree(repo, "delegation-seed-001");
    // The shim MUST rename workspacePath → worktreePath for backward compatibility
    expect(result).toHaveProperty("worktreePath");
    expect(result).not.toHaveProperty("workspacePath"); // old API must NOT expose workspacePath
    expect(result).toHaveProperty("branchName");
  });

  it("listWorktrees returns Worktree[] not Workspace[]", async () => {
    // The shim must map GitBackend.listWorkspaces() → old Worktree[] shape
    // The Worktree interface and Workspace interface share identical fields
    // (path, branch, head, bare), so this is a no-op structural mapping.
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const worktrees = await listWorktrees(repo);
    for (const wt of worktrees) {
      // Each element must have the Worktree fields
      expect(wt).toHaveProperty("path");
      expect(wt).toHaveProperty("branch");
      expect(wt).toHaveProperty("head");
      expect(wt).toHaveProperty("bare");
      // Must NOT have extra Workspace-only fields (none exist — they're identical)
    }
  });

  it("gitBranchExists delegates to branchExists (name compatibility)", async () => {
    // gitBranchExists (old name) is the shim wrapper for GitBackend.branchExists()
    // Both must return the same result for the same inputs.
    const repo = makeTempRepo();
    tempDirs.push(repo);

    await createWorktree(repo, "delegation-seed-002");

    // Both old name (gitBranchExists) and branchExists-like behavior must work
    const exists = await gitBranchExists(repo, "foreman/delegation-seed-002");
    expect(exists).toBe(true);

    const notExists = await gitBranchExists(repo, "no-such-branch");
    expect(notExists).toBe(false);
  });

  it("branchExistsOnOrigin delegates to branchExistsOnRemote (name compatibility)", async () => {
    // branchExistsOnOrigin (old name) wraps GitBackend.branchExistsOnRemote()
    // Without a remote configured, both must return false.
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const exists = await branchExistsOnOrigin(repo, "main");
    // No remote configured in temp repo → must return false (not throw)
    expect(exists).toBe(false);
  });

  it("mergeWorktree returns success:true for a clean merge", async () => {
    // Verifies the shim maps GitBackend.merge() → old MergeResult shape
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const { worktreePath, branchName } = await createWorktree(repo, "delegation-merge");
    writeFileSync(join(worktreePath, "new-file.txt"), "content\n");
    execFileSync("git", ["add", "new-file.txt"], { cwd: worktreePath });
    execFileSync("git", ["commit", "-m", "add new file"], { cwd: worktreePath });

    const result: MergeResult = await mergeWorktree(repo, branchName);
    expect(result.success).toBe(true);
    expect(result.conflicts).toBeUndefined();
  });
});

// ═══════════════════════════════════════════════════════════════════════════
// AC-T-011-3: Type compatibility — Worktree ≡ Workspace, MergeResult, etc.
// ═══════════════════════════════════════════════════════════════════════════

describe("AC-T-011-3: Type compatibility between old and new type exports", () => {
  it("Worktree is structurally compatible with Workspace (same fields)", () => {
    /**
     * TypeScript structural typing: if Worktree = Workspace (alias or re-export),
     * then an object satisfying Workspace also satisfies Worktree.
     * This test verifies runtime structural compatibility.
     */
    const workspace: Workspace = {
      path: "/tmp/test",
      branch: "foreman/test",
      head: "abc123",
      bare: false,
    };

    // Assign Workspace to Worktree — must be structurally compatible
    // (TypeScript compile-time check: both have identical required fields)
    const worktree: Worktree = workspace;

    expect(worktree.path).toBe(workspace.path);
    expect(worktree.branch).toBe(workspace.branch);
    expect(worktree.head).toBe(workspace.head);
    expect(worktree.bare).toBe(workspace.bare);
  });

  it("Workspace is structurally compatible with Worktree (same fields)", () => {
    const worktree: Worktree = {
      path: "/tmp/test2",
      branch: "foreman/test2",
      head: "def456",
      bare: true,
    };

    // Reverse assignment — also must compile without error
    const workspace: Workspace = worktree;

    expect(workspace.path).toBe(worktree.path);
    expect(workspace.branch).toBe(worktree.branch);
    expect(workspace.head).toBe(worktree.head);
    expect(workspace.bare).toBe(worktree.bare);
  });

  it("Worktree has exactly the required fields: path, branch, head, bare", () => {
    const wt: Worktree = {
      path: "/some/path",
      branch: "feature/x",
      head: "sha1abc",
      bare: false,
    };
    // Verify all four fields are present and properly typed
    expect(typeof wt.path).toBe("string");
    expect(typeof wt.branch).toBe("string");
    expect(typeof wt.head).toBe("string");
    expect(typeof wt.bare).toBe("boolean");
  });

  it("MergeResult from git.ts is structurally compatible with VCS MergeResult", () => {
    // Both old and new MergeResult have { success: boolean; conflicts?: string[] }
    const oldResult: MergeResult = { success: true };
    const newResult: VcsMergeResult = oldResult; // compile-time compatibility
    expect(newResult.success).toBe(true);

    const withConflicts: MergeResult = { success: false, conflicts: ["file.ts"] };
    const newWithConflicts: VcsMergeResult = withConflicts;
    expect(newWithConflicts.success).toBe(false);
    expect(newWithConflicts.conflicts).toEqual(["file.ts"]);
  });

  it("DeleteBranchResult from git.ts is structurally compatible with VCS DeleteBranchResult", () => {
    // Both have { deleted: boolean; wasFullyMerged: boolean }
    const oldResult: DeleteBranchResult = { deleted: true, wasFullyMerged: true };
    const newResult: VcsDeleteBranchResult = oldResult; // compile-time compatibility
    expect(newResult.deleted).toBe(true);
    expect(newResult.wasFullyMerged).toBe(true);

    const notDeleted: DeleteBranchResult = { deleted: false, wasFullyMerged: false };
    const newNotDeleted: VcsDeleteBranchResult = notDeleted;
    expect(newNotDeleted.deleted).toBe(false);
    expect(newNotDeleted.wasFullyMerged).toBe(false);
  });

  it("listWorktrees returns objects satisfying both Worktree and Workspace shapes", async () => {
    // Since Worktree ≡ Workspace structurally, objects from listWorktrees()
    // must satisfy both type shapes at runtime.
    const repo = makeTempRepo();
    tempDirs.push(repo);

    await createWorktree(repo, "type-compat-001");

    const worktrees: Worktree[] = await listWorktrees(repo);
    const asWorkspaces: Workspace[] = worktrees; // structural compatibility

    expect(asWorkspaces.length).toBeGreaterThanOrEqual(1);
    for (const ws of asWorkspaces) {
      expect(ws).toHaveProperty("path");
      expect(ws).toHaveProperty("branch");
      expect(ws).toHaveProperty("head");
      expect(ws).toHaveProperty("bare");
    }
  });
});

// ═══════════════════════════════════════════════════════════════════════════
// AC-T-011-2 (extended): GitBackend mock delegation tests
// These tests will be uncommented and pass once TRD-011 converts git.ts to a shim.
// They are currently skipped to avoid false failures during the RED phase.
// ═══════════════════════════════════════════════════════════════════════════

describe("AC-T-011-2: GitBackend delegation (mock-based, requires TRD-011 shim)", () => {
  /**
   * Once TRD-011 converts git.ts to import and use GitBackend, these tests
   * will verify the delegation using vi.mock.
   *
   * Current status: SKIPPED — git.ts is not yet a shim (TRD-011 pending).
   * After TRD-011: remove the .skip and update mock paths as needed.
   */

  it("createWorktree() delegates to GitBackend.createWorkspace() and maps workspacePath → worktreePath", async () => {
    const mockResult = { workspacePath: "/fake/.foreman-worktrees/seed-x", branchName: "foreman/seed-x" };
    const spy = vi.spyOn(GitBackend.prototype, "createWorkspace").mockResolvedValue(mockResult);

    const result = await createWorktree("/fake/repo", "seed-x");

    expect(spy).toHaveBeenCalledWith("/fake/repo", "seed-x", undefined);
    // Shim must rename workspacePath → worktreePath
    expect(result.worktreePath).toBe(mockResult.workspacePath);
    expect(result.branchName).toBe(mockResult.branchName);
    expect(result).not.toHaveProperty("workspacePath");
  });

  it("removeWorktree() delegates to GitBackend.removeWorkspace()", async () => {
    const spy = vi.spyOn(GitBackend.prototype, "removeWorkspace").mockResolvedValue(undefined);

    await removeWorktree("/fake/repo", "/fake/repo/.foreman-worktrees/seed-y");

    expect(spy).toHaveBeenCalledWith("/fake/repo", "/fake/repo/.foreman-worktrees/seed-y");
  });

  it("listWorktrees() delegates to GitBackend.listWorkspaces() and returns Worktree[]", async () => {
    const mockWorkspaces: Workspace[] = [
      { path: "/fake/repo", branch: "main", head: "abc123", bare: false },
      { path: "/fake/repo/.foreman-worktrees/seed-z", branch: "foreman/seed-z", head: "def456", bare: false },
    ];
    const spy = vi.spyOn(GitBackend.prototype, "listWorkspaces").mockResolvedValue(mockWorkspaces);

    const result: Worktree[] = await listWorktrees("/fake/repo");

    expect(spy).toHaveBeenCalledWith("/fake/repo");
    expect(result).toEqual(mockWorkspaces);
    // Each element must satisfy Worktree shape
    for (const wt of result) {
      expect(wt).toHaveProperty("path");
      expect(wt).toHaveProperty("branch");
      expect(wt).toHaveProperty("head");
      expect(wt).toHaveProperty("bare");
    }
  });

  it("mergeWorktree() delegates to GitBackend.merge()", async () => {
    const mockResult: MergeResult = { success: true };
    const spy = vi.spyOn(GitBackend.prototype, "merge").mockResolvedValue(mockResult);

    const result = await mergeWorktree("/fake/repo", "foreman/seed-m", "main");

    expect(spy).toHaveBeenCalledWith("/fake/repo", "foreman/seed-m", "main");
    expect(result).toEqual(mockResult);
  });

  it("gitBranchExists() delegates to GitBackend.branchExists()", async () => {
    const spy = vi.spyOn(GitBackend.prototype, "branchExists").mockResolvedValue(true);

    const result = await gitBranchExists("/fake/repo", "foreman/seed-b");

    expect(spy).toHaveBeenCalledWith("/fake/repo", "foreman/seed-b");
    expect(result).toBe(true);
  });

  it("branchExistsOnOrigin() delegates to GitBackend.branchExistsOnRemote()", async () => {
    const spy = vi.spyOn(GitBackend.prototype, "branchExistsOnRemote").mockResolvedValue(false);

    const result = await branchExistsOnOrigin("/fake/repo", "main");

    expect(spy).toHaveBeenCalledWith("/fake/repo", "main");
    expect(result).toBe(false);
  });

  it("deleteBranch() delegates to GitBackend.deleteBranch()", async () => {
    const mockResult: DeleteBranchResult = { deleted: true, wasFullyMerged: true };
    const spy = vi.spyOn(GitBackend.prototype, "deleteBranch").mockResolvedValue(mockResult);

    const result = await deleteBranch("/fake/repo", "old-branch", { force: false });

    expect(spy).toHaveBeenCalledWith("/fake/repo", "old-branch", { force: false });
    expect(result).toEqual(mockResult);
  });

  it("getRepoRoot() delegates to GitBackend.getRepoRoot()", async () => {
    const spy = vi.spyOn(GitBackend.prototype, "getRepoRoot").mockResolvedValue("/fake/root");

    const result = await getRepoRoot("/fake/root/subdir");

    expect(spy).toHaveBeenCalledWith("/fake/root/subdir");
    expect(result).toBe("/fake/root");
  });

  it("getMainRepoRoot() delegates to GitBackend.getMainRepoRoot()", async () => {
    const spy = vi.spyOn(GitBackend.prototype, "getMainRepoRoot").mockResolvedValue("/fake/main-root");

    const result = await getMainRepoRoot("/fake/worktree");

    expect(spy).toHaveBeenCalledWith("/fake/worktree");
    expect(result).toBe("/fake/main-root");
  });

  it("detectDefaultBranch() delegates to GitBackend.detectDefaultBranch()", async () => {
    const spy = vi.spyOn(GitBackend.prototype, "detectDefaultBranch").mockResolvedValue("dev");

    const result = await detectDefaultBranch("/fake/repo");

    expect(spy).toHaveBeenCalledWith("/fake/repo");
    expect(result).toBe("dev");
  });

  it("getCurrentBranch() delegates to GitBackend.getCurrentBranch()", async () => {
    const spy = vi.spyOn(GitBackend.prototype, "getCurrentBranch").mockResolvedValue("feature/abc");

    const result = await getCurrentBranch("/fake/repo");

    expect(spy).toHaveBeenCalledWith("/fake/repo");
    expect(result).toBe("feature/abc");
  });

  it("checkoutBranch() delegates to GitBackend.checkoutBranch()", async () => {
    const spy = vi.spyOn(GitBackend.prototype, "checkoutBranch").mockResolvedValue(undefined);

    await checkoutBranch("/fake/repo", "feature/xyz");

    expect(spy).toHaveBeenCalledWith("/fake/repo", "feature/xyz");
  });
});
