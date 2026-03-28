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

// ── GitBackend.getFinalizeCommands ────────────────────────────────────────────

describe("GitBackend.getFinalizeCommands", () => {
  it("returns all 6 required fields", () => {
    const backend = new GitBackend("/tmp");
    const cmds = backend.getFinalizeCommands({
      seedId: "bd-test",
      seedTitle: "My Task",
      baseBranch: "dev",
      worktreePath: "/tmp/worktrees/bd-test",
    });
    expect(typeof cmds.stageCommand).toBe("string");
    expect(typeof cmds.commitCommand).toBe("string");
    expect(typeof cmds.pushCommand).toBe("string");
    expect(typeof cmds.rebaseCommand).toBe("string");
    expect(typeof cmds.branchVerifyCommand).toBe("string");
    expect(typeof cmds.cleanCommand).toBe("string");
  });

  it("stageCommand is 'git add -A'", () => {
    const backend = new GitBackend("/tmp");
    const cmds = backend.getFinalizeCommands({
      seedId: "bd-abc",
      seedTitle: "Title",
      baseBranch: "main",
      worktreePath: "/tmp",
    });
    expect(cmds.stageCommand).toBe("git add -A");
  });

  it("commitCommand includes seedId and seedTitle", () => {
    const backend = new GitBackend("/tmp");
    const cmds = backend.getFinalizeCommands({
      seedId: "bd-abc",
      seedTitle: "My Feature",
      baseBranch: "main",
      worktreePath: "/tmp",
    });
    expect(cmds.commitCommand).toContain("bd-abc");
    expect(cmds.commitCommand).toContain("My Feature");
  });

  it("pushCommand references the correct branch", () => {
    const backend = new GitBackend("/tmp");
    const cmds = backend.getFinalizeCommands({
      seedId: "bd-xyz",
      seedTitle: "Feat",
      baseBranch: "dev",
      worktreePath: "/tmp",
    });
    expect(cmds.pushCommand).toContain("foreman/bd-xyz");
    expect(cmds.pushCommand).toContain("origin");
  });

  it("rebaseCommand references the base branch", () => {
    const backend = new GitBackend("/tmp");
    const cmds = backend.getFinalizeCommands({
      seedId: "bd-xyz",
      seedTitle: "Feat",
      baseBranch: "develop",
      worktreePath: "/tmp",
    });
    expect(cmds.rebaseCommand).toContain("develop");
    expect(cmds.rebaseCommand).toContain("rebase");
  });
});

// ── GitBackend.branchExists ────────────────────────────────────────────────────

describe("GitBackend.branchExists", () => {
  it("returns true for an existing branch", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const exists = await backend.branchExists(repo, "main");
    expect(exists).toBe(true);
  });

  it("returns false for a non-existent branch", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const exists = await backend.branchExists(repo, "nonexistent-branch");
    expect(exists).toBe(false);
  });
});

// ── GitBackend.getHeadId ──────────────────────────────────────────────────────

describe("GitBackend.getHeadId", () => {
  it("returns a 40-character commit hash", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const headId = await backend.getHeadId(repo);
    expect(headId).toHaveLength(40);
    expect(headId).toMatch(/^[0-9a-f]{40}$/);
  });
});

// ── GitBackend.status ─────────────────────────────────────────────────────────

describe("GitBackend.status", () => {
  it("returns empty string for a clean repo", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const statusOut = await backend.status(repo);
    expect(statusOut).toBe("");
  });

  it("returns non-empty string when files are modified", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    writeFileSync(join(repo, "newfile.txt"), "test\n");
    const backend = new GitBackend(repo);

    const statusOut = await backend.status(repo);
    expect(statusOut).toContain("newfile.txt");
  });
});

// ── GitBackend.stageAll ───────────────────────────────────────────────────────

describe("GitBackend.stageAll", () => {
  it("stages all files without error", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    writeFileSync(join(repo, "staged.txt"), "content\n");
    const backend = new GitBackend(repo);

    await expect(backend.stageAll(repo)).resolves.toBeUndefined();

    // Verify it staged the file
    const statusOut = await backend.status(repo);
    // After staging, porcelain shows "A  staged.txt" (not "?? staged.txt")
    expect(statusOut).not.toContain("??");
  });
});

