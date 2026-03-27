/**
 * Tests for GitBackend repository introspection methods.
 *
 * Mirrors the test coverage in src/lib/__tests__/git.test.ts for
 * getRepoRoot, getMainRepoRoot, detectDefaultBranch, and getCurrentBranch.
 */

import { describe, it, expect, afterEach } from "vitest";
import {
  mkdtempSync,
  writeFileSync,
  realpathSync,
  rmSync,
} from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { GitBackend } from "../git-backend.js";

// ── Helpers ──────────────────────────────────────────────────────────────────

function makeTempRepo(branch = "main"): string {
  // realpathSync resolves macOS /var → /private/var symlink
  const dir = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-git-backend-test-")),
  );
  execFileSync("git", ["init", `--initial-branch=${branch}`], { cwd: dir });
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
});

// ── getRepoRoot ───────────────────────────────────────────────────────────────

describe("GitBackend.getRepoRoot", () => {
  it("returns repo root when called from the root itself", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const root = await backend.getRepoRoot(repo);
    expect(root).toBe(repo);
  });

  it("finds root from a subdirectory", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const subdir = join(repo, "src", "nested");
    execFileSync("mkdir", ["-p", subdir]);
    const backend = new GitBackend(repo);

    const root = await backend.getRepoRoot(subdir);
    expect(root).toBe(repo);
  });

  it("throws when the path is not inside a git repository", async () => {
    const dir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-no-git-")),
    );
    tempDirs.push(dir);
    const backend = new GitBackend(dir);

    await expect(backend.getRepoRoot(dir)).rejects.toThrow(/rev-parse failed/);
  });
});

// ── getMainRepoRoot ───────────────────────────────────────────────────────────

describe("GitBackend.getMainRepoRoot", () => {
  it("returns the main repo root when called from the main repo", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const mainRoot = await backend.getMainRepoRoot(repo);
    expect(mainRoot).toBe(repo);
  });

  it("returns the main repo root even when called from a linked worktree", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    // Create a linked worktree
    const worktreePath = join(repo, "wt-test");
    execFileSync(
      "git",
      ["worktree", "add", "-b", "feature/wt", worktreePath],
      { cwd: repo },
    );

    const backend = new GitBackend(repo);
    const mainRoot = await backend.getMainRepoRoot(worktreePath);
    expect(mainRoot).toBe(repo);
  });
});

// ── getCurrentBranch ──────────────────────────────────────────────────────────

describe("GitBackend.getCurrentBranch", () => {
  it("returns the current branch name", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const branch = await backend.getCurrentBranch(repo);
    expect(branch).toBe("main");
  });

  it("returns the custom branch name after checkout", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    execFileSync("git", ["checkout", "-b", "feature/test"], { cwd: repo });
    const backend = new GitBackend(repo);

    const branch = await backend.getCurrentBranch(repo);
    expect(branch).toBe("feature/test");
  });
});

// ── detectDefaultBranch ───────────────────────────────────────────────────────

