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
  detectPackageManager,
  installDependencies,
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

/** Make a temp repo that includes a package.json (no dependencies) for npm install tests. */
function makeTempRepoWithPackageJson(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-git-npm-test-")));
  execFileSync("git", ["init", "--initial-branch=main"], { cwd: dir });
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
  execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
  writeFileSync(join(dir, "README.md"), "# init\n");
  // Minimal package.json with no dependencies so `npm install` is nearly instant
  writeFileSync(join(dir, "package.json"), JSON.stringify({ name: "test-pkg", version: "1.0.0" }, null, 2) + "\n");
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

  it("removeWorktree prunes stale .git/worktrees metadata", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const { worktreePath } = await createWorktree(repo, "seed-prune");

    // Verify the metadata directory was created under .git/worktrees
    const metaDir = join(repo, ".git", "worktrees", "seed-prune");
    expect(existsSync(metaDir)).toBe(true);

    await removeWorktree(repo, worktreePath);

    // After removal + prune, neither the worktree directory nor the stale
    // .git/worktrees/<seed> metadata should exist.
    expect(existsSync(worktreePath)).toBe(false);
    expect(existsSync(metaDir)).toBe(false);
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

describe("detectPackageManager", () => {
  it("returns 'npm' when package-lock.json is present (explicit lock-file detection)", () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-pm-npm-")));
    tempDirs.push(dir);
    writeFileSync(join(dir, "package-lock.json"), "{}");
    expect(detectPackageManager(dir)).toBe("npm");
  });

  it("returns 'yarn' when yarn.lock is present", () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-pm-yarn-")));
    tempDirs.push(dir);
    writeFileSync(join(dir, "yarn.lock"), "");
    expect(detectPackageManager(dir)).toBe("yarn");
  });

  it("returns 'pnpm' when pnpm-lock.yaml is present", () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-pm-pnpm-")));
    tempDirs.push(dir);
    writeFileSync(join(dir, "pnpm-lock.yaml"), "");
    expect(detectPackageManager(dir)).toBe("pnpm");
  });

  it("prefers pnpm over yarn when both lock files exist", () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-pm-both-")));
    tempDirs.push(dir);
    writeFileSync(join(dir, "pnpm-lock.yaml"), "");
    writeFileSync(join(dir, "yarn.lock"), "");
    expect(detectPackageManager(dir)).toBe("pnpm");
  });

  it("prefers yarn over npm when yarn.lock and package-lock.json both exist", () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-pm-yarn-npm-")));
    tempDirs.push(dir);
    writeFileSync(join(dir, "yarn.lock"), "");
    writeFileSync(join(dir, "package-lock.json"), "{}");
    expect(detectPackageManager(dir)).toBe("yarn");
  });

  it("defaults to 'npm' when no lock file is present", () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-pm-none-")));
    tempDirs.push(dir);
    expect(detectPackageManager(dir)).toBe("npm");
  });
});

describe("installDependencies", () => {
  it("skips silently when no package.json exists", async () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-install-skip-")));
    tempDirs.push(dir);
    // Should not throw
    await expect(installDependencies(dir)).resolves.toBeUndefined();
  });

  it("runs npm install and creates node_modules when package.json exists", async () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-install-npm-")));
    tempDirs.push(dir);
    writeFileSync(join(dir, "package.json"), JSON.stringify({ name: "test", version: "1.0.0" }, null, 2));
    await installDependencies(dir);
    // npm install creates package-lock.json (node_modules is only created when there are deps)
    expect(existsSync(join(dir, "package-lock.json"))).toBe(true);
  }, 60_000);
});

describe("createWorktree with npm install", () => {
  it("installs node_modules in newly created worktree when package.json is present", async () => {
    const repo = makeTempRepoWithPackageJson();
    tempDirs.push(repo);

    const { worktreePath } = await createWorktree(repo, "seed-npm-001");

    expect(existsSync(worktreePath)).toBe(true);
    // npm install creates package-lock.json (node_modules is only created when there are deps)
    expect(existsSync(join(worktreePath, "package-lock.json"))).toBe(true);
  }, 60_000);

  it("does not fail when no package.json exists in the worktree", async () => {
    // makeTempRepo has no package.json — install should be skipped gracefully
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const { worktreePath } = await createWorktree(repo, "seed-no-pkg-001");

    expect(existsSync(worktreePath)).toBe(true);
    // node_modules should NOT be created since there's no package.json
    expect(existsSync(join(worktreePath, "node_modules"))).toBe(false);
  });

  it("reinstalls package-lock.json when reusing an existing worktree", async () => {
    const repo = makeTempRepoWithPackageJson();
    tempDirs.push(repo);

    // Create the worktree the first time
    const { worktreePath } = await createWorktree(repo, "seed-npm-reuse");
    // npm install creates package-lock.json (node_modules is only created when there are deps)
    expect(existsSync(join(worktreePath, "package-lock.json"))).toBe(true);

    // Remove package-lock.json to simulate stale state
    rmSync(join(worktreePath, "package-lock.json"), { force: true });
    expect(existsSync(join(worktreePath, "package-lock.json"))).toBe(false);

    // Reuse the existing worktree — should reinstall and recreate package-lock.json
    await createWorktree(repo, "seed-npm-reuse");
    expect(existsSync(join(worktreePath, "package-lock.json"))).toBe(true);
  }, 60_000);
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