// ── GitBackend.getConflictingFiles ────────────────────────────────────────────

describe("GitBackend.getConflictingFiles", () => {
  it("returns empty array for a repo with no conflicts", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const conflicts = await backend.getConflictingFiles(repo);
    expect(conflicts).toEqual([]);
  });
});

// ── GitBackend.listWorkspaces ─────────────────────────────────────────────────

describe("GitBackend.listWorkspaces", () => {
  it("returns the main worktree", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const workspaces = await backend.listWorkspaces(repo);
    expect(workspaces.length).toBeGreaterThan(0);
    // Main worktree path should match
    expect(workspaces[0].path).toBe(repo);
  });

  it("includes linked worktrees", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);

    const worktreePath = join(repo, "wt-linked");
    execFileSync("git", ["worktree", "add", "-b", "feature/wt-list", worktreePath], { cwd: repo });

    const backend = new GitBackend(repo);
    const workspaces = await backend.listWorkspaces(repo);
    expect(workspaces.length).toBe(2);
    const paths = workspaces.map((w) => w.path);
    expect(paths).toContain(worktreePath);
  });
});

// ── GitBackend.createWorkspace / removeWorkspace ──────────────────────────────

describe("GitBackend.createWorkspace", () => {
  it("creates a worktree at the expected path", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const result = await backend.createWorkspace(repo, "seed-abc");

    expect(result.branchName).toBe("foreman/seed-abc");
    expect(result.workspacePath).toBe(join(repo, ".foreman-worktrees", "seed-abc"));
    // The directory should exist
    const { existsSync } = await import("node:fs");
    expect(existsSync(result.workspacePath)).toBe(true);

    // Cleanup
    await backend.removeWorkspace(repo, result.workspacePath);
  });

  it("reuses an existing worktree path on second call", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    await backend.createWorkspace(repo, "seed-reuse");
    // Second call should not throw
    await expect(backend.createWorkspace(repo, "seed-reuse")).resolves.toMatchObject({
      branchName: "foreman/seed-reuse",
    });

    await backend.removeWorkspace(repo, join(repo, ".foreman-worktrees", "seed-reuse"));
  });
});

describe("GitBackend.removeWorkspace", () => {
  // AC-T-006-3: directory no longer exists AND listWorkspaces() does not include it
  it("removes the worktree directory", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const { workspacePath } = await backend.createWorkspace(repo, "seed-rm");
    await backend.removeWorkspace(repo, workspacePath);

    const { existsSync } = await import("node:fs");
    expect(existsSync(workspacePath)).toBe(false);

    // AC-T-006-3 second clause: listWorkspaces() must not include the removed worktree
    const workspacesAfter = await backend.listWorkspaces(repo);
    const paths = workspacesAfter.map((w) => w.path);
    expect(paths).not.toContain(workspacePath);
  });
});

// ── GitBackend.checkoutBranch ─────────────────────────────────────────────────

describe("GitBackend.checkoutBranch", () => {
  it("checks out a branch and updates the current branch", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    // Create a feature branch
    execFileSync("git", ["checkout", "-b", "feature/checkout-test"], { cwd: repo });

    // Now checkout back to main via backend
    await backend.checkoutBranch(repo, "main");

    const current = await backend.getCurrentBranch(repo);
    expect(current).toBe("main");
  });

  it("throws when checking out a non-existent branch", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    await expect(
      backend.checkoutBranch(repo, "branch-does-not-exist"),
    ).rejects.toThrow();
  });
});

// ── GitBackend.branchExistsOnRemote ──────────────────────────────────────────