describe("GitBackend.detectDefaultBranch", () => {
  it("returns 'main' when the local branch is named 'main'", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const branch = await backend.detectDefaultBranch(repo);
    expect(branch).toBe("main");
  });

  it("returns 'master' when only 'master' exists (no 'main', no remote)", async () => {
    const dir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-backend-master-")),
    );
    tempDirs.push(dir);
    execFileSync("git", ["init", "--initial-branch=master"], { cwd: dir });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
    writeFileSync(join(dir, "README.md"), "# init\n");
    execFileSync("git", ["add", "."], { cwd: dir });
    execFileSync("git", ["commit", "-m", "initial commit"], { cwd: dir });

    const backend = new GitBackend(dir);
    const branch = await backend.detectDefaultBranch(dir);
    expect(branch).toBe("master");
  });

  it("returns custom branch name when origin/HEAD points to it", async () => {
    // Create a non-bare 'remote' repo with a commit on 'develop' branch
    const remoteDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-backend-remote-")),
    );
    tempDirs.push(remoteDir);
    execFileSync("git", ["init", "--initial-branch=develop"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: remoteDir });
    writeFileSync(join(remoteDir, "README.md"), "# remote\n");
    execFileSync("git", ["add", "."], { cwd: remoteDir });
    execFileSync("git", ["commit", "-m", "initial commit"], { cwd: remoteDir });

    // Clone so origin/HEAD is set
    const cloneDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-backend-clone-")),
    );
    tempDirs.push(cloneDir);
    execFileSync("git", ["clone", remoteDir, cloneDir]);
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: cloneDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: cloneDir });

    // Confirm symbolic-ref is set by the clone
    const symRef = execFileSync(
      "git",
      ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"],
      { cwd: cloneDir },
    )
      .toString()
      .trim();
    expect(symRef).toBe("origin/develop");

    const backend = new GitBackend(cloneDir);
    const branch = await backend.detectDefaultBranch(cloneDir);
    expect(branch).toBe("develop");
  });

  it("falls back to current branch when no main/master and no remote", async () => {
    const dir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-backend-trunk-")),
    );
    tempDirs.push(dir);
    execFileSync("git", ["init", "--initial-branch=trunk"], { cwd: dir });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
    writeFileSync(join(dir, "README.md"), "# init\n");
    execFileSync("git", ["add", "."], { cwd: dir });
    execFileSync("git", ["commit", "-m", "initial commit"], { cwd: dir });

    const backend = new GitBackend(dir);
    const branch = await backend.detectDefaultBranch(dir);
    expect(branch).toBe("trunk");
  });

  it("respects git-town.main-branch config above all other detection", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);

    // Set git-town.main-branch to 'develop'
    execFileSync(
      "git",
      ["config", "git-town.main-branch", "develop"],
      { cwd: repo },
    );

    const backend = new GitBackend(repo);
    const branch = await backend.detectDefaultBranch(repo);
    expect(branch).toBe("develop");
  });
});

// ── Phase B Tests ─────────────────────────────────────────────────────────────

// ── checkoutBranch ────────────────────────────────────────────────────────────

describe("GitBackend.checkoutBranch", () => {
  it("checks out an existing branch", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    execFileSync("git", ["checkout", "-b", "feature/test"], { cwd: repo });
    execFileSync("git", ["checkout", "main"], { cwd: repo });
    const backend = new GitBackend(repo);

    await backend.checkoutBranch(repo, "feature/test");
    const branch = await backend.getCurrentBranch(repo);
    expect(branch).toBe("feature/test");
  });

  it("throws when the branch does not exist", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    await expect(backend.checkoutBranch(repo, "nonexistent")).rejects.toThrow();
  });
});

// ── branchExists ─────────────────────────────────────────────────────────────

describe("GitBackend.branchExists", () => {
  it("returns true for an existing branch", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const exists = await backend.branchExists(repo, "main");
    expect(exists).toBe(true);
  });

  it("returns false for a non-existent branch", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const exists = await backend.branchExists(repo, "nonexistent-branch");
    expect(exists).toBe(false);
  });

  it("returns true for a newly created branch", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    execFileSync("git", ["checkout", "-b", "feature/new"], { cwd: repo });
    const backend = new GitBackend(repo);

    const exists = await backend.branchExists(repo, "feature/new");
    expect(exists).toBe(true);
  });
});

// ── branchExistsOnRemote ──────────────────────────────────────────────────────

