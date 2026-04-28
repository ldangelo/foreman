/**
 * JujutsuBackend — Jujutsu (jj) VCS backend implementation.
 *
 * Implements the `VcsBackend` interface using the `jj` CLI.
 * Supports Jujutsu repositories in both colocated and non-colocated layouts.
 *
 * Key differences from GitBackend:
 * - Workspaces use `jj workspace add` / `jj workspace forget`.
 * - Branches are called "bookmarks" in jj (`jj bookmark`).
 * - Staging is automatic — `stageAll()` is a no-op.
 * - Commits use `jj describe -m` (no trailing `jj new`).
 * - Push requires `--allow-new` for first push of a new bookmark.
 * - Rebase uses `jj rebase -d <destination>`.
 *
 * @module src/lib/vcs/jujutsu-backend
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";
import fs from "node:fs/promises";
import { dirname, join, relative as pathRelative } from "node:path";

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
  buildTrackedStateRestoreCommand,
  getWorkspacePath,
  getWorkspaceRoot,
} from "../workspace-paths.js";
import { normalizeBranchLabel } from "../branch-label.js";
import type { VcsBackend } from "./interface.js";

const execFileAsync = promisify(execFile);

/**
 * JujutsuBackend encapsulates jj-specific VCS operations for a Foreman project.
 *
 * Foreman prefers colocated jj repositories when git-native tooling is needed,
 * but repository introspection should also work for non-colocated jj repos.
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
      const home = process.env.HOME ?? "/home/nobody";
      const { stdout } = await execFileAsync("jj", args, {
        cwd,
        maxBuffer: 10 * 1024 * 1024,
        timeout: 60_000,
        env: {
          ...process.env,
          PATH: `${home}/.local/bin:/opt/homebrew/bin:${process.env.PATH ?? ""}`,
        },
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
   * Used for operations that still need git metadata when it exists.
   */
  private async git(args: string[], cwd: string): Promise<string> {
    try {
      const { stdout } = await execFileAsync("git", args, {
        cwd,
        maxBuffer: 10 * 1024 * 1024,
        timeout: 60_000,
        env: {
          ...process.env,
          GIT_EDITOR: "true",
          GIT_TERMINAL_PROMPT: "0",
          GIT_ASKPASS: "true",
        },
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
   * Uses `jj root`, which works in both colocated and non-colocated repos.
   */
  async getRepoRoot(path: string): Promise<string> {
    return this.jj(["root"], path);
  }

  /**
   * Find the main (primary) repository root from any workspace.
   * For jj this is the same as the workspace root regardless of repository layout.
   */
  async getMainRepoRoot(path: string): Promise<string> {
    return this.getRepoRoot(path);
  }

  /**
   * Detect the default/trunk branch for the repository.
   *
   * Resolution order:
   * 1. Respect `git-town.main-branch` when configured.
   * 2. Respect `origin/HEAD` when available.
   * 3. Look for a `main` bookmark.
   * 4. Look for a `master` bookmark.
   * 5. Look for a `dev` bookmark.
   * 6. Fall back to the current bookmark.
   */
  async detectDefaultBranch(repoPath: string): Promise<string> {
    // 1. Respect git-town.main-branch config (user's explicit development trunk)
    try {
      const gtMain = await this.git(["config", "get", "git-town.main-branch"], repoPath);
      if (gtMain) return gtMain;
    } catch {
      // git-town not configured or command unavailable — fall through
    }

    // 2. Try origin/HEAD symbolic ref from colocated git metadata
    try {
      const ref = await this.git(["symbolic-ref", "refs/remotes/origin/HEAD", "--short"], repoPath);
      if (ref) {
        return ref.replace(/^origin\//, "");
      }
    } catch {
      // origin/HEAD not set or no remote — fall through
    }

    // 3. Check for 'main' bookmark
    try {
      const out = await this.jj(["bookmark", "list", "main"], repoPath);
      if (out.includes("main")) return "main";
    } catch {
      // not found
    }

    // 4. Check for 'master' bookmark
    try {
      const out = await this.jj(["bookmark", "list", "master"], repoPath);
      if (out.includes("master")) return "master";
    } catch {
      // not found
    }

    // 5. Check for 'dev' bookmark
    try {
      const out = await this.jj(["bookmark", "list", "dev"], repoPath);
      if (out.includes("dev")) return "dev";
    } catch {
      // not found
    }

    // 6. Fall back to current branch
    return this.getCurrentBranch(repoPath);
  }

  private async getBookmarksAtRevision(repoPath: string, rev: string): Promise<string[]> {
    try {
      const bookmarks = await this.jj(
        ["log", "--no-graph", "-r", rev, "-T", "separate(' ', bookmarks)"],
        repoPath,
      );
      return bookmarks
        .split(" ")
        .map((bookmark) => normalizeBranchLabel(bookmark))
        .filter((bookmark): bookmark is string => Boolean(bookmark));
    } catch {
      return [];
    }
  }

  /**
   * Get the name of the currently active bookmark.
   * Uses `jj log --no-graph -r @ -T 'bookmarks'` to find the current bookmark.
   * If the working copy is an unbookmarked child revision, falls back to the
   * parent revision's bookmark before finally falling back to the short change ID.
   */
  async getCurrentBranch(repoPath: string): Promise<string> {
    const bookmarks = await this.getBookmarksAtRevision(repoPath, "@");
    if (bookmarks.length > 0) {
      return bookmarks[0];
    }

    const parentBookmarks = await this.getBookmarksAtRevision(repoPath, "@-");
    if (parentBookmarks.length > 0) {
      return parentBookmarks[0];
    }

    // Fall back to short change ID
    return this.jj(["log", "--no-graph", "-r", "@", "-T", "change_id.short()"], repoPath);
  }

  /**
   * Get the URL of a remote by name.
   * For jujutsu, this delegates to the underlying git repository.
   */
  async getRemoteUrl(repoPath: string, remote = "origin"): Promise<string | null> {
    try {
      const { execFile: gitExec } = await import("node:child_process");
      const { promisify } = await import("node:util");
      const execFileAsync = promisify(gitExec);
      return (await execFileAsync("git", ["ls-remote", "--get-url", remote], {
        cwd: repoPath,
        timeout: 5000,
      })).stdout.trim();
    } catch {
      return null;
    }
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
 * Creates a workspace in Foreman's external workspace root and sets up
 * a bookmark `foreman/<seedId>` pointing to the new workspace's revision.
 * When `baseBranch` is provided, the new workspace is created directly from
 * that branch/revision instead of inheriting the controller workspace parent.
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
    const workspacePath = getWorkspacePath(repoPath, seedId);

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
    const worktreesDir = getWorkspaceRoot(repoPath);
    await fs.mkdir(worktreesDir, { recursive: true });
    await fs.mkdir(dirname(workspacePath), { recursive: true });

    // Create new workspace pinned to the requested base. Without --revision,
    // JJ creates the new workspace on top of the parent(s) of the current
    // working-copy commit, which can accidentally inherit unrelated local
    // controller changes.
    try {
      await this.jj(
        [
          "workspace",
          "add",
          "--name",
          `foreman-${seedId}`,
          "--revision",
          base,
          workspacePath,
        ],
        repoPath,
      );
    } catch (err: unknown) {
      const msg = (err as Error).message ?? "";
      if (msg.includes("already exists")) {
        // Workspace registered in jj but directory missing (stale metadata from
        // a previous run that was cleaned up). Forget and recreate.
        if (!existsSync(workspacePath)) {
          await this.jj(["workspace", "forget", `foreman-${seedId}`], repoPath);
          await this.jj(
            [
              "workspace",
              "add",
              "--name",
              `foreman-${seedId}`,
              "--revision",
              base,
              workspacePath,
            ],
            repoPath,
          );
        }
      } else {
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
          ["bookmark", "move", branchName, "--allow-backwards", "--to", workspaceRef],
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
            const path = getWorkspacePath(repoPath, seedId);
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
   *
   * Does NOT call `jj new` afterwards. The `jj new` convention is for
   * interactive workflows where the user wants a fresh working revision.
   * In Foreman's agent pipeline, each workspace commits once and pushes;
   * the extra `jj new` would create an empty revision that gets exported
   * as an empty git commit and pollutes the branch history.
   */
  async commit(workspacePath: string, message: string): Promise<void> {
    await this.jj(["describe", "-m", message], workspacePath);
  }

  /**
   * Commit with auto-generated message.
   * Jujutsu always uses auto-messages, so this uses a default message.
   */
  async commitNoEdit(workspacePath: string): Promise<void> {
    await this.jj(["describe", "-m", "Auto-merge commit"], workspacePath);
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

  async saveWorktreeState(_workspacePath: string): Promise<boolean> {
    return false;
  }

  async restoreWorktreeState(_workspacePath: string): Promise<void> {
    return;
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

  async rebaseBranch(
    repoPath: string,
    branchName: string,
    onto: string,
  ): Promise<RebaseResult> {
    try {
      await this.jj(["rebase", "-b", branchName, "-d", onto], repoPath);
      let conflictingFiles: string[] = [];
      try {
        conflictingFiles = await this.getConflictingFiles(repoPath);
      } catch {
        // best effort
      }
      if (conflictingFiles.length > 0) {
        return { success: false, hasConflicts: true, conflictingFiles };
      }
      return { success: true, hasConflicts: false };
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      let conflictingFiles: string[] = [];
      try {
        conflictingFiles = await this.getConflictingFiles(repoPath);
      } catch {
        // best effort
      }
      if (msg.includes("conflict") || msg.includes("Conflict") || conflictingFiles.length > 0) {
        return { success: false, hasConflicts: true, conflictingFiles };
      }
      throw err;
    }
  }

  async restackBranch(
    repoPath: string,
    branchName: string,
    _oldBase: string,
    newBase: string,
  ): Promise<RebaseResult> {
    return this.rebaseBranch(repoPath, branchName, newBase);
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

  async mergeWithStrategy(
    repoPath: string,
    sourceBranch: string,
    targetBranch: string,
    strategy: "theirs",
  ): Promise<MergeResult> {
    try {
      await this.git(["checkout", targetBranch], repoPath);
      await this.git(["merge", sourceBranch, "--no-ff", "-X", strategy], repoPath);
      return { success: true };
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      let conflictingFiles: string[] = [];
      try {
        conflictingFiles = await this.getConflictingFiles(repoPath);
      } catch {
        // best effort
      }
      if (message.includes("conflict") || message.includes("Conflict") || conflictingFiles.length > 0) {
        return { success: false, conflicts: conflictingFiles };
      }
      throw err;
    }
  }

  async rollbackFailedMerge(workspacePath: string, beforeRef: string): Promise<void> {
    await this.resetHard(workspacePath, beforeRef);
  }

  // ── Diff, Status and Conflict Detection ─────────────────────────────

  /**
   * Get the current change ID (jj's equivalent of a commit hash).
   * When the working copy is an unbookmarked empty child revision, prefer the
   * parent revision's change ID so callers reason about the effective branch tip
   * rather than the ephemeral scratch commit jj may create on top.
   */
  async getHeadId(workspacePath: string): Promise<string> {
    const currentBookmarks = await this.getBookmarksAtRevision(workspacePath, "@");
    if (currentBookmarks.length > 0) {
      return this.jj(
        ["log", "--no-graph", "-r", "@", "-T", "change_id.short()"],
        workspacePath,
      );
    }

    const parentBookmarks = await this.getBookmarksAtRevision(workspacePath, "@-");
    if (parentBookmarks.length > 0) {
      return this.jj(
        ["log", "--no-graph", "-r", "@-", "-T", "change_id.short()"],
        workspacePath,
      );
    }

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

  async isAncestor(repoPath: string, ancestorRef: string, descendantRef: string): Promise<boolean> {
    try {
      const ancestorCommit = await this.resolveRef(repoPath, ancestorRef);
      const reachable = await this.jj(
        ["log", "--no-graph", "-r", `${ancestorRef}::${descendantRef}`, "-T", "commit_id"],
        repoPath,
      );
      return reachable.split("\n").map((line) => line.trim()).includes(ancestorCommit.trim());
    } catch {
      return false;
    }
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

  // ── Conflict Resolution Operations ───────────────────────────────────

  /**
   * Merge without auto-committing.
   * Jujutsu always auto-commits merges, so this delegates to `merge()`.
   * The conflict detection behavior is the same; the difference in commit
   * behavior is a jujutsu limitation for this interface method.
   */
  async mergeWithoutCommit(
    repoPath: string,
    sourceBranch: string,
    targetBranch: string,
  ): Promise<MergeResult> {
    return this.merge(repoPath, sourceBranch, targetBranch);
  }

  /**
   * Abort an in-progress merge.
   * Jujutsu doesn't track merge state the same way as git.
   * Uses `jj op restore @-` to restore to the pre-merge working copy state.
   */
  async abortMerge(workspacePath: string): Promise<void> {
    // Restore to the working copy parent (pre-merge state)
    try {
      await this.jj(["op", "restore", "@-"], workspacePath);
    } catch {
      // Best effort — if there's no merge to abort, this will fail silently
    }
  }

  /**
   * Stage a specific file.
   * Jujutsu auto-stages all changes, so this is a no-op.
   */
  async stageFile(_workspacePath: string, _filePath: string): Promise<void> {
    // jj auto-stages — nothing to do
  }

  async stageFiles(_workspacePath: string, _filePaths: string[]): Promise<void> {
    // jj auto-stages — nothing to do
  }

  /**
   * Checkout a file from a specific ref into the working tree.
   * Uses `jj file show <ref> -- <path>` written to the working copy.
   * The special ref "--theirs" during rebase resolves to the "other" parent.
   */
  async checkoutFile(
    workspacePath: string,
    ref: string,
    filePath: string,
  ): Promise<void> {
    // Handle "--theirs" in rebase context — map to the appropriate jj revision
    if (ref === "--theirs") {
      // In a rebase, @- is the original (@ before rebase), @@ is the rebased version
      // During rebase, "theirs" (the branch being rebased) is @+ or we use @-
      // which is the parent commit we rebased onto. Use jj log to determine.
      try {
        const content = await this.jj(
          ["file show", "@-", "--", filePath],
          workspacePath,
        );
        await fs.writeFile(join(workspacePath, filePath), content, "utf-8");
      } catch {
        // Best effort — file may not exist on that side
      }
      return;
    }

    // Normal ref checkout
    const content = await this.jj(
      ["file", "show", ref, "--", filePath],
      workspacePath,
    );
    await fs.writeFile(join(workspacePath, filePath), content, "utf-8");
  }

  /**
   * Get the content of a file at a specific ref.
   */
  async showFile(
    repoPath: string,
    ref: string,
    filePath: string,
  ): Promise<string> {
    // Handle "branch:path" format
    const colonIdx = ref.indexOf(":");
    if (colonIdx !== -1) {
      const branch = ref.slice(0, colonIdx);
      const path = ref.slice(colonIdx + 1);
      return this.jj(["file", "show", branch, "--", path], repoPath);
    }
    return this.jj(["file", "show", ref, "--", filePath], repoPath);
  }

  /**
   * Reset the working tree to a specific ref (hard reset).
   * Jujutsu equivalent: restore all files to the target revision.
   */
  async resetHard(workspacePath: string, ref: string): Promise<void> {
    await this.jj(["restore", "--to", ref], workspacePath);
  }

  /**
   * Remove a tracked file from the repository.
   */
  async removeFile(workspacePath: string, filePath: string): Promise<void> {
    await this.jj(["file", "rm", filePath], workspacePath);
  }

  /**
   * Continue an in-progress rebase after resolving conflicts.
   */
  async rebaseContinue(workspacePath: string): Promise<void> {
    await this.jj(["rebase", "--continue"], workspacePath);
  }

  /**
   * Remove a file from the staging area.
   * Jujutsu doesn't have a separate index, so this is a no-op.
   */
  async removeFromIndex(_workspacePath: string, _filePath: string): Promise<void> {
    // jj has no separate index — nothing to do
  }

  /**
   * Apply a patch file via colocated git metadata.
   */
  async applyPatchToIndex(workspacePath: string, patchFilePath: string): Promise<void> {
    await this.git(["apply", "--index", patchFilePath], workspacePath);
  }

  /**
   * Get the merge base of two refs.
   * Uses jj's parent traversal to find the common ancestor.
   */
  async getMergeBase(repoPath: string, ref1: string, ref2: string): Promise<string> {
    try {
      // Get parents of ref1
      const parents1 = await this.jj(
        ["log", "-r", ref1, "--no-graph", "-T", "parents"],
        repoPath,
      );
      // Check if any parent of ref1 is an ancestor of ref2
      for (const parent of parents1.split(" ").filter(Boolean)) {
        try {
          // Use jj's ancestor check: if merge-base between parent and ref2 equals parent, it's the base
          const base = await this.jj(
            ["log", "-r", `(${parent}) && (${ref2})`, "--no-graph", "-T", "change_id"],
            repoPath,
          );
          if (base.trim()) {
            return parent;
          }
        } catch {
          // This parent is not the merge base
        }
      }
      return "";
    } catch {
      return "";
    }
  }

  /**
   * List untracked files in the working tree.
   * For jj, untracked files are files that exist in the working tree but are
   * not part of the current revision's tree. We compare the working tree
   * contents against what jj knows about.
   */
  async getUntrackedFiles(workspacePath: string): Promise<string[]> {
    try {
      // Recursively collect all file paths in the working tree
      const allPaths: string[] = [];
      const collectFiles = async (dir: string): Promise<void> => {
        const entries = await fs.readdir(dir, { withFileTypes: true });
        for (const entry of entries) {
          const fullPath = join(dir, entry.name);
          if (entry.isFile()) {
            allPaths.push(pathRelative(workspacePath, fullPath));
          } else if (entry.isDirectory() && entry.name !== '.git' && entry.name !== '.jj') {
            await collectFiles(fullPath);
          }
        }
      };
      await collectFiles(workspacePath);

      // Get files tracked in the current revision
      const trackedOut = await this.jj(
        ["files", "--rev", "@"],
        workspacePath,
      );
      const trackedFiles = new Set(
        trackedOut.split("\n").map((f) => f.trim()).filter(Boolean),
      );

      // Untracked = files in working tree but not in tracked set
      return allPaths.filter((f) => !trackedFiles.has(f));
    } catch {
      return [];
    }
  }

  // ── Finalize Support ─────────────────────────────────────────────────

  /**
   * Return pre-computed jj finalize commands for prompt rendering.
   */
  getFinalizeCommands(vars: FinalizeTemplateVars): FinalizeCommands {
    const { seedId, seedTitle, baseBranch, worktreePath, githubIssueNumber } = vars;
    // Escape single quotes so the shell-level single-quoted commit message is
    // safe even when seedTitle contains apostrophes or shell-special characters.
    const safeSeedTitle = seedTitle.replace(/'/g, "'\\''");
    const footerSuffix = githubIssueNumber
      ? `\\n\\nFixes #${githubIssueNumber}`
      : "";
    return {
      stageCommand: "", // jj auto-stages
      commitCommand: `jj describe -m '${safeSeedTitle} (${seedId})${footerSuffix}'`,
      pushCommand: `jj git push --bookmark foreman/${seedId} --allow-new`,
      integrateTargetCommand: `jj git fetch && jj rebase -d ${baseBranch}@origin`,
      branchVerifyCommand: `jj bookmark list foreman/${seedId}`,
      cleanCommand: `jj workspace forget foreman-${seedId}`,
      restoreTrackedStateCommand: buildTrackedStateRestoreCommand(worktreePath, this.projectPath),
    };
  }
}