describe("GitBackend.branchExistsOnRemote", () => {
  it("returns true for a branch that exists on the remote", async () => {
    // Create a 'remote' repo
    const remoteDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-backend-remote-bxr-")),
    );
    tempDirs.push(remoteDir);
    execFileSync("git", ["init", "--initial-branch=main"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: remoteDir });
    writeFileSync(join(remoteDir, "README.md"), "# remote\n");
    execFileSync("git", ["add", "."], { cwd: remoteDir });
    execFileSync("git", ["commit", "-m", "initial commit"], { cwd: remoteDir });

    // Create and push a feature branch in the remote
    execFileSync("git", ["checkout", "-b", "feature/remote-branch"], { cwd: remoteDir });
    writeFileSync(join(remoteDir, "feature.txt"), "feature\n");
    execFileSync("git", ["add", "."], { cwd: remoteDir });
    execFileSync("git", ["commit", "-m", "feature commit"], { cwd: remoteDir });
    execFileSync("git", ["checkout", "main"], { cwd: remoteDir });

    // Clone the remote
    const cloneDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-backend-clone-bxr-")),
    );
    tempDirs.push(cloneDir);
    execFileSync("git", ["clone", remoteDir, cloneDir]);
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: cloneDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: cloneDir });

    const backend = new GitBackend(cloneDir);
    const exists = await backend.branchExistsOnRemote(cloneDir, "feature/remote-branch");
    expect(exists).toBe(true);
  });

  it("returns false for a branch that only exists locally", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    execFileSync("git", ["checkout", "-b", "local-only-branch"], { cwd: repo });
    execFileSync("git", ["checkout", "main"], { cwd: repo });
    const backend = new GitBackend(repo);

    // No remote is configured, so local-only-branch cannot exist on origin
    const exists = await backend.branchExistsOnRemote(repo, "local-only-branch");
    expect(exists).toBe(false);
  });

  it("returns false when no remote is configured", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const exists = await backend.branchExistsOnRemote(repo, "main");
    expect(exists).toBe(false);
  });
});

// ── GitBackend.deleteBranch ───────────────────────────────────────────────────

describe("GitBackend.deleteBranch", () => {
  it("deletes a merged branch and returns wasFullyMerged=true (AC-T-005-3)", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    // Create feature branch with a commit
    execFileSync("git", ["checkout", "-b", "feature/merged"], { cwd: repo });
    writeFileSync(join(repo, "feature.txt"), "feature content\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "feature commit"], { cwd: repo });

    // Merge feature into main
    execFileSync("git", ["checkout", "main"], { cwd: repo });
    execFileSync("git", ["merge", "feature/merged", "--no-ff", "-m", "merge feature"], { cwd: repo });

    const result = await backend.deleteBranch(repo, "feature/merged", { targetBranch: "main" });

    expect(result.deleted).toBe(true);
    expect(result.wasFullyMerged).toBe(true);
    // Verify the branch is gone
    const exists = await backend.branchExists(repo, "feature/merged");
    expect(exists).toBe(false);
  });

  it("skips deletion of an unmerged branch when force=false", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    // Create a feature branch with a commit (not merged)
    execFileSync("git", ["checkout", "-b", "feature/unmerged"], { cwd: repo });
    writeFileSync(join(repo, "unmerged.txt"), "unmerged content\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "unmerged commit"], { cwd: repo });
    execFileSync("git", ["checkout", "main"], { cwd: repo });

    const result = await backend.deleteBranch(repo, "feature/unmerged", {
      targetBranch: "main",
      force: false,
    });

    expect(result.deleted).toBe(false);
    expect(result.wasFullyMerged).toBe(false);
    // Branch should still exist
    const exists = await backend.branchExists(repo, "feature/unmerged");
    expect(exists).toBe(true);
  });

  it("force-deletes an unmerged branch when force=true", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    // Create a feature branch with a commit (not merged)
    execFileSync("git", ["checkout", "-b", "feature/force-delete"], { cwd: repo });
    writeFileSync(join(repo, "force.txt"), "force content\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "force commit"], { cwd: repo });
    execFileSync("git", ["checkout", "main"], { cwd: repo });

    const result = await backend.deleteBranch(repo, "feature/force-delete", {
      targetBranch: "main",
      force: true,
    });

    expect(result.deleted).toBe(true);
    expect(result.wasFullyMerged).toBe(false);
    // Branch should be gone
    const exists = await backend.branchExists(repo, "feature/force-delete");
    expect(exists).toBe(false);
  });

  it("returns { deleted: false, wasFullyMerged: true } when branch does not exist", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const result = await backend.deleteBranch(repo, "branch-that-never-existed");

    expect(result.deleted).toBe(false);
    expect(result.wasFullyMerged).toBe(true);
  });
});

// ── Helpers for remote-based tests ───────────────────────────────────────────

