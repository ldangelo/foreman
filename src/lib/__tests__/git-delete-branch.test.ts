import { describe, it, expect, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, rmSync, realpathSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { deleteBranch } from "../git.js";
import type { DeleteBranchResult } from "../git.js";

function makeTempRepo(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-git-delete-")));
  execFileSync("git", ["init", "--initial-branch=main"], { cwd: dir });
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
  execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
  writeFileSync(join(dir, "README.md"), "# init\n");
  execFileSync("git", ["add", "."], { cwd: dir });
  execFileSync("git", ["commit", "-m", "initial commit"], { cwd: dir });
  return dir;
}

/** Create a branch with a commit, then merge it into main so it is fully merged. */
function createMergedBranch(repo: string, branchName: string): void {
  const safeFile = branchName.replace(/\//g, "-");
  execFileSync("git", ["checkout", "-b", branchName], { cwd: repo });
  writeFileSync(join(repo, `${safeFile}.txt`), "merged content\n");
  execFileSync("git", ["add", "."], { cwd: repo });
  execFileSync("git", ["commit", "-m", `add ${branchName}`], { cwd: repo });
  execFileSync("git", ["checkout", "main"], { cwd: repo });
  execFileSync("git", ["merge", branchName, "--no-ff", "-m", `merge ${branchName}`], { cwd: repo });
}

/** Create a branch with a commit that is NOT merged into main. */
function createUnmergedBranch(repo: string, branchName: string): void {
  const safeFile = branchName.replace(/\//g, "-");
  execFileSync("git", ["checkout", "-b", branchName], { cwd: repo });
  writeFileSync(join(repo, `${safeFile}.txt`), "unmerged content\n");
  execFileSync("git", ["add", "."], { cwd: repo });
  execFileSync("git", ["commit", "-m", `add ${branchName}`], { cwd: repo });
  execFileSync("git", ["checkout", "main"], { cwd: repo });
}

const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
  tempDirs.length = 0;
});

describe("deleteBranch (safe deletion)", () => {
  it("deletes a fully merged branch safely and returns deleted:true, wasFullyMerged:true", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    createMergedBranch(repo, "feature/merged");

    const result: DeleteBranchResult = await deleteBranch(repo, "feature/merged");

    expect(result).toEqual({ deleted: true, wasFullyMerged: true });

    // Verify the branch is actually gone
    const branches = execFileSync("git", ["branch", "--list"], { cwd: repo }).toString();
    expect(branches).not.toContain("feature/merged");
  });

  it("skips deletion of unmerged branch without force, returns deleted:false, wasFullyMerged:false", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    createUnmergedBranch(repo, "feature/unmerged");

    const result: DeleteBranchResult = await deleteBranch(repo, "feature/unmerged");

    expect(result).toEqual({ deleted: false, wasFullyMerged: false });

    // Verify the branch still exists
    const branches = execFileSync("git", ["branch", "--list"], { cwd: repo }).toString();
    expect(branches).toContain("feature/unmerged");
  });

  it("force-deletes an unmerged branch, returns deleted:true, wasFullyMerged:false", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    createUnmergedBranch(repo, "feature/force-delete");

    const result: DeleteBranchResult = await deleteBranch(repo, "feature/force-delete", { force: true });

    expect(result).toEqual({ deleted: true, wasFullyMerged: false });

    // Verify the branch is gone
    const branches = execFileSync("git", ["branch", "--list"], { cwd: repo }).toString();
    expect(branches).not.toContain("feature/force-delete");
  });

  it("returns gracefully when branch does not exist: deleted:false, wasFullyMerged:true", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const result: DeleteBranchResult = await deleteBranch(repo, "feature/nonexistent");

    expect(result).toEqual({ deleted: false, wasFullyMerged: true });
  });

  it("uses custom targetBranch for merge-base check", async () => {
    const repo = makeTempRepo();
    tempDirs.push(repo);

    // Create a "develop" branch from main
    execFileSync("git", ["checkout", "-b", "develop"], { cwd: repo });
    writeFileSync(join(repo, "develop.txt"), "develop base\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "develop base"], { cwd: repo });

    // Create a feature branch off develop and merge it back into develop
    execFileSync("git", ["checkout", "-b", "feature/custom-target"], { cwd: repo });
    writeFileSync(join(repo, "feature-custom-target.txt"), "custom content\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-m", "custom feature"], { cwd: repo });
    execFileSync("git", ["checkout", "develop"], { cwd: repo });
    execFileSync("git", ["merge", "feature/custom-target", "--no-ff", "-m", "merge custom"], { cwd: repo });

    // Switch back to main so we're not on develop
    execFileSync("git", ["checkout", "main"], { cwd: repo });

    // Against main, this branch is NOT merged (it has develop-only commits)
    const resultAgainstMain: DeleteBranchResult = await deleteBranch(repo, "feature/custom-target");
    expect(resultAgainstMain).toEqual({ deleted: false, wasFullyMerged: false });

    // Against develop, this branch IS merged
    const resultAgainstDevelop: DeleteBranchResult = await deleteBranch(repo, "feature/custom-target", {
      targetBranch: "develop",
    });
    expect(resultAgainstDevelop).toEqual({ deleted: true, wasFullyMerged: true });
  });
});
