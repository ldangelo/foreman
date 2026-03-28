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

// ── GitBackend.checkoutBranch ─────────────────────────────────────────────────

describe("GitBackend.checkoutBranch", () => {
  it("successfully checks out an existing branch", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    execFileSync("git", ["checkout", "-b", "feature/test-checkout"], { cwd: repo });
    execFileSync("git", ["checkout", "main"], { cwd: repo });
    const backend = new GitBackend(repo);

    await expect(backend.checkoutBranch(repo, "feature/test-checkout")).resolves.toBeUndefined();

    const current = await backend.getCurrentBranch(repo);
    expect(current).toBe("feature/test-checkout");
  });

  it("throws when checking out a non-existent branch", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    await expect(backend.checkoutBranch(repo, "branch-does-not-exist")).rejects.toThrow();
  });

  it("handles branch names with slashes", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    execFileSync("git", ["checkout", "-b", "feature/nested/branch"], { cwd: repo });
    execFileSync("git", ["checkout", "main"], { cwd: repo });
    const backend = new GitBackend(repo);

    await expect(backend.checkoutBranch(repo, "feature/nested/branch")).resolves.toBeUndefined();

    const current = await backend.getCurrentBranch(repo);
    expect(current).toBe("feature/nested/branch");
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

  it("returns true for a branch after it is created", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    // Branch doesn't exist yet
    expect(await backend.branchExists(repo, "new-branch")).toBe(false);

    // Create the branch
    execFileSync("git", ["checkout", "-b", "new-branch"], { cwd: repo });

    // Now it should exist
    expect(await backend.branchExists(repo, "new-branch")).toBe(true);
  });
});

// ── GitBackend.branchExistsOnRemote ──────────────────────────────────────────

describe("GitBackend.branchExistsOnRemote", () => {
  it("returns true when a branch exists on origin", async () => {
    // Create a 'remote' repo (origin)
    const remoteDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-remote-")),
    );
    tempDirs.push(remoteDir);
    execFileSync("git", ["init", "--initial-branch=main"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: remoteDir });
    writeFileSync(join(remoteDir, "README.md"), "# remote\n");
    execFileSync("git", ["add", "."], { cwd: remoteDir });
    execFileSync("git", ["commit", "-m", "initial commit"], { cwd: remoteDir });

    // Clone so origin is configured
    const cloneDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-clone-")),
    );
    tempDirs.push(cloneDir);
    execFileSync("git", ["clone", remoteDir, cloneDir]);
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: cloneDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: cloneDir });

    const backend = new GitBackend(cloneDir);
    const exists = await backend.branchExistsOnRemote(cloneDir, "main");
    expect(exists).toBe(true);
  });

  it("returns false for a branch that does not exist on origin", async () => {
    // Create a 'remote' repo
    const remoteDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-remote2-")),
    );
    tempDirs.push(remoteDir);
    execFileSync("git", ["init", "--initial-branch=main"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: remoteDir });
    writeFileSync(join(remoteDir, "README.md"), "# remote\n");
    execFileSync("git", ["add", "."], { cwd: remoteDir });
    execFileSync("git", ["commit", "-m", "initial commit"], { cwd: remoteDir });

    // Clone so origin is configured
    const cloneDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-clone2-")),
    );
    tempDirs.push(cloneDir);
    execFileSync("git", ["clone", remoteDir, cloneDir]);
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: cloneDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: cloneDir });

    const backend = new GitBackend(cloneDir);
    const exists = await backend.branchExistsOnRemote(cloneDir, "branch-not-on-remote");
    expect(exists).toBe(false);
  });

  it("returns false when there is no remote configured", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    // No remote is configured — should return false, not throw
    const exists = await backend.branchExistsOnRemote(repo, "main");
    expect(exists).toBe(false);
  });

  it("returns true for a remote branch pushed after cloning", async () => {
    // Create a 'remote' repo
    const remoteDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-remote3-")),
    );
    tempDirs.push(remoteDir);
    execFileSync("git", ["init", "--initial-branch=main"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: remoteDir });
    writeFileSync(join(remoteDir, "README.md"), "# remote\n");
    execFileSync("git", ["add", "."], { cwd: remoteDir });
    execFileSync("git", ["commit", "-m", "initial commit"], { cwd: remoteDir });

    // Clone
    const cloneDir = realpathSync(
      mkdtempSync(join(tmpdir(), "foreman-git-clone3-")),
    );
    tempDirs.push(cloneDir);
    execFileSync("git", ["clone", remoteDir, cloneDir]);
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: cloneDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: cloneDir });

    // Create and push a new branch from the remote directly
    execFileSync("git", ["checkout", "-b", "feature/pushed"], { cwd: remoteDir });
    writeFileSync(join(remoteDir, "newfile.txt"), "pushed\n");
    execFileSync("git", ["add", "."], { cwd: remoteDir });
    execFileSync("git", ["commit", "-m", "add newfile"], { cwd: remoteDir });

    // Fetch in the clone to pick up the new remote branch
    execFileSync("git", ["fetch", "origin"], { cwd: cloneDir });

    const backend = new GitBackend(cloneDir);
    const exists = await backend.branchExistsOnRemote(cloneDir, "feature/pushed");
    expect(exists).toBe(true);
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
  it("removes the worktree directory", async () => {
    const repo = makeTempRepo("main");
    tempDirs.push(repo);
    const backend = new GitBackend(repo);

    const { workspacePath } = await backend.createWorkspace(repo, "seed-rm");
    await backend.removeWorkspace(repo, workspacePath);

    const { existsSync } = await import("node:fs");
    expect(existsSync(workspacePath)).toBe(false);
  });
});