/**
 * Create a bare "remote" repo and a clone of it, returning both paths.
 * The clone is pre-configured with user.email + user.name.
 */
function makeRemoteAndClone(branch = "main"): { remote: string; clone: string } {
  const remote = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-git-backend-remote-")),
  );
  execFileSync("git", ["init", "--bare", `--initial-branch=${branch}`], { cwd: remote });

  // Push an initial commit from a temp repo so the bare repo has content
  const seed = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-git-backend-seed-")),
  );
  execFileSync("git", ["init", `--initial-branch=${branch}`], { cwd: seed });
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: seed });
  execFileSync("git", ["config", "user.name", "Test"], { cwd: seed });
  writeFileSync(join(seed, "README.md"), "# init\n");
  execFileSync("git", ["add", "."], { cwd: seed });
  execFileSync("git", ["commit", "-m", "initial commit"], { cwd: seed });
  execFileSync("git", ["remote", "add", "origin", remote], { cwd: seed });
  execFileSync("git", ["push", "-u", "origin", branch], { cwd: seed });
  rmSync(seed, { recursive: true, force: true });

  const clone = realpathSync(
    mkdtempSync(join(tmpdir(), "foreman-git-backend-clone-")),
  );
  execFileSync("git", ["clone", remote, clone]);
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: clone });
  execFileSync("git", ["config", "user.name", "Test"], { cwd: clone });

  return { remote, clone };
}

// ── GitBackend.commit ─────────────────────────────────────────────────────────

describe("GitBackend.commit", () => {
  it("creates a commit from staged changes", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    writeFileSync(join(repo, "newfile.txt"), "hello\n");
    await backend.stageAll(repo);
    await backend.commit(repo, "test: add newfile");

    // Verify the commit message appears in git log
    const log = execFileSync("git", ["log", "--oneline", "-1"], { cwd: repo })
      .toString()
      .trim();
    expect(log).toContain("test: add newfile");
  });

  it("creates a commit with the correct HEAD hash afterwards", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const headBefore = await backend.getHeadId(repo);

    writeFileSync(join(repo, "another.txt"), "content\n");
    await backend.stageAll(repo);
    await backend.commit(repo, "test: another commit");

    const headAfter = await backend.getHeadId(repo);
    expect(headAfter).not.toBe(headBefore);
    expect(headAfter).toMatch(/^[0-9a-f]{40}$/);
  });

  it("throws when there is nothing to commit", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    // No staged changes — commit should fail
    await expect(backend.commit(repo, "empty commit")).rejects.toThrow();
  });

  it("commits with a multi-word message containing special characters", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    writeFileSync(join(repo, "special.txt"), "data\n");
    await backend.stageAll(repo);
    const message = 'fix: handle "edge case" in parser (AC-004-4)';
    await backend.commit(repo, message);

    const log = execFileSync("git", ["log", "--format=%s", "-1"], { cwd: repo })
      .toString()
      .trim();
    expect(log).toBe(message);
  });
});

// ── GitBackend.push ───────────────────────────────────────────────────────────

