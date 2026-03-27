/**
 * JujutsuBackend — Full Jujutsu (jj) VCS backend implementation.
 *
 * Phase D: Implements all 39 methods of the VcsBackend interface for
 * Jujutsu repositories backed by git (the common case for Foreman usage).
 *
 * Key jj semantics:
 * - Bookmarks replace git branches (same concept, different name)
 * - Changes (@ = working copy) replace commits; @- is the parent
 * - Auto-tracking: jj tracks all file changes; no explicit staging
 * - Workspaces share a single .jj/repo directory
 * - jj git push --bookmark --allow-new pushes to git-backed remotes
 *
 * @module src/lib/vcs/jujutsu-backend
 */

import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { existsSync, readFileSync, mkdirSync } from 'node:fs';
import { rm } from 'node:fs/promises';
import { join, resolve as resolvePath, dirname } from 'node:path';
import type { VcsBackend } from './backend.js';
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
} from './types.js';

const execFileAsync = promisify(execFile);

// ── Proto-binary parser for workspace_store/index ───────────────────────────

/**
 * Read a protobuf varint from a buffer starting at `offset`.
 * Returns [value, nextOffset].
 */
function readVarint(buf: Buffer, offset: number): [number, number] {
  let result = 0;
  let shift = 0;
  let pos = offset;
  while (pos < buf.length) {
    const byte = buf[pos++];
    result |= (byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) break;
    shift += 7;
  }
  return [result, pos];
}

/**
 * Parse jj's workspace_store/index binary (protobuf) to extract workspace paths.
 *
 * Format: repeated WorkspaceEntry { string name = 1; string path = 2; }
 * Paths are relative to the .jj/repo directory of the main repository.
 *
 * @param indexBuffer - raw contents of workspace_store/index
 * @param jjRepoPath  - absolute path to .jj/repo (for path resolution)
 */
function parseWorkspaceStoreIndex(
  indexBuffer: Buffer,
  jjRepoPath: string,
): Array<{ name: string; path: string }> {
  const results: Array<{ name: string; path: string }> = [];
  let offset = 0;

  while (offset < indexBuffer.length) {
    // Read outer field tag (should be field 1, wire type 2 = 0x0a)
    let outerTag: number;
    [outerTag, offset] = readVarint(indexBuffer, offset);
    if (offset >= indexBuffer.length) break;
    if ((outerTag & 0x7) !== 2) break; // not length-delimited

    // Read outer entry length
    let outerLen: number;
    [outerLen, offset] = readVarint(indexBuffer, offset);
    const entryEnd = offset + outerLen;

    let name = '';
    let relPath = '';

    // Parse inner fields (name + path)
    while (offset < entryEnd) {
      let innerTag: number;
      [innerTag, offset] = readVarint(indexBuffer, offset);
      if (offset >= entryEnd) break;

      let innerLen: number;
      [innerLen, offset] = readVarint(indexBuffer, offset);
      if (offset + innerLen > indexBuffer.length) break;

      const value = indexBuffer.slice(offset, offset + innerLen).toString('utf8');
      offset += innerLen;

      const fieldNum = innerTag >> 3;
      if (fieldNum === 1) name = value;
      if (fieldNum === 2) relPath = value;
    }

    // Ensure offset is at the end of the entry
    offset = entryEnd;

    if (name && relPath) {
      const absolutePath = resolvePath(jjRepoPath, relPath);
      results.push({ name, path: absolutePath });
    }
  }

  return results;
}

// ── JujutsuBackend ───────────────────────────────────────────────────────────

/**
 * JujutsuBackend encapsulates jj-specific VCS operations for a given project path.
 *
 * Constructor receives the project root path; all methods operate relative to it
 * unless given an explicit path argument (for workspace-aware operations).
 *
 * Targets git-backed jj repositories (created via `jj git init` or `jj git clone`).
 * Pure jj-native repos without a git backing store are not supported in Phase D.
 */
