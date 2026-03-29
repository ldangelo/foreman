/**
 * JujutsuBackend — Jujutsu (jj) VCS backend implementation.
 *
 * Implements the `VcsBackend` interface using the `jj` CLI.
 * Assumes a **colocated** Jujutsu repository (`.jj/` + `.git/` both present),
 * which is the only mode supported by Foreman.
 *
 * Key differences from GitBackend:
 * - Workspaces use `jj workspace add` / `jj workspace forget`.
 * - Branches are called "bookmarks" in jj (`jj bookmark`).
 * - Staging is automatic — `stageAll()` is a no-op.
 * - Commits use `jj describe -m` + `jj new`.
 * - Push requires `--allow-new` for first push of a new bookmark.
 * - Rebase uses `jj rebase -d <destination>`.
 *
 * @module src/lib/vcs/jujutsu-backend
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
 * JujutsuBackend encapsulates jj-specific VCS operations for a Foreman project.
 *
 * Foreman assumes a colocated jj repository so that git-based tooling
 * (GitHub Actions, gh CLI, etc.) continues to work alongside jj.
 */
export class JujutsuBackend implements VcsBackend {
  readonly name = 'jujutsu' as const;
  readonly projectPath: string;

  constructor(projectPath: string) {
    this.projectPath = projectPath;
  }

  // ── Private helpers ──────────────────────────────────────────────────

