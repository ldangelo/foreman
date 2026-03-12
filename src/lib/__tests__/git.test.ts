import { describe, it, expect, afterEach } from "vitest";
import { mkdtempSync, existsSync, writeFileSync, readFileSync, mkdirSync, rmSync, realpathSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  createWorktree,
  removeWorktree,
  listWorktrees,
  mergeWorktree,
  mergeWorktreeWithTiers,
  getRepoRoot,
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

    const { worktreePath, branchName } = await createWorktree(repo, "bead-001");

    expect(branchName).toBe("foreman/bead-001");
    expect(existsSync(worktreePath)).toBe(true);

    const branches = execFileSync("git", ["branch", "--list"], { cwd: repo })
      .toString()
      .trim();
    expect(branches).toContain("foreman/bead-001");
  });

  it("createWorktree uses correct path convention", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const { worktreePath } = await createWorktree(repo, "bead-002");

    expect(worktreePath).toBe(join(repo, ".foreman-worktrees", "bead-002"));
    expect(existsSync(worktreePath)).toBe(true);
  });

  it("removeWorktree cleans up directory", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const { worktreePath } = await createWorktree(repo, "bead-003");
    expect(existsSync(worktreePath)).toBe(true);

    await removeWorktree(repo, worktreePath);
    expect(existsSync(worktreePath)).toBe(false);
  });

  it("listWorktrees returns created worktrees", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    await createWorktree(repo, "bead-a");
    await createWorktree(repo, "bead-b");

    const worktrees = await listWorktrees(repo);
    const branches = worktrees.map((w) => w.branch);

    expect(branches).toContain("foreman/bead-a");
    expect(branches).toContain("foreman/bead-b");
    // Should also include the main worktree
    expect(worktrees.length).toBeGreaterThanOrEqual(3);
  });

  it("mergeWorktree merges clean changes", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const { worktreePath, branchName } = await createWorktree(repo, "bead-merge");

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

    const { worktreePath, branchName } = await createWorktree(repo, "bead-conflict");

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

  it("mergeWorktree with ours strategy resolves conflicts preferring main", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const { worktreePath, branchName } = await createWorktree(repo, "bead-ours");

    // Modify README.md in the worktree (agent changes)
    writeFileSync(join(worktreePath, "README.md"), "# agent change\n");
    execFileSync("git", ["add", "README.md"], { cwd: worktreePath });
    execFileSync("git", ["commit", "-m", "agent edit"], { cwd: worktreePath });

    // Modify the same file on main (main changes)
    writeFileSync(join(repo, "README.md"), "# main change\n");
    execFileSync("git", ["add", "README.md"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "main edit"], { cwd: repo });

    // Merge with 'ours' strategy — should succeed, preferring main's content
    const result = await mergeWorktree(repo, branchName, "main", "ours");

    expect(result.success).toBe(true);

    // Verify main's version was kept
    const content = readFileSync(join(repo, "README.md"), "utf8");
    expect(content).toBe("# main change\n");
  });

  it("mergeWorktree with theirs strategy resolves conflicts preferring agent", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const { worktreePath, branchName } = await createWorktree(repo, "bead-theirs");

    // Modify README.md in the worktree (agent changes)
    writeFileSync(join(worktreePath, "README.md"), "# agent change\n");
    execFileSync("git", ["add", "README.md"], { cwd: worktreePath });
    execFileSync("git", ["commit", "-m", "agent edit"], { cwd: worktreePath });

    // Modify the same file on main (main changes)
    writeFileSync(join(repo, "README.md"), "# main change\n");
    execFileSync("git", ["add", "README.md"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "main edit"], { cwd: repo });

    // Merge with 'theirs' strategy — should succeed, preferring agent's content
    const result = await mergeWorktree(repo, branchName, "main", "theirs");

    expect(result.success).toBe(true);

    // Verify agent's version was kept
    const content = readFileSync(join(repo, "README.md"), "utf8");
    expect(content).toBe("# agent change\n");
  });

  it("mergeWorktreeWithTiers succeeds at tier 1 for clean merge", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const { worktreePath, branchName } = await createWorktree(repo, "bead-tier1");

    // Add a new file — no conflict possible
    writeFileSync(join(worktreePath, "newfile.txt"), "new content\n");
    execFileSync("git", ["add", "newfile.txt"], { cwd: worktreePath });
    execFileSync("git", ["commit", "-m", "add new file"], { cwd: worktreePath });

    const result = await mergeWorktreeWithTiers(repo, branchName, "main");

    expect(result.success).toBe(true);
    expect(result.tier).toBe(1);
    expect(result.strategy).toBe("recursive");
    expect(existsSync(join(repo, "newfile.txt"))).toBe(true);
  });

  it("mergeWorktreeWithTiers escalates to tier 3 for conflicts", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const { worktreePath, branchName } = await createWorktree(repo, "bead-tier3");

    // Create conflicting README changes
    writeFileSync(join(worktreePath, "README.md"), "# agent change\n");
    execFileSync("git", ["add", "README.md"], { cwd: worktreePath });
    execFileSync("git", ["commit", "-m", "agent edit"], { cwd: worktreePath });

    writeFileSync(join(repo, "README.md"), "# main change\n");
    execFileSync("git", ["add", "README.md"], { cwd: repo });
    execFileSync("git", ["commit", "-m", "main edit"], { cwd: repo });

    const result = await mergeWorktreeWithTiers(repo, branchName, "main");

    // Tier 1 should fail (conflict), tier 2 or 3 should succeed
    expect(result.success).toBe(true);
    expect(result.tier).toBeGreaterThan(1);
    expect(result.tier).toBeLessThanOrEqual(3);
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
