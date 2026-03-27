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
