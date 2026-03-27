/**
 * GitBackend — Git-specific VCS backend implementation.
 *
 * Provides repository introspection methods extracted from src/lib/git.ts
 * into a class-based, backend-agnostic design.
 *
 * @module src/lib/vcs/git-backend
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

/**
 * GitBackend encapsulates git-specific VCS operations for a given project path.
 *
 * Constructor receives the project root path; all methods operate relative to it
 * unless given an explicit path argument (for worktree-aware operations).
 */
export class GitBackend {
  readonly projectPath: string;

  constructor(projectPath: string) {
    this.projectPath = projectPath;
  }

  // ── Private helpers ──────────────────────────────────────────────────

  /**
   * Execute a git command in the given working directory.
   * Returns trimmed stdout on success; throws with a formatted error on failure.
   */
  private async git(args: string[], cwd: string): Promise<string> {
    try {
      const { stdout } = await execFileAsync("git", args, {
        cwd,
        maxBuffer: 10 * 1024 * 1024,
      });
      return stdout.trim();
    } catch (err: unknown) {
      const e = err as { stdout?: string; stderr?: string; message?: string };
      const combined =
        [e.stdout, e.stderr]
          .map((s) => (s ?? "").trim())
          .filter(Boolean)
          .join("\n") || e.message || String(err);
      throw new Error(`git ${args[0]} failed: ${combined}`);
    }
  }

  // ── Repository Introspection ─────────────────────────────────────────

  /**
   * Find the root of the git repository containing `path`.
   *
   * Returns the worktree root for linked worktrees.
   * Use `getMainRepoRoot()` to always get the primary project root.
   */
  async getRepoRoot(path: string): Promise<string> {
    return this.git(["rev-parse", "--show-toplevel"], path);
  }

  /**
   * Find the main (primary) worktree root from any git worktree.
   *
   * `git rev-parse --show-toplevel` returns the *current* worktree root,
   * which for a linked worktree is the worktree directory itself — not the
   * main project root.  This function resolves the common `.git` directory
   * and strips the trailing `/.git` to always return the main project root.
   */
  async getMainRepoRoot(path: string): Promise<string> {
    const commonDir = await this.git(["rev-parse", "--git-common-dir"], path);
    // commonDir is e.g. "/path/to/project/.git" — strip the trailing "/.git"
    if (commonDir.endsWith("/.git")) {
      return commonDir.slice(0, -5);
    }
    // Fallback: if not a standard path, use show-toplevel
    return this.git(["rev-parse", "--show-toplevel"], path);
  }

  /**
   * Detect the default/parent branch for a repository.
   *
   * Resolution order:
   * 1. `git config get git-town.main-branch` — respect user's explicit development trunk config
   * 2. `git symbolic-ref refs/remotes/origin/HEAD --short` → strips "origin/" prefix
   *    (e.g. "origin/main" → "main"). Works when the remote has been fetched.
   * 3. Check whether "main" exists as a local branch.
   * 4. Check whether "master" exists as a local branch.
   * 5. Fall back to the current branch (`getCurrentBranch()`).
   */
  async detectDefaultBranch(repoPath: string): Promise<string> {
    // 1. Respect git-town.main-branch config (user's explicit development trunk)
    try {
      const gtMain = await this.git(
        ["config", "get", "git-town.main-branch"],
        repoPath,
      );
      if (gtMain) return gtMain;
    } catch {
      // git-town not configured or command unavailable — fall through
    }

    // 2. Try origin/HEAD symbolic ref
    try {
      const ref = await this.git(
        ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"],
        repoPath,
      );
      // ref is e.g. "origin/main" — strip the "origin/" prefix
      if (ref) {
        return ref.replace(/^origin\//, "");
      }
    } catch {
      // origin/HEAD not set or no remote — fall through
    }

    // 3. Check if "main" exists locally
    try {
      await this.git(["rev-parse", "--verify", "main"], repoPath);
      return "main";
    } catch {
      // "main" does not exist — fall through
    }

    // 4. Check if "master" exists locally
    try {
      await this.git(["rev-parse", "--verify", "master"], repoPath);
      return "master";
    } catch {
      // "master" does not exist — fall through
    }

    // 5. Fall back to the current branch
    return this.getCurrentBranch(repoPath);
  }

  /**
   * Get the current branch name.
   */
  async getCurrentBranch(repoPath: string): Promise<string> {
    return this.git(["rev-parse", "--abbrev-ref", "HEAD"], repoPath);
  }
}