  /**
   * Execute a jj command in the given working directory.
   * Returns trimmed stdout on success; throws with a formatted error on failure.
   */
  private async jj(args: string[], cwd: string): Promise<string> {
    try {
      const { stdout } = await execFileAsync("jj", args, {
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
      // Use first two args for compound subcommands (e.g. "jj git push" → "jj git push failed")
      const cmdLabel = args.slice(0, 2).join(" ");
      throw new Error(`jj ${cmdLabel} failed: ${combined}`);
    }
  }

  /**
   * Execute a git command in the given working directory.
   * Used for operations that still need git in colocated mode
   * (e.g. getRepoRoot, getMainRepoRoot).
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
   * Find the root of the jj repository containing `path`.
   * In colocated mode this delegates to git rev-parse since both .jj and .git exist.
   */
  async getRepoRoot(path: string): Promise<string> {
    // In colocated mode, use git rev-parse for compatibility
    return this.git(["rev-parse", "--show-toplevel"], path);
  }

  /**
   * Find the main (primary) repository root from any workspace.
   * In colocated mode, delegates to git rev-parse --git-common-dir.
   */
  async getMainRepoRoot(path: string): Promise<string> {
    const commonDir = await this.git(["rev-parse", "--git-common-dir"], path);
    if (commonDir.endsWith("/.git")) {
      return commonDir.slice(0, -5);
    }
    return this.git(["rev-parse", "--show-toplevel"], path);
  }

  /**
   * Detect the default/trunk branch for the repository.
   *
   * Resolution order:
   * 1. Look for a 'main' bookmark.
   * 2. Look for a 'master' bookmark.
   * 3. Fall back to the current bookmark.
   */
  async detectDefaultBranch(repoPath: string): Promise<string> {
    // 1. Check for 'main' bookmark
    try {
      const out = await this.jj(["bookmark", "list", "main"], repoPath);
      if (out.includes("main")) return "main";
    } catch {
      // not found
    }

    // 2. Check for 'master' bookmark
    try {
      const out = await this.jj(["bookmark", "list", "master"], repoPath);
      if (out.includes("master")) return "master";
    } catch {
      // not found
    }

    // 3. Fall back to current branch
    return this.getCurrentBranch(repoPath);
  }

  /**
   * Get the name of the currently active bookmark.
   * Uses `jj log --no-graph -r @ -T 'bookmarks'` to find the current bookmark.
   * Falls back to the short change ID if no bookmark is set.
   */
  async getCurrentBranch(repoPath: string): Promise<string> {
    try {
      const bookmarks = await this.jj(
        ["log", "--no-graph", "-r", "@", "-T", "separate(' ', bookmarks)"],
        repoPath,
      );
      if (bookmarks) {
        // Take the first bookmark if multiple are set
        return bookmarks.split(" ")[0];
      }
    } catch {
      // fall through
    }

    // Fall back to short change ID
    return this.jj(["log", "--no-graph", "-r", "@", "-T", "change_id.short()"], repoPath);
  }

  // ── Branch / Bookmark Operations ────────────────────────────────────

  /**
   * Checkout (switch to) a bookmark by name.
   * In jj this is `jj edit <bookmark>`.
   *
   * Attempts to track the remote bookmark first (for remote-backed branches),
   * but gracefully ignores failures when the bookmark only exists locally.
   */
  async checkoutBranch(repoPath: string, branchName: string): Promise<void> {
    // Try to track the remote bookmark — this succeeds only if the bookmark exists on origin.
    // For local-only branches, this is expected to fail and we continue without tracking.
    try {
      await this.jj(["bookmark", "track", `${branchName}@origin`], repoPath);
    } catch {
      // Bookmark may not exist on origin yet — that's fine for local branches
    }
    await this.jj(["edit", branchName], repoPath);
  }

  /**
   * Return true if the given bookmark exists locally.
   */
  async branchExists(repoPath: string, branchName: string): Promise<boolean> {
    try {
      const out = await this.jj(
        ["bookmark", "list", branchName],
        repoPath,
      );
      return out.includes(branchName);
    } catch {
      return false;
    }
  }

  /**
   * Return true if the bookmark exists on the origin remote.
   */
  async branchExistsOnRemote(
    repoPath: string,
    branchName: string,
  ): Promise<boolean> {
    try {
      const out = await this.jj(
        ["bookmark", "list", "--remote", "origin", branchName],
        repoPath,
      );
      return out.includes(branchName);
    } catch {
      return false;
    }
  }

  /**
   * Delete a bookmark with optional merge-safety checks.
   * Uses `jj bookmark delete <name>`.
   */
  async deleteBranch(
    repoPath: string,
    branchName: string,
    options?: DeleteBranchOptions,
  ): Promise<DeleteBranchResult> {
    const force = options?.force ?? false;

    // Check if bookmark exists
    const exists = await this.branchExists(repoPath, branchName);
    if (!exists) {
      return { deleted: false, wasFullyMerged: true };
    }

    // For jujutsu we can't easily check merge status without git, so use git
    const targetBranch =
      options?.targetBranch ?? (await this.detectDefaultBranch(repoPath));

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

    if (isFullyMerged || force) {
      await this.jj(["bookmark", "delete", branchName], repoPath);
      return { deleted: true, wasFullyMerged: isFullyMerged };
    }

    return { deleted: false, wasFullyMerged: false };
  }

  // ── Workspace Operations ─────────────────────────────────────────────

  /**
   * Create a jj workspace for a seed.
   *
   * Creates a workspace at `.foreman-worktrees/<seedId>` and sets up
   * a bookmark `foreman/<seedId>` pointing to the new workspace's revision.
   *
   * Handles existing workspaces by rebasing onto the base branch.
   */
  async createWorkspace(
    repoPath: string,
    seedId: string,
    baseBranch?: string,
  ): Promise<WorkspaceResult> {
    const base = baseBranch ?? (await this.getCurrentBranch(repoPath));
    const branchName = `foreman/${seedId}`;
    const workspacePath = join(repoPath, ".foreman-worktrees", seedId);

    // If workspace directory already exists, reuse it
    if (existsSync(workspacePath)) {
      try {
        // Rebase the bookmark onto the base branch
        await this.jj(["rebase", "-b", branchName, "-d", base], repoPath);
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`[jj] Warning: rebase failed for ${workspacePath}: ${msg}`);
      }
      return { workspacePath, branchName };
    }

    // Ensure the parent directory exists (jj workspace add requires it)
    const worktreesDir = join(repoPath, ".foreman-worktrees");
    await fs.mkdir(worktreesDir, { recursive: true });

    // Create new workspace
    try {
      await this.jj(
        ["workspace", "add", "--name", `foreman-${seedId}`, workspacePath],
        repoPath,
      );
    } catch (err: unknown) {
      const msg = (err as Error).message ?? "";
      if (!msg.includes("already exists")) {
        throw err;
      }
    }

    // Create a bookmark for this workspace
    // Use "foreman-<seedId>@" syntax to reference the workspace's working copy
    const workspaceRef = `foreman-${seedId}@`;
    try {
      await this.jj(
        ["bookmark", "create", branchName, "-r", workspaceRef],
        repoPath,
      );
    } catch {
      // Bookmark may already exist — try to move it
      try {
        await this.jj(
          ["bookmark", "move", branchName, "--to", workspaceRef],
          repoPath,
        );
      } catch (moveErr) {
        const msg = moveErr instanceof Error ? moveErr.message : String(moveErr);
        console.error(`[jj] Warning: could not create/move bookmark ${branchName}: ${msg}`);
      }
    }

    return { workspacePath, branchName };
  }

  /**
   * Remove a jj workspace and its associated metadata.
   */
  async removeWorkspace(repoPath: string, workspacePath: string): Promise<void> {
    // Derive workspace name from path
    const seedId = workspacePath.split("/").pop() ?? "";
    const workspaceName = `foreman-${seedId}`;

    try {
      await this.jj(["workspace", "forget", workspaceName], repoPath);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`[jj] Warning: workspace forget failed for ${workspaceName}: ${msg}`);
    }

    // Also remove the directory
    try {
      await fs.rm(workspacePath, { recursive: true, force: true });
    } catch (rmErr) {
      const msg = rmErr instanceof Error ? rmErr.message : String(rmErr);
      console.error(`[jj] Warning: rm failed for ${workspacePath}: ${msg}`);
    }
  }