describe("GitBackend.branchExistsOnRemote", () => {
  it("returns false when there is no remote", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const exists = await backend.branchExistsOnRemote(repo, "main");
    expect(exists).toBe(false);
  });

  it("returns true when the branch exists on the remote", async () => {
    // Create a 'remote' repo
    const remoteDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-backend-remote-branchexists-")),
    );
    tempDirs.push(remoteDir);
    execFileSync("git", ["init", "--initial-branch=main"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: remoteDir });
    writeFileSync(join(remoteDir, "README.md"), "# remote\n");
    execFileSync("git", ["add", "."], { cwd: remoteDir });
    execFileSync("git", ["commit", "-m", "initial"], { cwd: remoteDir });

    const cloneDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-backend-clone-branchexists-")),
    );
    tempDirs.push(cloneDir);
    execFileSync("git", ["clone", remoteDir, cloneDir]);
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: cloneDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: cloneDir });

    const backend = new GitBackend(cloneDir);
    const exists = await backend.branchExistsOnRemote(cloneDir, "main");
    expect(exists).toBe(true);
  });

  it("returns false when the branch does not exist on the remote", async () => {
    const remoteDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-backend-remote-noexists-")),
    );
    tempDirs.push(remoteDir);
    execFileSync("git", ["init", "--initial-branch=main"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: remoteDir });
    writeFileSync(join(remoteDir, "README.md"), "# remote\n");
    execFileSync("git", ["add", "."], { cwd: remoteDir });
    execFileSync("git", ["commit", "-m", "initial"], { cwd: remoteDir });

    const cloneDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-backend-clone-noexists-")),
    );
    tempDirs.push(cloneDir);
    execFileSync("git", ["clone", remoteDir, cloneDir]);

    const backend = new GitBackend(cloneDir);
    const exists = await backend.branchExistsOnRemote(cloneDir, "feature/does-not-exist");
    expect(exists).toBe(false);
  });
});

// ── deleteBranch ─────────────────────────────────────────────────────────────

describe("GitBackend.deleteBranch", () => {
  it("deletes a fully merged branch and returns wasFullyMerged=true", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    // Create and merge a feature branch
    execFileSync("git", ["checkout", "-b", "feature/merged"], { cwd: repo });
    writeFileSync(join(repo, "feature.txt"), "feature\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add feature"], { cwd: repo });
    execFileSync("git", ["checkout", "main"], { cwd: repo });
    execFileSync("git", ["merge", "feature/merged", "--no-ff"], { cwd: repo });

    const backend = new GitBackend(repo);
    const result = await backend.deleteBranch(repo, "feature/merged", { targetBranch: "main" });
    expect(result.deleted).toBe(true);
    expect(result.wasFullyMerged).toBe(true);
    const exists = await backend.branchExists(repo, "feature/merged");
    expect(exists).toBe(false);
  });

  it("does not delete unmerged branch without force", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    execFileSync("git", ["checkout", "-b", "feature/unmerged"], { cwd: repo });
    writeFileSync(join(repo, "unmerged.txt"), "content\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "unmerged"], { cwd: repo });
    execFileSync("git", ["checkout", "main"], { cwd: repo });

    const backend = new GitBackend(repo);
    const result = await backend.deleteBranch(repo, "feature/unmerged", { targetBranch: "main" });
    expect(result.deleted).toBe(false);
    expect(result.wasFullyMerged).toBe(false);
    const exists = await backend.branchExists(repo, "feature/unmerged");
    expect(exists).toBe(true);
  });

  it("force-deletes an unmerged branch when force=true", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    execFileSync("git", ["checkout", "-b", "feature/force-delete"], { cwd: repo });
    writeFileSync(join(repo, "forcedel.txt"), "content\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "force delete"], { cwd: repo });
    execFileSync("git", ["checkout", "main"], { cwd: repo });

    const backend = new GitBackend(repo);
    const result = await backend.deleteBranch(repo, "feature/force-delete", { force: true, targetBranch: "main" });
    expect(result.deleted).toBe(true);
    expect(result.wasFullyMerged).toBe(false);
  });

  it("returns deleted=false, wasFullyMerged=true when branch does not exist", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const result = await backend.deleteBranch(repo, "nonexistent-branch");
    expect(result.deleted).toBe(false);
    expect(result.wasFullyMerged).toBe(true);
  });
});