describe("GitBackend.push", () => {
  it("pushes a branch to origin (AC-004-5)", async () => {
    const { remote, clone } = makeRemoteAndClone("main");
    tempDirs.push(remote, clone);
    const backend = new GitBackend(clone);

    // Create a feature branch and commit
    execFileSync("git", ["checkout", "-b", "feature/push-test"], { cwd: clone });
    writeFileSync(join(clone, "push.txt"), "pushed content\n");
    await backend.stageAll(clone);
    await backend.commit(clone, "test: push content");

    // Push via backend
    await expect(
      backend.push(clone, "feature/push-test"),
    ).resolves.toBeUndefined();

    // Verify the branch exists on remote
    const branches = execFileSync("git", ["branch", "-r"], { cwd: clone })
      .toString();
    expect(branches).toContain("feature/push-test");
  });

  it("throws on non-fast-forward push without force", async () => {
    const { remote, clone } = makeRemoteAndClone("main");
    tempDirs.push(remote, clone);
    const backend = new GitBackend(clone);

    // Push a feature branch
    execFileSync("git", ["checkout", "-b", "feature/nff"], { cwd: clone });
    writeFileSync(join(clone, "nff.txt"), "content\n");
    execFileSync("git", ["add", "."], { cwd: clone });
    execFileSync("git", ["commit", "-m", "first"], { cwd: clone });
    execFileSync("git", ["push", "-u", "origin", "feature/nff"], { cwd: clone });

    // Create a second clone and push a different commit to the same branch
    const clone2 = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-backend-clone2-")),
    );
    tempDirs.push(clone2);
    execFileSync("git", ["clone", remote, clone2]);
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: clone2 });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: clone2 });
    execFileSync("git", ["checkout", "feature/nff"], { cwd: clone2 });
    writeFileSync(join(clone2, "nff2.txt"), "content2\n");
    execFileSync("git", ["add", "."], { cwd: clone2 });
    execFileSync("git", ["commit", "-m", "second"], { cwd: clone2 });
    execFileSync("git", ["push", "origin", "feature/nff"], { cwd: clone2 });

    // Now first clone tries to push — should fail (non-fast-forward)
    writeFileSync(join(clone, "nff3.txt"), "content3\n");
    await backend.stageAll(clone);
    await backend.commit(clone, "third");

    await expect(backend.push(clone, "feature/nff")).rejects.toThrow();
  });

  it("force-pushes a branch when force=true", async () => {
    const { remote, clone } = makeRemoteAndClone("main");
    tempDirs.push(remote, clone);
    const backend = new GitBackend(clone);

    // Push feature branch initially
    execFileSync("git", ["checkout", "-b", "feature/force-push"], { cwd: clone });
    writeFileSync(join(clone, "fp1.txt"), "v1\n");
    execFileSync("git", ["add", "."], { cwd: clone });
    execFileSync("git", ["commit", "-m", "v1"], { cwd: clone });
    execFileSync("git", ["push", "-u", "origin", "feature/force-push"], { cwd: clone });

    // Amend the commit (rewrites history) then force push
    writeFileSync(join(clone, "fp1.txt"), "v1-amended\n");
    execFileSync("git", ["add", "."], { cwd: clone });
    execFileSync("git", ["commit", "--amend", "--no-edit"], { cwd: clone });

    await expect(
      backend.push(clone, "feature/force-push", { force: true }),
    ).resolves.toBeUndefined();
  });
});

// ── GitBackend.fetch ──────────────────────────────────────────────────────────

describe("GitBackend.fetch", () => {
  it("fetches from origin without error (AC-007-1)", async () => {
    const { remote, clone } = makeRemoteAndClone("main");
    tempDirs.push(remote, clone);
    const backend = new GitBackend(clone);

    await expect(backend.fetch(clone)).resolves.toBeUndefined();
  });

  it("updates tracking refs after fetch", async () => {
    const { remote, clone } = makeRemoteAndClone("main");
    tempDirs.push(remote, clone);
    const backend = new GitBackend(clone);

    // Create a new branch in a second clone and push to remote
    const clone2 = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-backend-fetch-clone2-")),
    );
    tempDirs.push(clone2);
    execFileSync("git", ["clone", remote, clone2]);
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: clone2 });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: clone2 });
    execFileSync("git", ["checkout", "-b", "feature/new-in-remote"], { cwd: clone2 });
    writeFileSync(join(clone2, "new.txt"), "new\n");
    execFileSync("git", ["add", "."], { cwd: clone2 });
    execFileSync("git", ["commit", "-m", "add feature"], { cwd: clone2 });
    execFileSync("git", ["push", "-u", "origin", "feature/new-in-remote"], { cwd: clone2 });

    // Fetch in first clone — should now see the new branch
    await backend.fetch(clone);

    const remoteBranches = execFileSync("git", ["branch", "-r"], { cwd: clone })
      .toString();
    expect(remoteBranches).toContain("feature/new-in-remote");
  });

  it("throws when there is no remote configured", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    await expect(backend.fetch(repo)).rejects.toThrow();
  });
});

// ── GitBackend.pull ───────────────────────────────────────────────────────────