export class JujutsuBackend implements VcsBackend {
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
      const { stdout } = await execFileAsync('jj', args, {
        cwd,
        maxBuffer: 10 * 1024 * 1024,
        env: {
          ...process.env,
          // Force color off for deterministic parsing
          NO_COLOR: '1',
          JJ_NO_PAGER: '1',
        },
      });
      return stdout.trim();
    } catch (err: unknown) {
      const nodeErr = err as NodeJS.ErrnoException & {
        stdout?: string;
        stderr?: string;
        message?: string;
      };
      // Detect "command not found" (ENOENT)
      if (nodeErr.code === 'ENOENT') {
        throw new Error(
          'jj (Jujutsu) CLI not found. Please install jj: https://github.com/martinvonz/jj/releases',
        );
      }
      const combined =
        [nodeErr.stdout, nodeErr.stderr]
          .map((s) => (s ?? '').trim())
          .filter(Boolean)
          .join('\n') || nodeErr.message || String(err);
      throw new Error(`jj ${args[0]} failed: ${combined}`);
    }
  }

  // ── Repository Introspection ─────────────────────────────────────────

  /**
   * Find the root of the jj workspace containing `path`.
   * Uses `jj root` which returns the workspace working directory root.
   */
  async getRepoRoot(path: string): Promise<string> {
    return this.jj(['root'], path);
  }

  /**
   * Find the main (primary) repository root.
   *
   * For jj, all workspaces share a single `.jj/repo` directory —
   * `jj root` returns the workspace root, which IS the repo root for jj.
   * This is equivalent to `getRepoRoot` for jj backends.
   */
  async getMainRepoRoot(path: string): Promise<string> {
    return this.jj(['root'], path);
  }

  /**
   * Detect the default development branch / bookmark.
   *
   * Resolution order:
   * 1. Check for 'main' bookmark
   * 2. Check for 'master' bookmark
   * 3. Check for 'trunk' bookmark (common jj convention)
   * 4. Fall back to `getCurrentBranch()`
   */
  async detectDefaultBranch(repoPath: string): Promise<string> {
    for (const candidate of ['main', 'master', 'trunk']) {
      try {
        const names = await this.jj(
          ['bookmark', 'list', '-T', 'name ++ "\\n"'],
          repoPath,
        );
        if (
          names
            .split('\n')
            .map((n) => n.trim())
            .includes(candidate)
        ) {
          return candidate;
        }
      } catch {
        // fall through
      }
    }

    return this.getCurrentBranch(repoPath);
  }

  /**
   * Get the name of the current bookmark (or a synthetic change-based name).
   *
   * First checks for bookmarks pointing to the working copy (@).
   * If no bookmarks exist on @, returns "change-<short-id>".
   */
  async getCurrentBranch(repoPath: string): Promise<string> {
    // Get bookmarks on the working copy change
    try {
      const output = await this.jj(
        ['bookmark', 'list', '--revisions', '@', '-T', 'name ++ "\\n"'],
        repoPath,
      );
      const names = output
        .split('\n')
        .map((n) => n.trim())
        .filter(Boolean);
      if (names.length > 0) return names[0];
    } catch {
      // fall through
    }

    // No bookmark on @ — return synthetic "change-<id>"
    try {
      const changeId = await this.jj(
        ['log', '--no-graph', '-T', 'change_id.shortest(8)', '-r', '@'],
        repoPath,
      );
      if (changeId) return `change-${changeId.trim()}`;
    } catch {
      // fall through
    }

    return 'HEAD';
  }

  // ── Branch / Bookmark Operations ─────────────────────────────────────

  /**
   * Checkout an existing bookmark or create it if it does not exist.
   *
   * For existing bookmarks: creates a new child change on top of the bookmark.
   * For new bookmarks: creates a new change and sets the bookmark to point to it.
   */
  async checkoutBranch(repoPath: string, branchName: string): Promise<void> {
    const exists = await this.branchExists(repoPath, branchName);
    if (exists) {
      // Create a new child change on top of the bookmark
      await this.jj(['new', branchName], repoPath);
    } else {
      // Create a new empty change, then create the bookmark
      await this.jj(['new'], repoPath);
      await this.jj(['bookmark', 'create', branchName, '-r', '@'], repoPath);
    }
  }

  /**
   * Check whether a local bookmark exists.
   */
  async branchExists(repoPath: string, branchName: string): Promise<boolean> {
    try {
      const names = await this.jj(
        ['bookmark', 'list', '-T', 'name ++ "\\n"'],
        repoPath,
      );
      return names
        .split('\n')
        .map((n) => n.trim())
        .includes(branchName);
    } catch {
      return false;
    }
  }

  /**
   * Check whether a bookmark exists on the remote (origin).
   *
   * Uses `jj bookmark list --all-remotes` and looks for remote-tracking entries.
   * Remote bookmarks appear as "bookmarkname@origin" in the name template output.
   */
  async branchExistsOnRemote(repoPath: string, branchName: string): Promise<boolean> {
    try {
      // -a / --all-remotes includes remote-tracking bookmarks
      const output = await this.jj(
        ['bookmark', 'list', '-a', '-T', 'name ++ "\\n"'],
        repoPath,
      );
      // Remote bookmarks appear as "bookmarkname@origin" — local bookmarks appear as just "bookmarkname"
      // Only match the @origin form to distinguish remote from local
      return output
        .split('\n')
        .map((n) => n.trim())
        .some((n) => n === `${branchName}@origin`);
    } catch {
      return false;
    }
  }

  /**
   * Delete a local bookmark.
   *
   * Checks whether the bookmark is an ancestor of the target branch to determine
   * `wasFullyMerged`. Always deletes (no force-only variant in jj).
   */
  async deleteBranch(
    repoPath: string,
    branchName: string,
    opts?: DeleteBranchOptions,
  ): Promise<DeleteBranchResult> {
    const exists = await this.branchExists(repoPath, branchName);
    if (!exists) {
      return { deleted: false, wasFullyMerged: false };
    }

    const targetBranch =
      opts?.targetBranch ?? (await this.detectDefaultBranch(repoPath));
    let wasFullyMerged = false;

    // Check if branchName is an ancestor of targetBranch (i.e., fully merged)
    try {
      const result = await this.jj(
        [
          'log',
          '--no-graph',
          '-T',
          'change_id',
          '-r',
          `ancestors(${targetBranch}) & ${branchName}`,
        ],
        repoPath,
      );
      wasFullyMerged = result.trim().length > 0;
    } catch {
      // Can't determine merge status — assume not merged
    }

    await this.jj(['bookmark', 'delete', branchName], repoPath);
    return { deleted: true, wasFullyMerged };
  }

  // ── Workspace Management ──────────────────────────────────────────────

  /**
   * Create an isolated jj workspace for a task at `.foreman-worktrees/<seedId>`.
   *
   * If the workspace already exists, rebases it onto `baseBranch` and returns.
   * Creates a new bookmark `foreman/<seedId>` pointing to the workspace's working copy.
   *
   * @param repoPath   - absolute path to the main repository root
   * @param seedId     - unique identifier for the task
   * @param baseBranch - the branch to base from (defaults to default branch)
   * @param setupSteps - optional shell commands to run after creation
   */
  async createWorkspace(
    repoPath: string,
    seedId: string,
    baseBranch?: string,
    setupSteps?: string[],
    _setupCache?: string,
  ): Promise<WorkspaceResult> {
    const workspaceName = `foreman-${seedId}`;
    const workspacePath = join(repoPath, '.foreman-worktrees', seedId);
    const branchName = `foreman/${seedId}`;

    // Check if workspace already exists
    const existingWorkspaces = await this.listWorkspaces(repoPath);
    const existing = existingWorkspaces.find(
      (ws) => ws.path === workspacePath || ws.branch === workspaceName,
    );

    if (existing) {
      // Workspace exists — try to update stale and rebase
      const base = baseBranch ?? (await this.detectDefaultBranch(repoPath));
      try {
        await this.jj(['workspace', 'update-stale'], repoPath);
      } catch {
        // Non-fatal — workspace may be current
      }
      try {
        await this.jj(['rebase', '-d', `${base}@origin`], workspacePath);
      } catch {
        // Non-fatal — may not have remote or no rebase needed
      }
      return { workspacePath, branchName };
    }

    // Determine base branch
    const base = baseBranch ?? (await this.detectDefaultBranch(repoPath));

    // Ensure the parent directory exists (jj workspace add creates the workspace dir itself)
    mkdirSync(dirname(workspacePath), { recursive: true });

    // Create the workspace at the target path
    await this.jj(
      ['workspace', 'add', workspacePath, '--name', workspaceName],
      repoPath,
    );

    // Create bookmark pointing to the workspace's working copy
    try {
      await this.jj(
        ['bookmark', 'create', branchName, '-r', `${workspaceName}@`],
        repoPath,
      );
    } catch {
      // Bookmark may already exist — try set instead
      await this.jj(
        ['bookmark', 'set', branchName, '-r', `${workspaceName}@`],
        repoPath,
      );
    }

    // Rebase onto the base branch if it exists
    try {
      await this.jj(['rebase', '-d', base], workspacePath);
    } catch {
      // Base branch may not exist yet — that's ok for new repos
    }

    // Run optional setup steps
    if (setupSteps && setupSteps.length > 0) {
      const { exec } = await import('node:child_process');
      const { promisify: prom } = await import('node:util');
      const execAsync = prom(exec);
      for (const step of setupSteps) {
        await execAsync(step, { cwd: workspacePath });
      }
    }

    return { workspacePath, branchName };
  }

  /**
   * Remove a jj workspace: forgets it from jj tracking and deletes the directory.
   */
  async removeWorkspace(repoPath: string, workspacePath: string): Promise<void> {
    // Find the workspace name from the path
    const workspaces = await this.listWorkspaces(repoPath);
    const ws = workspaces.find((w) => w.path === workspacePath);

    if (ws) {
      try {
        await this.jj(['workspace', 'forget', ws.branch], repoPath);
      } catch {
        // Workspace may already be forgotten — continue to directory cleanup
      }
    }

    // Remove the directory
    if (existsSync(workspacePath)) {
      await rm(workspacePath, { recursive: true, force: true });
    }
  }

  /**
   * List all jj workspaces associated with the repository.
   *
   * Parses the binary `.jj/repo/workspace_store/index` file (protobuf) to extract
   * workspace names and paths. Falls back to empty array on parse errors.
   */
  async listWorkspaces(repoPath: string): Promise<Workspace[]> {
    const jjRepoPath = join(repoPath, '.jj', 'repo');
    const indexPath = join(jjRepoPath, 'workspace_store', 'index');

    if (!existsSync(indexPath)) {
      return [];
    }

    try {
      const indexBuffer = readFileSync(indexPath);
      const wsEntries = parseWorkspaceStoreIndex(indexBuffer, jjRepoPath);

      const workspaces: Workspace[] = [];
      for (const entry of wsEntries) {
        let head = '';
        try {
          head = await this.jj(
            ['log', '--no-graph', '-T', 'change_id', '-r', `${entry.name}@`],
            repoPath,
          );
        } catch {
          // Workspace might be stale
        }

        workspaces.push({
          path: entry.path,
          branch: entry.name,
          head: head.trim(),
          bare: false,
        });
      }

      return workspaces;
    } catch {
      return [];
    }
  }

  // ── Commit & Sync ─────────────────────────────────────────────────────

  /**
   * Stage all changes — no-op for jj (auto-tracks all file changes).
   */
  async stageAll(_workspacePath: string): Promise<void> {
    // jj automatically tracks all file changes — no staging step needed
  }

  /**
   * Commit staged changes by describing the current change and creating a new child.
   *
   * Returns the change ID of the described (committed) change.
   */
  async commit(workspacePath: string, message: string): Promise<string> {
    // Describe the current working copy change with the commit message
    await this.jj(['describe', '-m', message], workspacePath);
    // Create a new empty child change (making the previous one "committed")
    await this.jj(['new'], workspacePath);
    // Return the change ID of the committed change (now the parent of @)
    return this.jj(
      ['log', '--no-graph', '-T', 'change_id', '-r', '@-'],
      workspacePath,
    );
  }

  /**
   * Get the current HEAD change ID.
   *
   * Returns the change ID of the parent change (@-), which is the last
   * "committed" change. If no parent exists, returns the current change ID.
   */
  async getHeadId(workspacePath: string): Promise<string> {
    try {
      return await this.jj(
        ['log', '--no-graph', '-T', 'change_id', '-r', '@-'],
        workspacePath,
      );
    } catch {
      // No parent (empty repo) — return current change ID
      return this.jj(
        ['log', '--no-graph', '-T', 'change_id', '-r', '@'],
        workspacePath,
      );
    }
  }

  /**
   * Push the bookmark to the remote.
   *
   * @param opts.allowNew - pass --allow-new (required for new bookmarks)
   * @param opts.force    - pass --force-new (overwrite remote)
   */
  async push(
    workspacePath: string,
    branchName: string,
    opts?: PushOptions,
  ): Promise<void> {
    const args = ['git', 'push', '--bookmark', branchName];
    if (opts?.allowNew) args.push('--allow-new');
    if (opts?.force) args.push('--force-new');
    await this.jj(args, workspacePath);
  }

  /**
   * Pull by fetching from the remote and rebasing the workspace onto the branch.
   */
  async pull(workspacePath: string, branchName: string): Promise<void> {
    await this.jj(['git', 'fetch'], workspacePath);
    await this.jj(['rebase', '-d', `${branchName}@origin`], workspacePath);
  }

  /**
   * Fetch all refs from the remote without merging.
   */
  async fetch(workspacePath: string): Promise<void> {
    await this.jj(['git', 'fetch'], workspacePath);
  }

  /**
   * Rebase the workspace onto the given target revision.
   *
   * Returns a RebaseResult; does NOT throw on conflict.
   * The caller must check `result.hasConflicts` and call `abortRebase()` if needed.
   */
  async rebase(workspacePath: string, onto: string): Promise<RebaseResult> {
    try {
      await this.jj(['rebase', '-d', onto], workspacePath);
    } catch {
      // jj rebase may continue with conflicts — check for them
    }

    // Check for conflicts (jj doesn't always fail with a non-zero exit code on conflicts)
    const conflictingFiles = await this.getConflictingFiles(workspacePath).catch(
      () => [],
    );
    if (conflictingFiles.length > 0) {
      return { success: false, hasConflicts: true, conflictingFiles };
    }

    return { success: true, hasConflicts: false };
  }

  /**
   * Abort an in-progress rebase by reverting the last operation.
   *
   * For jj: uses `jj op revert` to revert the last operation (default: @).
   * This is the equivalent of "undo" in jj 0.39+.
   */
  async abortRebase(workspacePath: string): Promise<void> {
    await this.jj(['op', 'revert'], workspacePath);
  }

  // ── Merge Operations ──────────────────────────────────────────────────

  /**
   * Merge a bookmark into `targetBranch` (or the default branch if omitted).
   *
   * Uses `jj new <target> <source>` to create a two-parent merge change.
   * Returns a structured result; does NOT throw on conflict.
   */
  async merge(
    repoPath: string,
    branchName: string,
    targetBranch?: string,
  ): Promise<MergeResult> {
    const target = targetBranch ?? (await this.detectDefaultBranch(repoPath));

    // jj creates a merge change with two parents
    await this.jj(
      ['new', target, branchName, '-m', `Merge ${branchName} into ${target}`],
      repoPath,
    );

    // Check for conflicts
    const conflictingFiles = await this.getConflictingFiles(repoPath).catch(
      () => [],
    );
    if (conflictingFiles.length > 0) {
      return { success: false, conflicts: conflictingFiles };
    }

    // Move the target bookmark to the merge change
    try {
      await this.jj(['bookmark', 'set', target, '-r', '@'], repoPath);
    } catch {
      // Non-fatal — bookmark may already be at the right place
    }

    return { success: true };
  }

  // ── Diff, Conflict & Status ───────────────────────────────────────────

  /**
   * Return the list of files in conflict.
   *
   * Uses `jj resolve --list` which exits with code 2 when no conflicts exist.
   * Returns empty array when there are no conflicts.
   */
  async getConflictingFiles(workspacePath: string): Promise<string[]> {
    try {
      const output = await this.jj(['resolve', '--list'], workspacePath);
      if (!output) return [];

      // Output format: "path/to/file    <conflict-info>"
      return output
        .split('\n')
        .map((line) => line.trim())
        .filter(Boolean)
        .map((line) => line.split(/\s+/)[0])
        .filter(Boolean);
    } catch (err: unknown) {
      const e = err as { message?: string };
      // "No conflicts found" is not an error for our purposes
      if (e.message?.includes('No conflicts found')) return [];
      // Other errors also return empty (caller decides if it's a problem)
      return [];
    }
  }

  /**
   * Return the diff output between two revisions.
   */
  async diff(repoPath: string, from: string, to: string): Promise<string> {
    return this.jj(['diff', '--from', from, '--to', to], repoPath);
  }

  /**
   * Return files modified between `base` and the working copy.
   *
   * Uses `jj diff --summary --from <base>` to get the change summary.
   * Output format: "M path/to/file" → returns ["path/to/file"].
   */
  async getModifiedFiles(workspacePath: string, base: string): Promise<string[]> {
    try {
      const output = await this.jj(
        ['diff', '--summary', '--from', base],
        workspacePath,
      );
      if (!output) return [];

      // Output format: "M path/to/file" or "A path/to/file" or "D path/to/file"
      return output
        .split('\n')
        .map((line) => line.trim())
        .filter(Boolean)
        .map((line) => {
          // Strip the status character (M/A/D/R/C) and any leading whitespace
          const parts = line.split(/\s+/);
          return parts.slice(1).join(' ');
        })
        .filter(Boolean);
    } catch {
      return [];
    }
  }

  /**
   * Discard all uncommitted changes and restore to the committed state.
   *
   * Uses `jj restore` to restore all files to the parent change state.
   */
  async cleanWorkingTree(workspacePath: string): Promise<void> {
    await this.jj(['restore'], workspacePath);
  }

  /**
   * Return a human-readable status summary of the workspace.
   */
  async status(workspacePath: string): Promise<string> {
    return this.jj(['status'], workspacePath);
  }

  // ── Finalize Command Generation ───────────────────────────────────────

  /**
   * Generate jj-specific shell commands for the Finalize phase.
   *
   * Returns the six command strings that the Finalize agent executes:
   * - stageCommand: empty (jj auto-stages)
   * - commitCommand: describe the change and create a new child
   * - pushCommand: push the bookmark to the git-backed remote
   * - rebaseCommand: fetch and rebase onto the base branch
   * - branchVerifyCommand: verify the bookmark exists locally
   * - cleanCommand: empty (workspace management handles cleanup)
   */
  getFinalizeCommands(vars: FinalizeTemplateVars): FinalizeCommands {
    const { seedId, seedTitle, baseBranch } = vars;
    return {
      stageCommand: '', // jj auto-stages all changes
      commitCommand: `jj describe -m "${seedTitle} (${seedId})" && jj new`,
      pushCommand: `jj git push --bookmark foreman/${seedId} --allow-new`,
      rebaseCommand: `jj git fetch && jj rebase -d ${baseBranch}@origin`,
      branchVerifyCommand: `jj bookmark list -T 'name ++ "\\n"' | grep -x "foreman/${seedId}"`,
      cleanCommand: '', // jj workspace management handles cleanup
    };
  }
}