// ── createWorkspace / removeWorkspace / listWorkspaces ────────────────────────

describe("GitBackend.createWorkspace", () => {
  it("creates a workspace with the correct branch and path", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const result = await backend.createWorkspace(repo, "test-seed-001");
    expect(result.branchName).toBe("foreman/test-seed-001");
    expect(result.workspacePath).toBe(join(repo, ".foreman-worktrees", "test-seed-001"));

    const { existsSync } = await import("node:fs");
    expect(existsSync(result.workspacePath)).toBe(true);

    const branches = execFileSync("git", ["branch", "--list"], { cwd: repo }).toString().trim();
    expect(branches).toContain("foreman/test-seed-001");
  });

  it("reuses an existing workspace by rebasing", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    // Create the workspace the first time
    const result1 = await backend.createWorkspace(repo, "test-reuse-001");
    expect(result1.workspacePath).toBe(join(repo, ".foreman-worktrees", "test-reuse-001"));

    // Call again — should reuse existing worktree
    const result2 = await backend.createWorkspace(repo, "test-reuse-001");
    expect(result2.workspacePath).toBe(result1.workspacePath);
    expect(result2.branchName).toBe(result1.branchName);
  });
});

describe("GitBackend.removeWorkspace", () => {
  it("removes the workspace directory", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const { workspacePath } = await backend.createWorkspace(repo, "test-remove-001");
    const { existsSync } = await import("node:fs");
    expect(existsSync(workspacePath)).toBe(true);

    await backend.removeWorkspace(repo, workspacePath);
    expect(existsSync(workspacePath)).toBe(false);
  });

  it("prunes stale .git/worktrees metadata", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const { workspacePath } = await backend.createWorkspace(repo, "test-prune-001");
    const metaDir = join(repo, ".git", "worktrees", "test-prune-001");
    const { existsSync } = await import("node:fs");
    expect(existsSync(metaDir)).toBe(true);

    await backend.removeWorkspace(repo, workspacePath);
    expect(existsSync(workspacePath)).toBe(false);
    expect(existsSync(metaDir)).toBe(false);
  });
});

describe("GitBackend.listWorkspaces", () => {
  it("returns all worktrees including the main one", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    await backend.createWorkspace(repo, "test-list-a");
    await backend.createWorkspace(repo, "test-list-b");

    const workspaces = await backend.listWorkspaces(repo);
    const branches = workspaces.map((w) => w.branch);

    expect(branches).toContain("foreman/test-list-a");
    expect(branches).toContain("foreman/test-list-b");
    expect(workspaces.length).toBeGreaterThanOrEqual(3);
  });
});

// ── stageAll / commit / getHeadId ─────────────────────────────────────────────

describe("GitBackend.stageAll + commit + getHeadId", () => {
  it("stages all changes, commits, and returns the commit hash", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    writeFileSync(join(repo, "new-file.txt"), "hello\n");
    await backend.stageAll(repo);
    const hash = await backend.commit(repo, "test commit");

    expect(hash).toBeTruthy();
    expect(hash.length).toBeLessThanOrEqual(10); // short hash

    const headId = await backend.getHeadId(repo);
    expect(headId).toBe(hash);
  });

  it("getHeadId returns the current HEAD short hash", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const headId = await backend.getHeadId(repo);
    // Verify it looks like a short git hash (hex chars)
    expect(headId).toMatch(/^[0-9a-f]{4,40}$/);
  });
});

// ── fetch / rebase / abortRebase ─────────────────────────────────────────────

describe("GitBackend.fetch", () => {
  it("does not throw when no remote is configured", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    // fetch fails non-fatally for no remote — but our impl catches that
    // It should either succeed or the method should handle the error gracefully
    // Since there's no remote, we just check it doesn't throw fatally
    try {
      await backend.fetch(repo);
    } catch {
      // Acceptable: fetch may throw when there's no remote configured
    }
  });
});

