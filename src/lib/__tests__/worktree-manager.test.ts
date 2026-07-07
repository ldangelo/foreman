import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { WorktreeManager } from "../worktree-manager.js";

const tmpDirs: string[] = [];

function tmpDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tmpDirs.push(dir);
  return dir;
}

function git(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

function commitFile(repo: string, file: string, content: string, message: string): string {
  writeFileSync(join(repo, file), content);
  git(repo, ["add", file]);
  git(repo, ["commit", "-m", message]);
  return git(repo, ["rev-parse", "HEAD"]);
}

describe("WorktreeManager", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
    for (const dir of tmpDirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("derives the default root from HOME at construction time", () => {
    vi.stubEnv("HOME", "/tmp/foreman-home-test");

    const manager = new WorktreeManager();

    expect(manager.root).toBe(join("/tmp/foreman-home-test", ".foreman", "worktrees"));
  });

  it("creates worktrees from fetched origin target instead of stale local branch", async () => {
    const remote = join(tmpDir("foreman-remote-"), "repo.git");
    execFileSync("git", ["init", "--bare", "--initial-branch=main", remote], { stdio: "pipe" });

    const repo = join(tmpDir("foreman-repo-"), "repo");
    execFileSync("git", ["clone", remote, repo], { stdio: "pipe" });
    git(repo, ["config", "user.email", "test@example.com"]);
    git(repo, ["config", "user.name", "Test User"]);
    const oldHead = commitFile(repo, "file.txt", "old\n", "old");
    git(repo, ["push", "origin", "main"]);

    const updater = join(tmpDir("foreman-updater-"), "repo");
    execFileSync("git", ["clone", remote, updater], { stdio: "pipe" });
    git(updater, ["config", "user.email", "test@example.com"]);
    git(updater, ["config", "user.name", "Test User"]);
    const newHead = commitFile(updater, "file.txt", "new\n", "new");
    git(updater, ["push", "origin", "main"]);

    expect(git(repo, ["rev-parse", "main"])).toBe(oldHead);

    const manager = new WorktreeManager({ root: join(tmpDir("foreman-worktrees-"), "worktrees") });
    const worktree = await manager.createWorktree({
      projectId: "proj",
      taskId: "task-1",
      repoPath: repo,
      baseBranch: "main",
    });

    expect(git(worktree.path, ["rev-parse", "HEAD"])).toBe(newHead);
    expect(git(repo, ["rev-parse", "main"])).toBe(newHead);
  });

  it("prunes stale git worktree registrations before reusing a leftover branch", async () => {
    const repo = join(tmpDir("foreman-repo-"), "repo");
    execFileSync("git", ["init", "--initial-branch=main", repo], { stdio: "pipe" });
    git(repo, ["config", "user.email", "test@example.com"]);
    git(repo, ["config", "user.name", "Test User"]);
    const head = commitFile(repo, "file.txt", "initial\n", "initial");

    const root = join(tmpDir("foreman-worktrees-"), "worktrees");
    const manager = new WorktreeManager({ root });
    const first = await manager.createWorktree({
      projectId: "proj",
      taskId: "task-1",
      repoPath: repo,
      baseBranch: "main",
    });
    rmSync(first.path, { recursive: true, force: true });
    expect(git(repo, ["worktree", "list", "--porcelain"])).toContain("prunable");

    const second = await manager.createWorktree({
      projectId: "proj",
      taskId: "task-1",
      repoPath: repo,
      baseBranch: "main",
    });

    expect(existsSync(second.path)).toBe(true);
    expect(git(second.path, ["rev-parse", "HEAD"])).toBe(head);
  });

  it("resets leftover branches to the fetched origin target before attaching", async () => {
    const remote = join(tmpDir("foreman-remote-"), "repo.git");
    execFileSync("git", ["init", "--bare", "--initial-branch=main", remote], { stdio: "pipe" });

    const repo = join(tmpDir("foreman-repo-"), "repo");
    execFileSync("git", ["clone", remote, repo], { stdio: "pipe" });
    git(repo, ["config", "user.email", "test@example.com"]);
    git(repo, ["config", "user.name", "Test User"]);
    commitFile(repo, "file.txt", "old\n", "old");
    git(repo, ["push", "origin", "main"]);
    git(repo, ["branch", "foreman/task-1", "main"]);

    const updater = join(tmpDir("foreman-updater-"), "repo");
    execFileSync("git", ["clone", remote, updater], { stdio: "pipe" });
    git(updater, ["config", "user.email", "test@example.com"]);
    git(updater, ["config", "user.name", "Test User"]);
    const newHead = commitFile(updater, "file.txt", "new\n", "new");
    git(updater, ["push", "origin", "main"]);

    const manager = new WorktreeManager({ root: join(tmpDir("foreman-worktrees-"), "worktrees") });
    const worktree = await manager.createWorktree({
      projectId: "proj",
      taskId: "task-1",
      repoPath: repo,
      baseBranch: "main",
    });

    expect(existsSync(worktree.path)).toBe(true);
    expect(git(worktree.path, ["rev-parse", "HEAD"])).toBe(newHead);
  });
});