  /**
   * List all jj workspaces for the repo.
   */
  async listWorkspaces(repoPath: string): Promise<Workspace[]> {
    try {
      const raw = await this.jj(
        ["workspace", "list"],
        repoPath,
      );
      if (!raw) return [];

      const workspaces: Workspace[] = [];
      for (const line of raw.split("\n")) {
        // Format: "default: yklonqvs b91a4c60 (no description set)"
        // or "foreman-bd-deoi: abc123 ..."
        const match = line.match(/^(\S+):\s+(\S+)/);
        if (match) {
          const [, name, changeId] = match;
          // Map workspace name back to a path
          if (name !== "default") {
            const seedId = name.replace(/^foreman-/, "");
            const path = join(repoPath, ".foreman-worktrees", seedId);
            const branchName = `foreman/${seedId}`;
            workspaces.push({
              path,
              branch: branchName,
              head: changeId,
              bare: false,
            });
          }
        }
      }
      return workspaces;
    } catch {
      return [];
    }
  }

  // ── Staging and Commit Operations ────────────────────────────────────

  /**
   * No-op: jj auto-stages all changes.
   */
  async stageAll(_workspacePath: string): Promise<void> {
    // jj tracks changes automatically — no explicit staging step
  }

  /**
   * Commit the current revision with a message using `jj describe -m`.
   * Creates a new empty revision on top with `jj new`.
   */
  async commit(workspacePath: string, message: string): Promise<void> {
    await this.jj(["describe", "-m", message], workspacePath);
    await this.jj(["new"], workspacePath);
  }

  /**
   * Push a bookmark to origin using `jj git push`.
   * Passes `--allow-new` when `options.allowNew` is true (required for new bookmarks).
   */
  async push(
    workspacePath: string,
    branchName: string,
    options?: PushOptions,
  ): Promise<void> {
    const args = ["git", "push", "--bookmark", branchName];
    if (options?.allowNew) {
      args.push("--allow-new");
    }
    if (options?.force) {
      args.push("--force");
    }
    await this.jj(args, workspacePath);
  }

  /**
   * Pull/fetch from origin and update the bookmark.
   */
  async pull(workspacePath: string, branchName: string): Promise<void> {
    await this.jj(["git", "fetch", "--remote", "origin"], workspacePath);
    try {
      await this.jj(
        ["bookmark", "track", `${branchName}@origin`],
        workspacePath,
      );
    } catch {
      // bookmark may already be tracked
    }
  }