describe("GitBackend.pull", () => {
  it("fast-forward pulls changes from origin", async () => {
    const { remote, clone } = makeRemoteAndClone("main");
    tempDirs.push(remote, clone);
    const backend = new GitBackend(clone);

    // Push a new commit to remote via a second clone
    const clone2 = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-backend-pull-clone2-")),
    );
    tempDirs.push(clone2);
    execFileSync("git", ["clone", remote, clone2]);
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: clone2 });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: clone2 });
    writeFileSync(join(clone2, "remote-change.txt"), "remote\n");
    execFileSync("git", ["add", "."], { cwd: clone2 });
    execFileSync("git", ["commit", "-m", "remote change"], { cwd: clone2 });
    execFileSync("git", ["push", "origin", "main"], { cwd: clone2 });

    const headBefore = await backend.getHeadId(clone);

    // Pull in first clone
    await expect(backend.pull(clone, "main")).resolves.toBeUndefined();

    const headAfter = await backend.getHeadId(clone);
    expect(headAfter).not.toBe(headBefore);
  });

  it("throws on non-fast-forward situation (diverged history)", async () => {
    const { remote, clone } = makeRemoteAndClone("main");
    tempDirs.push(remote, clone);
    const backend = new GitBackend(clone);

    // Add a commit to the remote via clone2
    const clone2 = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-backend-pull-nff-")),
    );
    tempDirs.push(clone2);
    execFileSync("git", ["clone", remote, clone2]);
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: clone2 });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: clone2 });
    writeFileSync(join(clone2, "remote2.txt"), "remote2\n");
    execFileSync("git", ["add", "."], { cwd: clone2 });
    execFileSync("git", ["commit", "-m", "remote2"], { cwd: clone2 });
    execFileSync("git", ["push", "origin", "main"], { cwd: clone2 });

    // Add a diverging commit in clone1
    writeFileSync(join(clone, "local.txt"), "local\n");
    execFileSync("git", ["add", "."], { cwd: clone });
    execFileSync("git", ["commit", "-m", "local diverge"], { cwd: clone });

    // Pull --ff-only should fail
    await expect(backend.pull(clone, "main")).rejects.toThrow();
  });
});

// ── GitBackend.rebase ─────────────────────────────────────────────────────────

