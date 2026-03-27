/**
 * GitBackend — Git-specific VCS backend implementation.
 *
 * Phase A: Implements the VcsBackend interface. The 4 repository-introspection
 * methods are fully implemented; the remaining methods are Phase-B stubs that
 * throw descriptive errors. Full implementation follows in Phase B.
 *
 * @module src/lib/vcs/git-backend
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { VcsBackend } from "./backend.js";
import type {
  Workspace,
  WorkspaceResult,
  MergeResult,
  RebaseResult,
  DeleteBranchOptions,
  DeleteBranchResult,
  PushOptions,
  FinalizeTemplateVars,
  FinalizeCommands,
} from "./types.js";

const execFileAsync = promisify(execFile);

/**
 * GitBackend encapsulates git-specific VCS operations for a given project path.
 *
 * Constructor receives the project root path; all methods operate relative to it
 * unless given an explicit path argument (for worktree-aware operations).
 */
export class GitBackend implements VcsBackend {
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

  // ── Branch / Bookmark Operations — Phase B stubs ────────────────────

  async checkoutBranch(_repoPath: string, _branchName: string): Promise<void> {
    throw new Error("GitBackend.checkoutBranch: not yet implemented (Phase B)");
  }

  async branchExists(_repoPath: string, _branchName: string): Promise<boolean> {
    throw new Error("GitBackend.branchExists: not yet implemented (Phase B)");
  }

  async branchExistsOnRemote(
    _repoPath: string,
    _branchName: string,
  ): Promise<boolean> {
    throw new Error(
      "GitBackend.branchExistsOnRemote: not yet implemented (Phase B)",
    );
  }

  async deleteBranch(
    _repoPath: string,
    _branchName: string,
    _opts?: DeleteBranchOptions,
  ): Promise<DeleteBranchResult> {
    throw new Error("GitBackend.deleteBranch: not yet implemented (Phase B)");
  }

  // ── Workspace Management — Phase B stubs ─────────────────────────────

  async createWorkspace(
    _repoPath: string,
    _seedId: string,
    _baseBranch?: string,
    _setupSteps?: string[],
    _setupCache?: string,
  ): Promise<WorkspaceResult> {
    throw new Error(
      "GitBackend.createWorkspace: not yet implemented (Phase B)",
    );
  }

  async removeWorkspace(
    _repoPath: string,
    _workspacePath: string,
  ): Promise<void> {
    throw new Error(
      "GitBackend.removeWorkspace: not yet implemented (Phase B)",
    );
  }

  async listWorkspaces(_repoPath: string): Promise<Workspace[]> {
    throw new Error(
      "GitBackend.listWorkspaces: not yet implemented (Phase B)",
    );
  }

  // ── Commit & Sync — Phase B stubs ────────────────────────────────────

  async stageAll(_workspacePath: string): Promise<void> {
    throw new Error("GitBackend.stageAll: not yet implemented (Phase B)");
  }

  async commit(_workspacePath: string, _message: string): Promise<string> {
    throw new Error("GitBackend.commit: not yet implemented (Phase B)");
  }

  async getHeadId(_workspacePath: string): Promise<string> {
    throw new Error("GitBackend.getHeadId: not yet implemented (Phase B)");
  }

  async push(
    _workspacePath: string,
    _branchName: string,
    _opts?: PushOptions,
  ): Promise<void> {
    throw new Error("GitBackend.push: not yet implemented (Phase B)");
  }

  async pull(_workspacePath: string, _branchName: string): Promise<void> {
    throw new Error("GitBackend.pull: not yet implemented (Phase B)");
  }

  async fetch(_workspacePath: string): Promise<void> {
    throw new Error("GitBackend.fetch: not yet implemented (Phase B)");
  }

  async rebase(_workspacePath: string, _onto: string): Promise<RebaseResult> {
    throw new Error("GitBackend.rebase: not yet implemented (Phase B)");
  }

  async abortRebase(_workspacePath: string): Promise<void> {
    throw new Error("GitBackend.abortRebase: not yet implemented (Phase B)");
  }

  // ── Merge Operations — Phase B stubs ─────────────────────────────────

  async merge(
    _repoPath: string,
    _branchName: string,
    _targetBranch?: string,
  ): Promise<MergeResult> {
    throw new Error("GitBackend.merge: not yet implemented (Phase B)");
  }

  // ── Diff, Conflict & Status — Phase B stubs ──────────────────────────

  async getConflictingFiles(_workspacePath: string): Promise<string[]> {
    throw new Error(
      "GitBackend.getConflictingFiles: not yet implemented (Phase B)",
    );
  }

  async diff(_repoPath: string, _from: string, _to: string): Promise<string> {
    throw new Error("GitBackend.diff: not yet implemented (Phase B)");
  }

  async getModifiedFiles(
    _workspacePath: string,
    _base: string,
  ): Promise<string[]> {
    throw new Error(
      "GitBackend.getModifiedFiles: not yet implemented (Phase B)",
    );
  }

  async cleanWorkingTree(_workspacePath: string): Promise<void> {
    throw new Error(
      "GitBackend.cleanWorkingTree: not yet implemented (Phase B)",
    );
  }

  async status(_workspacePath: string): Promise<string> {
    throw new Error("GitBackend.status: not yet implemented (Phase B)");
  }

  // ── Finalize Command Generation — Phase B stub ────────────────────────

  getFinalizeCommands(_vars: FinalizeTemplateVars): FinalizeCommands {
    throw new Error(
      "GitBackend.getFinalizeCommands: not yet implemented (Phase B)",
    );
  }
}
