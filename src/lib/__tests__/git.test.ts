import { describe, it, expect, afterEach } from "vitest";
import { mkdtempSync, existsSync, writeFileSync, mkdirSync, rmSync, realpathSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  createWorktree,
  removeWorktree,
  listWorktrees,
  mergeWorktree,
  getRepoRoot,
  detectDefaultBranch,
} from "../git.js";

function makeTempRepo(): string {
  // realpathSync resolves macOS /var → /private/var symlink
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-git-test-")));
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
});

describe("git worktree manager", () => {
  it("createWorktree creates directory and branch", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const { worktreePath, branchName } = await createWorktree(repo, "seed-001");

    expect(branchName).toBe("foreman/seed-001");
    expect(existsSync(worktreePath)).toBe(true);

    const branches = execFileSync("git", ["branch", "--list"], { cwd: repo })
      .toString()
      .trim();
    expect(branches).toContain("foreman/seed-001");
  });

  it("createWorktree uses correct path convention", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const { worktreePath } = await createWorktree(repo, "seed-002");

    expect(worktreePath).toBe(join(repo, ".foreman-worktrees", "seed-002"));
    expect(existsSync(worktreePath)).toBe(true);
  });

  it("removeWorktree cleans up directory", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const { worktreePath } = await createWorktree(repo, "seed-003");
    expect(existsSync(worktreePath)).toBe(true);

    await removeWorktree(repo, worktreePath);
    expect(existsSync(worktreePath)).toBe(false);
  });

  it("listWorktrees returns created worktrees", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    await createWorktree(repo, "seed-a");
    await createWorktree(repo, "seed-b");

    const worktrees = await listWorktrees(repo);
    const branches = worktrees.map((w) => w.branch);

    expect(branches).toContain("foreman/seed-a");
    expect(branches).toContain("foreman/seed-b");
    // Should also include the main worktree
    expect(worktrees.length).toBeGreaterThanOrEqual(3);
  });

  it("mergeWorktree merges clean changes", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const { worktreePath, branchName } = await createWorktree(repo, "seed-merge");

    // Add a new file in the worktree and commit
    writeFileSync(join(worktreePath, "feature.txt"), "new feature\n");
    execFileSync("git", ["add", "feature.txt"], { cwd: worktreePath });
    execFileSync("git", ["commit", "-m", "add feature"], { cwd: worktreePath });

    const result = await mergeWorktree(repo, branchName);

    expect(result.success).toBe(true);
    expect(existsSync(join(repo, "feature.txt"))).toBe(true);
  });

  it("mergeWorktree detects conflicts", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const { worktreePath, branchName } = await createWorktree(repo, "seed-conflict");

    // Modify README.md in the worktree
    writeFileSync(join(worktreePath, "README.md"), "# worktree change\n");
    execFileSync("git", ["add", "README.md"], { cwd: worktreePath });
    execFileSync("git", ["commit", "-m", "worktree edit"], { cwd: worktreePath });

    // Modify the same file on main
    writeFileSync(join(repo, "README.md"), "# main change\n");
    execFileSync("git", ["add", "README.md"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "main edit"], { cwd: repo });

    const result = await mergeWorktree(repo, branchName);

    expect(result.success).toBe(false);
    expect(result.conflicts).toBeDefined();
    expect(result.conflicts!.length).toBeGreaterThan(0);
    expect(result.conflicts).toContain("README.md");

    // Clean up the failed merge state
    execFileSync("git", ["merge", "--abort"], { cwd: repo });
  });

  it("getRepoRoot finds root from subdirectory", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const subdir = join(repo, "src", "nested");
    mkdirSync(subdir, { recursive: true });

    const root = await getRepoRoot(subdir);
    expect(root).toBe(repo);
  });
});

describe("detectDefaultBranch", () => {
  it("returns 'main' when the local branch is named 'main'", async () => {
    // makeTempRepo uses --initial-branch=main, so 'main' exists locally
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const branch = await detectDefaultBranch(repo);
    expect(branch).toBe("main");
  });

  it("returns 'master' when only 'master' exists (no 'main', no remote)", async () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-git-master-")));
    tempDirs.push(dir);
    execFileSync("git", ["init", "--initial-branch=master"], { cwd: dir });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
    writeFileSync(join(dir, "README.md"), "# init\n");
    execFileSync("git", ["add", "."], { cwd: dir });
    execFileSync("git", ["commit", "-m", "initial commit"], { cwd: dir });

    const branch = await detectDefaultBranch(dir);
    expect(branch).toBe("master");
  });

  it("returns custom branch name when origin/HEAD points to it", async () => {
    // Create a non-bare 'remote' repo with a commit on 'develop' branch
    const remoteDir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-git-remote-")));
    tempDirs.push(remoteDir);
    execFileSync("git", ["init", "--initial-branch=develop"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: remoteDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: remoteDir });
    writeFileSync(join(remoteDir, "README.md"), "# remote\n");
    execFileSync("git", ["add", "."], { cwd: remoteDir });
    execFileSync("git", ["commit", "-m", "initial commit"], { cwd: remoteDir });

    // Clone it so origin/HEAD is set (git clones a non-bare repo and sets origin/HEAD)
    const cloneDir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-git-clone-")));
    tempDirs.push(cloneDir);
    execFileSync("git", ["clone", remoteDir, cloneDir]);
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: cloneDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: cloneDir });

    // Confirm symbolic-ref is set by the clone
    const symRef = execFileSync(
      "git", ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"],
      { cwd: cloneDir },
    ).toString().trim();
    // symRef should be "origin/develop"
    expect(symRef).toBe("origin/develop");

    const branch = await detectDefaultBranch(cloneDir);
    expect(branch).toBe("develop");
  });

  it("falls back to current branch when no main/master and no remote", async () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-git-custom-")));
    tempDirs.push(dir);
    execFileSync("git", ["init", "--initial-branch=trunk"], { cwd: dir });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
    writeFileSync(join(dir, "README.md"), "# init\n");
    execFileSync("git", ["add", "."], { cwd: dir });
    execFileSync("git", ["commit", "-m", "initial commit"], { cwd: dir });

    const branch = await detectDefaultBranch(dir);
    expect(branch).toBe("trunk");
  });
});