describe("GitBackend.rebase", () => {
  it("returns { success: true, hasConflicts: false } for a clean rebase", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    // Create feature branch
    execFileSync("git", ["checkout", "-b", "feature/clean-rebase"], { cwd: repo });
    writeFileSync(join(repo, "feature.txt"), "feature content\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "feature commit"], { cwd: repo });

    // Add a commit to main that doesn't conflict
    execFileSync("git", ["checkout", "main"], { cwd: repo });
    writeFileSync(join(repo, "main-only.txt"), "main content\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "main commit"], { cwd: repo });

    // Switch back to feature and rebase onto main
    execFileSync("git", ["checkout", "feature/clean-rebase"], { cwd: repo });
    const result = await backend.rebase(repo, "main");

    expect(result.success).toBe(true);
    expect(result.hasConflicts).toBe(false);
  });

  it("returns { success: false, hasConflicts: true } with conflictingFiles populated", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    // Both branches modify the same file — this will conflict on rebase
    writeFileSync(join(repo, "conflict.txt"), "original\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add conflict.txt to main"], { cwd: repo });

    execFileSync("git", ["checkout", "-b", "feature/conflict-rebase"], { cwd: repo });
    writeFileSync(join(repo, "conflict.txt"), "feature version\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "feature modifies conflict.txt"], { cwd: repo });

    // Modify the same file on main
    execFileSync("git", ["checkout", "main"], { cwd: repo });
    writeFileSync(join(repo, "conflict.txt"), "main version\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "main modifies conflict.txt"], { cwd: repo });

    // Switch back to feature and rebase
    execFileSync("git", ["checkout", "feature/conflict-rebase"], { cwd: repo });
    const result = await backend.rebase(repo, "main");

    expect(result.success).toBe(false);
    expect(result.hasConflicts).toBe(true);
    expect(result.conflictingFiles).toBeDefined();
    expect(result.conflictingFiles!.length).toBeGreaterThan(0);
    expect(result.conflictingFiles).toContain("conflict.txt");

    // Clean up rebase state
    await backend.abortRebase(repo);
  });

  it("applies commits in the correct order after clean rebase", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    execFileSync("git", ["checkout", "-b", "feature/order"], { cwd: repo });
    writeFileSync(join(repo, "f1.txt"), "f1\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "feat: f1"], { cwd: repo });

    execFileSync("git", ["checkout", "main"], { cwd: repo });
    writeFileSync(join(repo, "m1.txt"), "m1\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "main: m1"], { cwd: repo });

    execFileSync("git", ["checkout", "feature/order"], { cwd: repo });
    const result = await backend.rebase(repo, "main");

    expect(result.success).toBe(true);

    // After rebase, the feature commit should be on top of the main commit
    const log = execFileSync("git", ["log", "--oneline", "-2"], { cwd: repo })
      .toString()
      .trim();
    expect(log).toContain("feat: f1");
    expect(log).toContain("main: m1");
  });
});

// ── GitBackend.abortRebase ────────────────────────────────────────────────────

describe("GitBackend.abortRebase", () => {
  it("aborts an in-progress rebase and restores the previous state", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    // Set up conflict scenario
    writeFileSync(join(repo, "abort-conflict.txt"), "original\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "add abort-conflict.txt"], { cwd: repo });

    execFileSync("git", ["checkout", "-b", "feature/abort-test"], { cwd: repo });
    writeFileSync(join(repo, "abort-conflict.txt"), "feature version\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "feature change"], { cwd: repo });

    execFileSync("git", ["checkout", "main"], { cwd: repo });
    writeFileSync(join(repo, "abort-conflict.txt"), "main version\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "main change"], { cwd: repo });

    execFileSync("git", ["checkout", "feature/abort-test"], { cwd: repo });

    // Trigger conflict rebase
    const result = await backend.rebase(repo, "main");
    expect(result.hasConflicts).toBe(true);

    // Abort the rebase
    await expect(backend.abortRebase(repo)).resolves.toBeUndefined();

    // After abort, we should be back on feature/abort-test with no rebase in progress
    const branch = await backend.getCurrentBranch(repo);
    expect(branch).toBe("feature/abort-test");
  });

  it("throws when there is no rebase in progress", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    await expect(backend.abortRebase(repo)).rejects.toThrow();
  });
});

// ── Integration: stageAll + commit + push workflow ────────────────────────────

describe("GitBackend integration: stageAll → commit → push", () => {
  it("stages, commits, and pushes a complete workflow (AC-004-4, AC-004-5)", async () => {
    const { remote, clone } = makeRemoteAndClone("main");
    tempDirs.push(remote, clone);
    const backend = new GitBackend(clone);

    // Create a feature branch
    execFileSync("git", ["checkout", "-b", "feature/integration-test"], { cwd: clone });

    // Create files and use stageAll → commit → push
    writeFileSync(join(clone, "integration.ts"), "export const x = 1;\n");
    writeFileSync(join(clone, "integration.test.ts"), "import { x } from './integration.js';\n");

    const headBefore = await backend.getHeadId(clone);

    await backend.stageAll(clone);
    await backend.commit(clone, "feat: add integration files");
    await backend.push(clone, "feature/integration-test");

    const headAfter = await backend.getHeadId(clone);
    expect(headAfter).not.toBe(headBefore);

    // Verify remote has the branch
    const remoteBranches = execFileSync("git", ["branch", "-r"], { cwd: clone })
      .toString();
    expect(remoteBranches).toContain("feature/integration-test");
  });

  it("stageAll + commit + rebase workflow succeeds", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    // Feature branch with a commit
    execFileSync("git", ["checkout", "-b", "feature/workflow-rebase"], { cwd: repo });
    writeFileSync(join(repo, "workflow.txt"), "feature work\n");
    await backend.stageAll(repo);
    await backend.commit(repo, "feat: workflow feature");

    // Main advances
    execFileSync("git", ["checkout", "main"], { cwd: repo });
    writeFileSync(join(repo, "main-advance.txt"), "main advance\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "main: advance"], { cwd: repo });

    // Rebase feature onto updated main
    execFileSync("git", ["checkout", "feature/workflow-rebase"], { cwd: repo });
    const result = await backend.rebase(repo, "main");

    expect(result.success).toBe(true);
    expect(result.hasConflicts).toBe(false);

    // HEAD should be the rebased commit
    const headId = await backend.getHeadId(repo);
    expect(headId).toMatch(/^[0-9a-f]{40}$/);
  });
});