  // ── Rebase and Merge Operations ──────────────────────────────────────

  /**
   * Rebase the current workspace onto a destination bookmark.
   * Uses `jj rebase -d <onto>`.
   */
  async rebase(workspacePath: string, onto: string): Promise<RebaseResult> {
    try {
      await this.jj(["rebase", "-d", onto], workspacePath);

      // jj rebase exits 0 even when conflicts exist — it embeds conflict
      // markers in files and continues. Check explicitly after each rebase.
      let conflictingFiles: string[] = [];
      try {
        conflictingFiles = await this.getConflictingFiles(workspacePath);
      } catch {
        // best effort
      }

      if (conflictingFiles.length > 0) {
        return { success: false, hasConflicts: true, conflictingFiles };
      }

      return { success: true, hasConflicts: false };
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);

      // jj marks conflicted files differently; check for conflict marker
      let conflictingFiles: string[] = [];
      try {
        conflictingFiles = await this.getConflictingFiles(workspacePath);
      } catch {
        // best effort
      }

      if (
        msg.includes("conflict") ||
        msg.includes("Conflict") ||
        conflictingFiles.length > 0
      ) {
        return { success: false, hasConflicts: true, conflictingFiles };
      }

      throw err;
    }
  }

  /**
   * Abandon the last commit to undo a failed rebase.
   * jj doesn't have a "rebase --abort" but we can restore via `jj undo`.
   */
  async abortRebase(workspacePath: string): Promise<void> {
    try {
      await this.jj(["undo"], workspacePath);
    } catch {
      // best effort
    }
  }

  /**
   * Merge a source bookmark into a target bookmark.
   * In jj this creates a new commit that has both as parents via `jj new`.
   */
  async merge(
    repoPath: string,
    sourceBranch: string,
    targetBranch?: string,
  ): Promise<MergeResult> {
    const target = targetBranch ?? (await this.getCurrentBranch(repoPath));

    try {
      // Create a merge commit with two parents
      await this.jj(
        ["new", target, sourceBranch, "-m", `Merge ${sourceBranch} into ${target}`],
        repoPath,
      );
      return { success: true };
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);

      let conflictingFiles: string[] = [];
      try {
        conflictingFiles = await this.getConflictingFiles(repoPath);
      } catch {
        // best effort
      }

      if (
        msg.includes("conflict") ||
        msg.includes("Conflict") ||
        conflictingFiles.length > 0
      ) {
        return { success: false, conflicts: conflictingFiles };
      }

      throw err;
    }
  }

  // ── Diff, Status and Conflict Detection ─────────────────────────────

  /**
   * Get the current change ID (jj's equivalent of a commit hash).
   * Returns the short (12-char) change ID for consistency with how callers
   * typically use commit/change IDs (e.g., as labels or references).
   */
  async getHeadId(workspacePath: string): Promise<string> {
    return this.jj(
      ["log", "--no-graph", "-r", "@", "-T", "change_id.short()"],
      workspacePath,
    );
  }

  /**
   * Resolve an arbitrary revision expression to its change ID.
   * Equivalent to `jj log -r <ref> -T commit_id`.
   * Throws if the ref does not exist.
   */
  async resolveRef(repoPath: string, ref: string): Promise<string> {
    return this.jj(
      ["log", "--no-graph", "-r", ref, "-T", "commit_id"],
      repoPath,
    );
  }

  /**
   * Fetch updates from origin via `jj git fetch`.
   */

  async fetch(repoPath: string): Promise<void> {
    await this.jj(["git", "fetch", "--remote", "origin"], repoPath);
  }

  /**
   * Get a diff between two revisions/bookmarks.
   */
  async diff(repoPath: string, from: string, to: string): Promise<string> {
    return this.jj(["diff", "--from", from, "--to", to], repoPath);
  }

  /**
   * Get a list of file paths changed between two revisions.
   * Uses `jj diff --summary --from <from> --to <to>` and extracts filenames.
   * Returns an empty array if no files changed or revisions do not exist.
   */
  async getChangedFiles(repoPath: string, from: string, to: string): Promise<string[]> {
    try {
      const out = await this.jj(
        ["diff", "--summary", "--from", from, "--to", to],
        repoPath,
      );
      if (!out) return [];
      return out
        .split("\n")
        .map((l) => l.replace(/^[MA?D]\s+/, "").trim())
        .filter(Boolean);
    } catch {
      return [];
    }
  }

  /**
   * Get the commit timestamp for a given ref (bookmark).
   * Returns a Unix timestamp in seconds, or null if not found.
   */
  async getRefCommitTimestamp(repoPath: string, ref: string): Promise<number | null> {
    try {
      const out = await this.jj(
        ["log", "-r", ref, "--no-graph", "-T", "author.timestamp().utc().unix()"],
        repoPath,
      );
      const ts = parseInt(out.trim(), 10);
      if (isNaN(ts)) return null;
      return ts;
    } catch {
      return null;
    }
  }

  /**
   * List modified files in the current revision.
   */
  async getModifiedFiles(workspacePath: string): Promise<string[]> {
    const out = await this.jj(
      ["diff", "--summary", "-r", "@"],
      workspacePath,
    );
    return out
      .split("\n")
      .map((l) => l.replace(/^[MA?D]\s+/, "").trim())
      .filter(Boolean);
  }

  /**
   * List files with conflicts in the current revision.
   * jj marks conflict files with a `C` prefix in `jj resolve --list`.
   */
  async getConflictingFiles(workspacePath: string): Promise<string[]> {
    try {
      const out = await this.jj(["resolve", "--list"], workspacePath);
      return out
        .split("\n")
        .map((l) => l.trim())
        .filter(Boolean);
    } catch {
      return [];
    }
  }

  /**
   * Get working status (jj status output).
   */
  async status(workspacePath: string): Promise<string> {
    return this.jj(["status"], workspacePath);
  }

  /**
   * Restore all files to their state in the parent revision and remove untracked files.
   *
   * Equivalent to `git checkout -- . && git clean -fd` — restores tracked files
   * to parent-revision state AND removes any new untracked files from the working tree.
   */
  async cleanWorkingTree(workspacePath: string): Promise<void> {
    // Restore tracked files to parent-revision state
    await this.jj(["restore"], workspacePath);

    // Remove untracked files by abandoning the current change and starting fresh.
    // `jj abandon --ignore-immutable` discards the current working-copy change
    // and all its pending changes (tracked + untracked), leaving a clean state.
    // We do this via jj git reset equivalent: restore is sufficient for tracked files,
    // but we also need to remove files added in the current change that aren't in parent.
    // Use `jj diff --summary -r @` to find added files and remove them.
    try {
      const diffOut = await this.jj(["diff", "--summary", "-r", "@"], workspacePath);
      if (diffOut) {
        const addedFiles = diffOut
          .split("\n")
          .filter((l) => l.startsWith("A "))
          .map((l) => l.replace(/^A\s+/, "").trim())
          .filter(Boolean);

        for (const file of addedFiles) {
          try {
            await fs.rm(join(workspacePath, file), { force: true, recursive: false });
          } catch {
            // best effort — file may have already been removed
          }
        }
      }
    } catch {
      // best effort — diff failure should not block the restore
    }
  }

  // ── Finalize Support ─────────────────────────────────────────────────

  /**
   * Return pre-computed jj finalize commands for prompt rendering.
   */
  getFinalizeCommands(vars: FinalizeTemplateVars): FinalizeCommands {
    const { seedId, seedTitle, baseBranch } = vars;
    return {
      stageCommand: "", // jj auto-stages
      commitCommand: `jj describe -m "${seedTitle} (${seedId})" && jj new`,
      pushCommand: `jj git push --bookmark foreman/${seedId} --allow-new`,
      rebaseCommand: `jj git fetch && jj rebase -d ${baseBranch}@origin`,
      branchVerifyCommand: `jj bookmark list foreman/${seedId}`,
      cleanCommand: `jj workspace forget foreman-${seedId}`,
    };
  }
}