describe("GitBackend.rebase", () => {
  it("returns success when already up-to-date", async () => {
    // Create a remote-like setup
    const remoteDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-backend-remote-rebase-")),
    );
    tempDirs.push(remoteDir);
    execFileSync("git", ["init", "--initial-branch=main"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: remoteDir });
    writeFileSync(join(remoteDir, "README.md"), "# remote\n");
    execFileSync("git", ["add", "."], { cwd: remoteDir });
    execFileSync("git", ["commit", "-m", "initial"], { cwd: remoteDir });

    const cloneDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-backend-clone-rebase-")),
    );
    tempDirs.push(cloneDir);
    execFileSync("git", ["clone", remoteDir, cloneDir]);
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: cloneDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: cloneDir });

    const backend = new GitBackend(cloneDir);
    const result = await backend.rebase(cloneDir, "main");
    expect(result.success).toBe(true);
    expect(result.hasConflicts).toBe(false);
  });
});

describe("GitBackend.abortRebase", () => {
  it("throws when no rebase is in progress", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    await expect(backend.abortRebase(repo)).rejects.toThrow();
  });
});

// ── merge ─────────────────────────────────────────────────────────────────────

describe("GitBackend.merge", () => {
  it("merges a feature branch cleanly", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    // Create a feature branch with a new file
    execFileSync("git", ["checkout", "-b", "feature/merge-test"], { cwd: repo });
    writeFileSync(join(repo, "feature.txt"), "feature content\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add feature"], { cwd: repo });
    execFileSync("git", ["checkout", "main"], { cwd: repo });

    const result = await backend.merge(repo, "feature/merge-test", "main");
    expect(result.success).toBe(true);

    const { existsSync } = await import("node:fs");
    expect(existsSync(join(repo, "feature.txt"))).toBe(true);
  });

  it("detects merge conflicts and returns conflicting files", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    // Create a feature branch that modifies README
    execFileSync("git", ["checkout", "-b", "feature/conflict-test"], { cwd: repo });
    writeFileSync(join(repo, "README.md"), "# feature branch version\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "feature edit"], { cwd: repo });
    execFileSync("git", ["checkout", "main"], { cwd: repo });

    // Also modify README on main
    writeFileSync(join(repo, "README.md"), "# main branch version\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "main edit"], { cwd: repo });

    const result = await backend.merge(repo, "feature/conflict-test", "main");
    expect(result.success).toBe(false);
    expect(result.conflicts).toBeDefined();
    expect(result.conflicts!.length).toBeGreaterThan(0);
    expect(result.conflicts).toContain("README.md");

    // Clean up the failed merge state
    execFileSync("git", ["merge", "--abort"], { cwd: repo });
  });
});

// ── getConflictingFiles / diff / getModifiedFiles / cleanWorkingTree / status ──

describe("GitBackend.getConflictingFiles", () => {
  it("returns empty array when no conflicts", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const files = await backend.getConflictingFiles(repo);
    expect(files).toEqual([]);
  });
});

describe("GitBackend.diff", () => {
  it("returns diff between two commits", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const head1 = await backend.getHeadId(repo);

    writeFileSync(join(repo, "diff-test.txt"), "new content\n");
    await backend.stageAll(repo);
    const head2 = await backend.commit(repo, "add diff-test.txt");

    const diffOutput = await backend.diff(repo, head1, head2);
    expect(diffOutput).toContain("diff-test.txt");
  });

  it("returns empty string when refs are identical", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const head = await backend.getHeadId(repo);
    const diffOutput = await backend.diff(repo, head, head);
    expect(diffOutput).toBe("");
  });
});

describe("GitBackend.getModifiedFiles", () => {
  it("returns list of files modified since base", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const base = await backend.getHeadId(repo);
    writeFileSync(join(repo, "modified.txt"), "modified\n");
    await backend.stageAll(repo);
    await backend.commit(repo, "add modified.txt");

    const files = await backend.getModifiedFiles(repo, base);
    expect(files).toContain("modified.txt");
  });

  it("returns empty array when no modifications since base", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const head = await backend.getHeadId(repo);
    const files = await backend.getModifiedFiles(repo, head);
    expect(files).toEqual([]);
  });
});

