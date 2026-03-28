/**
 * GitBackend — Git-specific VCS backend implementation.
 *
 * Implements the `VcsBackend` interface using standard `git` CLI commands.
 * Extracted from src/lib/git.ts into a class-based, backend-agnostic design.
 *
 * @module src/lib/vcs/git-backend
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";
import fs from "node:fs/promises";
import { join } from "node:path";

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
import type { VcsBackend } from "./interface.js";

const execFileAsync = promisify(execFile);

/**
 * GitBackend encapsulates git-specific VCS operations for a given project path.
 *
 * Constructor receives the project root path; all methods operate relative to it
 * unless given an explicit path argument (for worktree-aware operations).
 */
export class GitBackend implements VcsBackend {
  readonly name = 'git' as const;
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
        env: { ...process.env, GIT_EDITOR: "true" },
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

  // ── Branch Operations ────────────────────────────────────────────────

  /**
   * Checkout a branch by name.
   */
  async checkoutBranch(repoPath: string, branchName: string): Promise<void> {
    await this.git(["checkout", branchName], repoPath);
  }

  /**
   * Return true if the given local branch exists.
   */
  async branchExists(repoPath: string, branchName: string): Promise<boolean> {
    try {
      await this.git(["show-ref", "--verify", "--quiet", `refs/heads/${branchName}`], repoPath);
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Return true if the branch exists on the origin remote.
   */
  async branchExistsOnRemote(repoPath: string, branchName: string): Promise<boolean> {
    try {
      await this.git(["rev-parse", "--verify", `origin/${branchName}`], repoPath);
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Delete a local branch with merge-safety checks.
   *
   * - If fully merged into targetBranch → uses `git branch -D` (after verifying via merge-base).
   * - If NOT merged and `force: true` → force-deletes.
   * - If NOT merged and `force: false` (default) → skips.
   * - If branch doesn't exist → returns `{ deleted: false, wasFullyMerged: true }`.
   */
  async deleteBranch(
    repoPath: string,
    branchName: string,
    options?: DeleteBranchOptions,
  ): Promise<DeleteBranchResult> {
    const force = options?.force ?? false;
    const targetBranch =
      options?.targetBranch ?? (await this.detectDefaultBranch(repoPath));

    // Check if branch exists
    try {
      await this.git(["rev-parse", "--verify", branchName], repoPath);
    } catch {
      return { deleted: false, wasFullyMerged: true };
    }

    // Check merge status
    let isFullyMerged = false;
    try {
      await this.git(
        ["merge-base", "--is-ancestor", branchName, targetBranch],
        repoPath,
      );
      isFullyMerged = true;
    } catch {
      isFullyMerged = false;
    }

    if (isFullyMerged) {
      await this.git(["branch", "-D", branchName], repoPath);
      return { deleted: true, wasFullyMerged: true };
    }

    if (force) {
      await this.git(["branch", "-D", branchName], repoPath);
      return { deleted: true, wasFullyMerged: false };
    }

    return { deleted: false, wasFullyMerged: false };
  }

  // ── Workspace / Worktree Operations ─────────────────────────────────

  /**
   * Create a git worktree for a seed.
   *
   * - Branch: foreman/<seedId>
   * - Location: <repoPath>/.foreman-worktrees/<seedId>
   * - Base: baseBranch or current branch
   *
   * If the worktree already exists, rebases onto the base branch.
   */
  async createWorkspace(
    repoPath: string,
    seedId: string,
    baseBranch?: string,
  ): Promise<WorkspaceResult> {
    const base = baseBranch ?? (await this.getCurrentBranch(repoPath));
    const branchName = `foreman/${seedId}`;
    const workspacePath = join(repoPath, ".foreman-worktrees", seedId);

    // If worktree already exists — reuse it with rebase
    if (existsSync(workspacePath)) {
      try {
        await this.git(["rebase", base], workspacePath);
      } catch (rebaseErr) {
        const rebaseMsg =
          rebaseErr instanceof Error ? rebaseErr.message : String(rebaseErr);
        const hasUnstagedChanges =
          rebaseMsg.includes("unstaged changes") ||
          rebaseMsg.includes("uncommitted changes") ||
          rebaseMsg.includes("please stash");

        if (hasUnstagedChanges) {
          try {
            await this.git(["checkout", "--", "."], workspacePath);
            await this.git(["clean", "-fd"], workspacePath);
            await this.git(["rebase", base], workspacePath);
          } catch (retryErr) {
            const retryMsg =
              retryErr instanceof Error ? retryErr.message : String(retryErr);
            try {
              await this.git(["rebase", "--abort"], workspacePath);
            } catch { /* already clean */ }
            throw new Error(
              `Rebase failed even after cleaning unstaged changes: ${retryMsg}`,
            );
          }
        } else {
          try {
            await this.git(["rebase", "--abort"], workspacePath);
          } catch { /* already clean */ }
          throw new Error(
            `Rebase failed in ${workspacePath}: ${rebaseMsg.slice(0, 300)}`,
          );
        }
      }
      return { workspacePath, branchName };
    }

    // Branch may exist without a worktree
    try {
      await this.git(
        ["worktree", "add", "-b", branchName, workspacePath, base],
        repoPath,
      );
    } catch (err: unknown) {
      const msg = (err as Error).message ?? "";
      if (msg.includes("already exists")) {
        await this.git(["worktree", "add", workspacePath, branchName], repoPath);
      } else {
        throw err;
      }
    }

    return { workspacePath, branchName };
  }

  /**
   * Remove a git worktree and prune stale metadata.
   */
  async removeWorkspace(repoPath: string, workspacePath: string): Promise<void> {
    try {
      await this.git(["worktree", "remove", workspacePath, "--force"], repoPath);
    } catch (removeErr) {
      const removeMsg =
        removeErr instanceof Error ? removeErr.message : String(removeErr);
      console.error(
        `[git] Warning: git worktree remove --force failed for ${workspacePath}: ${removeMsg}`,
      );
      try {
        await fs.rm(workspacePath, { recursive: true, force: true });
      } catch (rmErr) {
        const rmMsg = rmErr instanceof Error ? rmErr.message : String(rmErr);
        console.error(
          `[git] Warning: fs.rm fallback also failed for ${workspacePath}: ${rmMsg}`,
        );
      }
    }

    try {
      await this.git(["worktree", "prune"], repoPath);
    } catch (pruneErr) {
      const msg = pruneErr instanceof Error ? pruneErr.message : String(pruneErr);
      console.error(
        `[git] Warning: worktree prune failed after removing ${workspacePath}: ${msg}`,
      );
    }
  }

  /**
   * List all git worktrees for the repo.
   */
  async listWorkspaces(repoPath: string): Promise<Workspace[]> {
    const raw = await this.git(["worktree", "list", "--porcelain"], repoPath);
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

  // ── Staging and Commit Operations ────────────────────────────────────

  /**
   * Stage all changes (git add -A).
   */
  async stageAll(workspacePath: string): Promise<void> {
    await this.git(["add", "-A"], workspacePath);
  }

  /**
   * Commit staged changes with the given message.
   */
  async commit(workspacePath: string, message: string): Promise<void> {
    await this.git(["commit", "-m", message], workspacePath);
  }

  /**
   * Push the branch to origin.
   */
  async push(
    workspacePath: string,
    branchName: string,
    options?: PushOptions,
  ): Promise<void> {
    const args = ["push", "-u", "origin", branchName];
    if (options?.force) {
      args.splice(1, 0, "-f");
    }
    await this.git(args, workspacePath);
  }

  /**
   * Pull/fast-forward the current branch from origin.
   */
  async pull(workspacePath: string, branchName: string): Promise<void> {
    await this.git(["pull", "origin", branchName, "--ff-only"], workspacePath);
  }

  // ── Rebase and Merge Operations ──────────────────────────────────────

  /**
   * Rebase the current branch onto `onto`.
   */
  async rebase(workspacePath: string, onto: string): Promise<RebaseResult> {
    try {
      await this.git(["rebase", onto], workspacePath);
      return { success: true, hasConflicts: false };
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);

      // Check for conflict markers
      let conflictingFiles: string[] = [];
      try {
        const statusOut = await this.git(
          ["diff", "--name-only", "--diff-filter=U"],
          workspacePath,
        );
        conflictingFiles = statusOut
          .split("\n")
          .map((f) => f.trim())
          .filter(Boolean);
      } catch {
        // Best effort — ignore error getting conflict list
      }

      if (
        msg.includes("CONFLICT") ||
        msg.includes("conflict") ||
        conflictingFiles.length > 0
      ) {
        return {
          success: false,
          hasConflicts: true,
          conflictingFiles,
        };
      }

      throw err;
    }
  }

  /**
   * Abort an in-progress rebase.
   */
  async abortRebase(workspacePath: string): Promise<void> {
    await this.git(["rebase", "--abort"], workspacePath);
  }

  /**
   * Merge a source branch into a target branch using --no-ff.
   * Stashes any uncommitted changes before merging.
   */
  async merge(
    repoPath: string,
    sourceBranch: string,
    targetBranch?: string,
  ): Promise<MergeResult> {
    const target = targetBranch ?? (await this.getCurrentBranch(repoPath));

    // Stash local changes if needed
    let stashed = false;
    try {
      const stashOut = await this.git(
        ["stash", "push", "-m", "foreman-merge-auto-stash"],
        repoPath,
      );
      stashed = !stashOut.includes("No local changes");
    } catch {
      // stash may fail if nothing to stash — fine
    }

    try {
      await this.git(["checkout", target], repoPath);

      try {
        await this.git(["merge", sourceBranch, "--no-ff"], repoPath);
        return { success: true };
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        if (message.includes("CONFLICT") || message.includes("Merge conflict")) {
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
        throw err;
      }
    } finally {
      if (stashed) {
        try {
          await this.git(["stash", "pop"], repoPath);
        } catch {
          // pop may conflict — leave in stash
        }
      }
    }
  }

  // ── Diff, Status and Conflict Detection ─────────────────────────────

  /**
   * Get the current HEAD commit hash.
   */
  async getHeadId(workspacePath: string): Promise<string> {
    return this.git(["rev-parse", "HEAD"], workspacePath);
  }

  /**
   * Resolve an arbitrary ref (branch name, remote ref, tag, etc.) to its commit hash.
   * Equivalent to `git rev-parse <ref>`.
   * Throws if the ref does not exist.
   */
  async resolveRef(repoPath: string, ref: string): Promise<string> {
    return this.git(["rev-parse", ref], repoPath);
  }

  /**
   * Fetch updates from origin (no merge).
   */
  async fetch(repoPath: string): Promise<void> {
    await this.git(["fetch", "origin"], repoPath);
  }

  /**
   * Get a unified diff between two refs.
   */
  async diff(repoPath: string, from: string, to: string): Promise<string> {
    return this.git(["diff", `${from}..${to}`, "--"], repoPath);
  }

  /**
   * Get a list of file paths changed between two refs (three-dot semantics).
   * Equivalent to `git diff --name-only <from>...<to>`.
   * Returns an empty array if no files changed or refs do not exist.
   */
  async getChangedFiles(repoPath: string, from: string, to: string): Promise<string[]> {
    try {
      const out = await this.git(["diff", "--name-only", `${from}...${to}`], repoPath);
      if (!out) return [];
      return out.split("\n").map((f) => f.trim()).filter(Boolean);
    } catch {
      return [];
    }
  }

  /**
   * List files modified (staged or unstaged) in the workspace.
   */
  async getModifiedFiles(workspacePath: string): Promise<string[]> {
    const out = await this.git(["status", "--porcelain"], workspacePath);
    if (!out) return [];
    return out
      .split("\n")
      .map((l) => {
        // Porcelain v1: "XY PATH" — 2 status chars + 1 space + path.
        // The private git() helper trims() the entire stdout string, which can
        // strip the leading space from the first line when the X status char is
        // a space (e.g., " M file" becomes "M file" after whole-string trim).
        // Trimming each line individually normalises all lines to "YY PATH"
        // form, then slice(2) + trim() extracts the path robustly.
        const normalized = l.trim();
        if (normalized.length < 3) return "";
        return normalized.slice(2).trim();
      })
      .filter(Boolean);
  }

  /**
   * List files with unresolved merge/rebase conflicts.
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
   * Get working tree status (porcelain format).
   */
  async status(workspacePath: string): Promise<string> {
    return this.git(["status", "--porcelain"], workspacePath);
  }

  /**
   * Discard all unstaged changes and untracked files.
   */
  async cleanWorkingTree(workspacePath: string): Promise<void> {
    await this.git(["checkout", "--", "."], workspacePath);
    await this.git(["clean", "-fd"], workspacePath);
  }

  // ── Finalize Support ─────────────────────────────────────────────────

  /**
   * Return pre-computed git finalize commands for prompt rendering.
   */
  getFinalizeCommands(vars: FinalizeTemplateVars): FinalizeCommands {
    const { seedId, seedTitle, baseBranch } = vars;
    return {
      stageCommand: "git add -A",
      commitCommand: `git commit -m "${seedTitle} (${seedId})"`,
      pushCommand: `git push -u origin foreman/${seedId}`,
      rebaseCommand: `git fetch origin && git rebase origin/${baseBranch}`,
      branchVerifyCommand: `git rev-parse --abbrev-ref HEAD`,
      cleanCommand: `git worktree remove --force ${vars.worktreePath}`,
    };
  }
}
