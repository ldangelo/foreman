/**
 * GitBackend — Git-specific VCS backend implementation.
 *
 * Phase A: Implements the VcsBackend interface. The 4 repository-introspection
 * methods are fully implemented.
 *
 * Phase B: All remaining methods implemented (TRD-005 through TRD-010).
 *
 * @module src/lib/vcs/git-backend
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";
import fs from "node:fs/promises";
import { join } from "node:path";
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
import {
  runSetupWithCache,
  installDependencies,
} from "../git.js";
import type { WorkflowSetupStep, WorkflowSetupCache } from "../workflow-loader.js";

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

  // ── Branch / Bookmark Operations — TRD-005 ──────────────────────────

  /**
   * Checkout an existing branch. Throws if the branch does not exist.
   */
  async checkoutBranch(repoPath: string, branchName: string): Promise<void> {
    await this.git(["checkout", branchName], repoPath);
  }

  /**
   * Check whether a local branch exists.
   * Uses `git show-ref --verify --quiet refs/heads/<branchName>`.
   */
  async branchExists(repoPath: string, branchName: string): Promise<boolean> {
    try {
      await this.git(
        ["show-ref", "--verify", "--quiet", `refs/heads/${branchName}`],
        repoPath,
      );
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Check whether a branch exists on the origin remote.
   * Uses `git rev-parse --verify origin/<branchName>` against local remote-tracking refs.
   */
  async branchExistsOnRemote(
    repoPath: string,
    branchName: string,
  ): Promise<boolean> {
    try {
      await this.git(
        ["rev-parse", "--verify", `origin/${branchName}`],
        repoPath,
      );
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Delete a local branch with merge-safety checks.
   *
   * - If the branch is fully merged into targetBranch, uses `git branch -D` (safe delete after verify).
   * - If NOT merged and `force: true`, uses `git branch -D` (force delete).
   * - If NOT merged and `force: false` (default), skips deletion.
   * - If the branch does not exist, returns `{ deleted: false, wasFullyMerged: true }`.
   */
  async deleteBranch(
    repoPath: string,
    branchName: string,
    opts?: DeleteBranchOptions,
  ): Promise<DeleteBranchResult> {
    const force = opts?.force ?? false;
    const targetBranch =
      opts?.targetBranch ?? (await this.detectDefaultBranch(repoPath));

    // Check if branch exists
    try {
      await this.git(["rev-parse", "--verify", branchName], repoPath);
    } catch {
      // Branch not found — already gone
      return { deleted: false, wasFullyMerged: true };
    }

    // Check merge status: is branchName an ancestor of targetBranch?
    let isFullyMerged = false;
    try {
      await this.git(
        ["merge-base", "--is-ancestor", branchName, targetBranch],
        repoPath,
      );
      isFullyMerged = true;
    } catch {
      // merge-base --is-ancestor exits non-zero when branch is NOT an ancestor
      isFullyMerged = false;
    }

    if (isFullyMerged) {
      // We verified merge status via merge-base --is-ancestor against targetBranch.
      // Use -D because git branch -d checks against HEAD, which may differ from targetBranch.
      await this.git(["branch", "-D", branchName], repoPath);
      return { deleted: true, wasFullyMerged: true };
    }

    if (force) {
      // Force delete — caller explicitly asked for it
      await this.git(["branch", "-D", branchName], repoPath);
      return { deleted: true, wasFullyMerged: false };
    }

    // Not merged and not forced — skip deletion
    return { deleted: false, wasFullyMerged: false };
  }

  // ── Workspace Management — TRD-006 ───────────────────────────────────

  /**
   * Create an isolated workspace (git worktree) for a task.
   *
   * - Branch: foreman/<seedId>
   * - Location: <repoPath>/.foreman-worktrees/<seedId>
   * - Base: baseBranch (or current branch if not specified)
   *
   * If the worktree already exists (retry case), rebases onto baseBranch
   * with auto-cleanup of unstaged changes if needed.
   */
  async createWorkspace(
    repoPath: string,
    seedId: string,
    baseBranch?: string,
    setupSteps?: WorkflowSetupStep[],
    setupCache?: WorkflowSetupCache,
  ): Promise<WorkspaceResult> {
    const base = baseBranch ?? (await this.getCurrentBranch(repoPath));
    const branchName = `foreman/${seedId}`;
    const worktreePath = join(repoPath, ".foreman-worktrees", seedId);

    // If worktree already exists (e.g. from a failed previous run), reuse it
    if (existsSync(worktreePath)) {
      // Update the branch to the latest base so it picks up new code.
      // Rebase may fail when there are unstaged changes in the worktree —
      // attempt a `git checkout -- .` to discard them before retrying.
      try {
        await this.git(["rebase", base], worktreePath);
      } catch (rebaseErr) {
        const rebaseMsg =
          rebaseErr instanceof Error ? rebaseErr.message : String(rebaseErr);
        const hasUnstagedChanges =
          rebaseMsg.includes("unstaged changes") ||
          rebaseMsg.includes("uncommitted changes") ||
          rebaseMsg.includes("please stash");

        if (hasUnstagedChanges) {
          console.error(
            `[git] Rebase failed due to unstaged changes in ${worktreePath} — cleaning and retrying`,
          );
          try {
            // Discard all unstaged changes and untracked files so rebase can proceed
            await this.git(["checkout", "--", "."], worktreePath);
            await this.git(["clean", "-fd"], worktreePath);
            // Retry the rebase after cleaning
            await this.git(["rebase", base], worktreePath);
          } catch (retryErr) {
            const retryMsg =
              retryErr instanceof Error ? retryErr.message : String(retryErr);
            // Abort any partial rebase to leave the worktree in a usable state
            try {
              await this.git(["rebase", "--abort"], worktreePath);
            } catch {
              /* already clean */
            }
            throw new Error(
              `Rebase failed even after cleaning unstaged changes: ${retryMsg}`,
            );
          }
        } else {
          // Non-unstaged-changes rebase failure (e.g. real conflicts): throw so
          // the dispatcher does not spawn an agent into a broken worktree.
          try {
            await this.git(["rebase", "--abort"], worktreePath);
          } catch {
            /* already clean */
          }
          throw new Error(
            `Rebase failed in ${worktreePath}: ${rebaseMsg.slice(0, 300)}`,
          );
        }
      }
      // Reinstall in case dependencies changed after rebase
      if (setupSteps && setupSteps.length > 0) {
        await runSetupWithCache(worktreePath, repoPath, setupSteps, setupCache);
      } else {
        await installDependencies(worktreePath);
      }
      return { workspacePath: worktreePath, branchName };
    }

    // Branch may exist without a worktree (worktree was cleaned up but branch wasn't)
    try {
      await this.git(
        ["worktree", "add", "-b", branchName, worktreePath, base],
        repoPath,
      );
    } catch (err: unknown) {
      const msg = (err as Error).message ?? "";
      if (msg.includes("already exists")) {
        // Branch exists — create worktree using existing branch
        await this.git(["worktree", "add", worktreePath, branchName], repoPath);
      } else {
        throw err;
      }
    }

    // Run setup steps with caching (or fallback to Node.js dependency install)
    if (setupSteps && setupSteps.length > 0) {
      await runSetupWithCache(worktreePath, repoPath, setupSteps, setupCache);
    } else {
      await installDependencies(worktreePath);
    }

    return { workspacePath: worktreePath, branchName };
  }

  /**
   * Remove an existing workspace (git worktree) and prune stale metadata.
   *
   * Tries `git worktree remove --force`, falls back to `fs.rm` for untracked
   * files, then runs `git worktree prune` non-fatally.
   */
  async removeWorkspace(
    repoPath: string,
    workspacePath: string,
  ): Promise<void> {
    // Try the standard git removal first.
    try {
      await this.git(
        ["worktree", "remove", workspacePath, "--force"],
        repoPath,
      );
    } catch (removeErr) {
      const removeMsg =
        removeErr instanceof Error ? removeErr.message : String(removeErr);
      console.error(
        `[git] Warning: git worktree remove --force failed for ${workspacePath}: ${removeMsg}`,
      );
      console.error(`[git] Falling back to fs.rm for ${workspacePath}`);
      try {
        await fs.rm(workspacePath, { recursive: true, force: true });
      } catch (rmErr) {
        const rmMsg = rmErr instanceof Error ? rmErr.message : String(rmErr);
        console.error(
          `[git] Warning: fs.rm fallback also failed for ${workspacePath}: ${rmMsg}`,
        );
      }
    }

    // Prune stale .git/worktrees/<seed> metadata so the next dispatch does not
    // fail with "fatal: not a git repository: .git/worktrees/<seed>".
    try {
      await this.git(["worktree", "prune"], repoPath);
    } catch (pruneErr) {
      // Non-fatal: log a warning and continue.
      const msg =
        pruneErr instanceof Error ? pruneErr.message : String(pruneErr);
      console.error(
        `[git] Warning: worktree prune failed after removing ${workspacePath}: ${msg}`,
      );
    }
  }

  /**
   * List all workspaces (worktrees) for the repo.
   * Parses `git worktree list --porcelain` output into Workspace[].
   */
  async listWorkspaces(repoPath: string): Promise<Workspace[]> {
    const raw = await this.git(
      ["worktree", "list", "--porcelain"],
      repoPath,
    );

    if (!raw) return [];

    const workspaces: Workspace[] = [];
    let current: Partial<Workspace> = {};

    for (const line of raw.split("\n")) {
      if (line.startsWith("worktree ")) {
        if (current.path) workspaces.push(current as Workspace);
        current = { path: line.slice("worktree ".length), bare: false };
      } else if (line.startsWith("HEAD ")) {
        current.head = line.slice("HEAD ".length);
      } else if (line.startsWith("branch ")) {
        // refs/heads/foreman/abc → foreman/abc
        current.branch = line.slice("branch refs/heads/".length);
      } else if (line === "bare") {
        current.bare = true;
      } else if (line === "detached") {
        current.branch = "(detached)";
      } else if (line === "" && current.path) {
        workspaces.push(current as Workspace);
        current = {};
      }
    }
    if (current.path) workspaces.push(current as Workspace);

    return workspaces;
  }

  // ── Commit & Sync — TRD-007 ──────────────────────────────────────────

  /**
   * Stage all changes in the workspace.
   */
  async stageAll(workspacePath: string): Promise<void> {
    await this.git(["add", "-A"], workspacePath);
  }

  /**
   * Commit staged changes with the given message.
   * Returns the short commit hash.
   */
  async commit(workspacePath: string, message: string): Promise<string> {
    await this.git(["commit", "-m", message], workspacePath);
    return this.git(["rev-parse", "--short", "HEAD"], workspacePath);
  }

  /**
   * Get the current HEAD commit hash (short form).
   */
  async getHeadId(workspacePath: string): Promise<string> {
    return this.git(["rev-parse", "--short", "HEAD"], workspacePath);
  }

  /**
   * Push the current branch to the remote.
   * Uses `-u origin <branchName>` with optional force flag.
   */
  async push(
    workspacePath: string,
    branchName: string,
    opts?: PushOptions,
  ): Promise<void> {
    const args = ["push", "-u", "origin", branchName];
    if (opts?.force) args.push("--force");
    await this.git(args, workspacePath);
  }

  /**
   * Pull (fetch + merge) the latest changes for the given branch.
   */
  async pull(workspacePath: string, branchName: string): Promise<void> {
    await this.git(["fetch", "origin"], workspacePath);
    await this.git(["merge", `origin/${branchName}`], workspacePath);
  }

  /**
   * Fetch all refs from the remote without merging.
   */
  async fetch(workspacePath: string): Promise<void> {
    await this.git(["fetch", "origin"], workspacePath);
  }

  /**
   * Rebase the current workspace branch onto `onto` (after fetching).
   * Returns a structured result; does NOT throw on conflict.
   */
  async rebase(workspacePath: string, onto: string): Promise<RebaseResult> {
    try {
      await this.git(["fetch", "origin"], workspacePath);
    } catch {
      // Fetch failure is non-fatal (e.g. no remote) — try rebase anyway
    }

    try {
      await this.git(["rebase", `origin/${onto}`], workspacePath);
      return { success: true, hasConflicts: false };
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);

      // Check if there are conflicting files
      let conflictingFiles: string[] = [];
      try {
        const conflictOut = await this.git(
          ["diff", "--name-only", "--diff-filter=U"],
          workspacePath,
        );
        conflictingFiles = conflictOut
          .split("\n")
          .map((f) => f.trim())
          .filter(Boolean);
      } catch {
        // Can't determine conflicting files — return empty list
      }

      if (conflictingFiles.length > 0 || msg.includes("CONFLICT") || msg.includes("conflict")) {
        return {
          success: false,
          hasConflicts: true,
          conflictingFiles,
        };
      }

      // Unexpected error — re-throw
      throw err;
    }
  }

  /**
   * Abort an in-progress rebase and restore the workspace to its pre-rebase state.
   */
  async abortRebase(workspacePath: string): Promise<void> {
    await this.git(["rebase", "--abort"], workspacePath);
  }

  // ── Merge Operations — TRD-008 ────────────────────────────────────────

  /**
   * Merge a branch into targetBranch (or the current branch if omitted).
   *
   * Implements the stash-checkout-merge-restore pattern to handle dirty
   * working trees.
   *
   * Returns a structured result with the list of conflicting files on failure.
   * Does NOT throw on conflict — the caller must check `result.success`.
   */
  async merge(
    repoPath: string,
    branchName: string,
    targetBranch?: string,
  ): Promise<MergeResult> {
    const target = targetBranch ?? (await this.getCurrentBranch(repoPath));

    // Stash any local changes so checkout doesn't fail on a dirty tree
    let stashed = false;
    try {
      const stashOut = await this.git(
        ["stash", "push", "-m", "foreman-merge-auto-stash"],
        repoPath,
      );
      stashed = !stashOut.includes("No local changes");
    } catch {
      // stash may fail if there's nothing to stash — that's fine
    }

    try {
      // Checkout target branch
      await this.git(["checkout", target], repoPath);

      try {
        await this.git(["merge", branchName, "--no-ff"], repoPath);
        return { success: true };
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        if (
          message.includes("CONFLICT") ||
          message.includes("Merge conflict")
        ) {
          // Gather conflicting files
          const statusOut = await this.git(
            ["diff", "--name-only", "--diff-filter=U"],
            repoPath,
          );
          const conflicts = statusOut
            .split("\n")
            .map((f) => f.trim())
            .filter(Boolean);
          return { success: false, conflicts };
        }
        // Re-throw for unexpected errors
        throw err;
      }
    } finally {
      // Restore stashed changes
      if (stashed) {
        try {
          await this.git(["stash", "pop"], repoPath);
        } catch {
          // Pop may conflict — leave in stash, user can recover with `git stash pop`
        }
      }
    }
  }

  // ── Diff, Conflict & Status — TRD-009 ────────────────────────────────

  /**
   * Return the list of files in conflict during an active rebase or merge.
   */
  async getConflictingFiles(workspacePath: string): Promise<string[]> {
    const out = await this.git(
      ["diff", "--name-only", "--diff-filter=U"],
      workspacePath,
    );
    return out
      .split("\n")
      .map((f) => f.trim())
      .filter(Boolean);
  }

  /**
   * Return the diff output between two refs.
   */
  async diff(repoPath: string, from: string, to: string): Promise<string> {
    return this.git(["diff", `${from}..${to}`], repoPath);
  }

  /**
   * Return the list of files modified relative to `base`.
   */
  async getModifiedFiles(
    workspacePath: string,
    base: string,
  ): Promise<string[]> {
    const out = await this.git(
      ["diff", "--name-only", base],
      workspacePath,
    );
    return out
      .split("\n")
      .map((f) => f.trim())
      .filter(Boolean);
  }

  /**
   * Discard all uncommitted changes and restore the workspace to HEAD.
   */
  async cleanWorkingTree(workspacePath: string): Promise<void> {
    await this.git(["checkout", "--", "."], workspacePath);
    await this.git(["clean", "-fd"], workspacePath);
  }

  /**
   * Return a human-readable status summary of the workspace.
   */
  async status(workspacePath: string): Promise<string> {
    return this.git(["status", "--short"], workspacePath);
  }

  // ── Finalize Command Generation — TRD-010 ─────────────────────────────

  /**
   * Generate the git-specific shell commands for the Finalize phase.
   *
   * All 6 fields are required. Special characters in seedTitle are escaped
   * to prevent shell injection when commands are interpolated into prompts.
   */
  getFinalizeCommands(vars: FinalizeTemplateVars): FinalizeCommands {
    // Escape double quotes in seedTitle to prevent shell injection
    const escapedTitle = vars.seedTitle.replace(/"/g, '\\"');
    return {
      stageCommand: "git add -A",
      commitCommand: `git commit -m "${escapedTitle} (${vars.seedId})"`,
      pushCommand: `git push -u origin foreman/${vars.seedId}`,
      rebaseCommand: `git fetch origin && git rebase origin/${vars.baseBranch}`,
      branchVerifyCommand: `git rev-parse --verify origin/foreman/${vars.seedId}`,
      cleanCommand: "git worktree prune",
    };
  }
}