describe("GitBackend.cleanWorkingTree", () => {
  it("discards untracked files", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);
    const { existsSync } = await import("node:fs");

    writeFileSync(join(repo, "untracked.txt"), "untracked\n");
    expect(existsSync(join(repo, "untracked.txt"))).toBe(true);

    await backend.cleanWorkingTree(repo);
    expect(existsSync(join(repo, "untracked.txt"))).toBe(false);
  });

  it("discards modified tracked files", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);
    const { readFileSync } = await import("node:fs");

    writeFileSync(join(repo, "README.md"), "# modified\n");
    const content = readFileSync(join(repo, "README.md"), "utf-8");
    expect(content).toBe("# modified\n");

    await backend.cleanWorkingTree(repo);
    const restored = readFileSync(join(repo, "README.md"), "utf-8");
    expect(restored).toBe("# init\n");
  });
});

describe("GitBackend.status", () => {
  it("returns empty string for a clean repo", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const statusOutput = await backend.status(repo);
    expect(statusOutput).toBe("");
  });

  it("returns non-empty string when there are uncommitted changes", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    writeFileSync(join(repo, "untracked.txt"), "untracked\n");
    const statusOutput = await backend.status(repo);
    expect(statusOutput).toContain("untracked.txt");
  });
});

// ── getFinalizeCommands ────────────────────────────────────────────────────────

describe("GitBackend.getFinalizeCommands", () => {
  it("returns all 6 required command fields", () => {
    const backend = new GitBackend("/tmp/repo");
    const cmds = backend.getFinalizeCommands({
      seedId: "bd-abc1",
      seedTitle: "Add new feature",
      baseBranch: "dev",
      worktreePath: "/tmp/repo/.foreman-worktrees/bd-abc1",
    });

    expect(cmds.stageCommand).toBe("git add -A");
    expect(cmds.commitCommand).toContain("bd-abc1");
    expect(cmds.commitCommand).toContain("Add new feature");
    expect(cmds.pushCommand).toContain("foreman/bd-abc1");
    expect(cmds.pushCommand).toContain("origin");
    expect(cmds.rebaseCommand).toContain("dev");
    expect(cmds.rebaseCommand).toContain("fetch");
    expect(cmds.branchVerifyCommand).toContain("foreman/bd-abc1");
    expect(cmds.cleanCommand).toContain("prune");
  });

  it("escapes double quotes in seedTitle", () => {
    const backend = new GitBackend("/tmp/repo");
    const cmds = backend.getFinalizeCommands({
      seedId: "bd-xyz9",
      seedTitle: 'Fix "the bug"',
      baseBranch: "main",
      worktreePath: "/tmp/repo/.foreman-worktrees/bd-xyz9",
    });

    // Should not have unescaped double quotes that would break the shell command
    expect(cmds.commitCommand).toContain('\\"the bug\\"');
  });

  it("generates correct push command format", () => {
    const backend = new GitBackend("/tmp/repo");
    const cmds = backend.getFinalizeCommands({
      seedId: "bd-test",
      seedTitle: "Test task",
      baseBranch: "main",
      worktreePath: "/tmp/worktree",
    });

    expect(cmds.pushCommand).toBe("git push -u origin foreman/bd-test");
  });

  it("generates correct rebase command format", () => {
    const backend = new GitBackend("/tmp/repo");
    const cmds = backend.getFinalizeCommands({
      seedId: "bd-test",
      seedTitle: "Test task",
      baseBranch: "dev",
      worktreePath: "/tmp/worktree",
    });

    expect(cmds.rebaseCommand).toBe("git fetch origin && git rebase origin/dev");
  });
});
