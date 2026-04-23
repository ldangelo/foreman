/**
 * WorktreeManager — manages git worktrees at ~/.foreman/worktrees/<project-id>/<bead-id>.
 *
 * Path hierarchy:
 *   ~/.foreman/worktrees/<projectId>/<beadId>
 *
 * Each worktree is a git worktree of the project's repository, checked out
 * on a branch named `foreman/<beadId>`. This keeps per-bead workspaces isolated
 * from the main checkout without polluting the project directory.
 *
 * @module src/lib/worktree-manager
 */

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { join, basename } from "node:path";
import { homedir } from "node:os";

export interface WorktreeInfo {
  projectId: string;
  beadId: string;
  branchName: string;
  path: string;
  exists: boolean;
}

export interface CreateWorktreeOptions {
  projectId: string;
  beadId: string;
  repoPath: string;
  baseBranch?: string;
}

export interface ListWorktreesResult {
  projectId: string;
  worktrees: WorktreeInfo[];
}

// ── Constants ────────────────────────────────────────────────────────────────

function getDefaultWorktreesRoot(): string {
  return join(homedir(), ".foreman", "worktrees");
}

// ── WorktreeManager ──────────────────────────────────────────────────────────

export class WorktreeManager {
  /**
   * The root directory for all Foreman worktrees.
   * Defaults to ~/.foreman/worktrees.
   */
  readonly root: string;

  constructor(options: { root?: string } = {}) {
    this.root = options.root ?? getDefaultWorktreesRoot();
  }

  /**
   * Get the worktree directory for a specific project+bead.
   */
  getWorktreePath(projectId: string, beadId: string): string {
    return join(this.root, projectId, beadId);
  }

  /**
   * Get the worktrees directory for a project.
   */
  getProjectRoot(projectId: string): string {
    return join(this.root, projectId);
  }

  /**
   * Create a git worktree for a bead.
   *
   * Branch: foreman/<beadId>
   * Path: ~/.foreman/worktrees/<projectId>/<beadId>
   *
   * If the worktree already exists, rebases onto the base branch.
   * If the branch already exists but has no worktree, attaches a new worktree.
   *
   * @throws Error if creation/rebase fails after cleanup
   */
  async createWorktree(options: CreateWorktreeOptions): Promise<WorktreeInfo> {
    const { projectId, beadId, repoPath, baseBranch } = options;
    const branchName = `foreman/${beadId}`;
    const worktreePath = this.getWorktreePath(projectId, beadId);

    // Ensure parent directory exists
    mkdirSync(this.getProjectRoot(projectId), { recursive: true, mode: 0o700 });

    // If worktree already exists — reuse it with rebase
    if (existsSync(worktreePath)) {
      await this._rebaseWorktree(worktreePath, baseBranch ?? "HEAD");
      return { projectId, beadId, branchName, path: worktreePath, exists: true };
    }

    // Branch may exist without a worktree — try to attach worktree
    try {
      execFileSync("git", ["worktree", "add", "-b", branchName, worktreePath, baseBranch ?? "HEAD"], {
        cwd: repoPath,
        stdio: "pipe",
      });
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      if (msg.includes("already exists")) {
        // Branch exists, just attach worktree
        execFileSync("git", ["worktree", "add", worktreePath, branchName], {
          cwd: repoPath,
          stdio: "pipe",
        });
      } else if (msg.includes("fatal")) {
        throw new Error(`Failed to create worktree at ${worktreePath}: ${msg}`);
      } else {
        throw err;
      }
    }

    return { projectId, beadId, branchName, path: worktreePath, exists: true };
  }

  /**
   * Remove a worktree and its branch.
   */
  async removeWorktree(projectId: string, beadId: string, repoPath: string): Promise<void> {
    const worktreePath = this.getWorktreePath(projectId, beadId);
    if (!existsSync(worktreePath)) return;

    try {
      execFileSync("git", ["worktree", "remove", worktreePath, "--force"], {
        cwd: repoPath,
        stdio: "pipe",
      });
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      if (!msg.includes("is not a working tree")) {
        // Not a registered worktree — just remove the directory
        try {
          rmSync(worktreePath, { recursive: true, force: true });
        } catch { /* ignore */ }
      }
    }
  }

  /**
   * List all worktrees for a project.
   */
  listWorktrees(projectId: string): WorktreeInfo[] {
    const projectRoot = this.getProjectRoot(projectId);
    if (!existsSync(projectRoot)) return [];

    const worktrees: WorktreeInfo[] = [];
    try {
      for (const entry of readdirSync(projectRoot, { withFileTypes: true })) {
        if (!entry.isDirectory()) continue;
        const beadId = entry.name;
        const worktreePath = join(projectRoot, beadId);
        const branchName = `foreman/${beadId}`;
        worktrees.push({
          projectId,
          beadId,
          branchName,
          path: worktreePath,
          exists: existsSync(worktreePath),
        });
      }
    } catch { /* empty or inaccessible directory */ }

    return worktrees;
  }

  /**
   * List all worktrees across all projects.
   */
  listAllWorktrees(): ListWorktreesResult[] {
    if (!existsSync(this.root)) return [];

    const results: ListWorktreesResult[] = [];
    try {
      for (const entry of readdirSync(this.root, { withFileTypes: true })) {
        if (!entry.isDirectory()) continue;
        const projectId = entry.name;
        results.push({
          projectId,
          worktrees: this.listWorktrees(projectId),
        });
      }
    } catch { /* empty or inaccessible */ }

    return results;
  }

  /**
   * Clean up stale worktree directories that are no longer valid git worktrees.
   * Returns the number of directories removed.
   */
  cleanStaleWorktrees(projectId: string): number {
    const worktrees = this.listWorktrees(projectId);
    let removed = 0;

    for (const wt of worktrees) {
      if (!existsSync(wt.path)) continue;

      // Check if it's a valid git worktree by looking for .git file
      const gitFile = join(wt.path, ".git");
      const isValidWorktree = existsSync(gitFile) || existsSync(join(wt.path, ".git"));

      if (!isValidWorktree) {
        try {
          rmSync(wt.path, { recursive: true, force: true });
          removed++;
        } catch { /* ignore */ }
      }
    }

    return removed;
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  private async _rebaseWorktree(worktreePath: string, baseBranch: string): Promise<void> {
    try {
      execFileSync("git", ["rebase", baseBranch], {
        cwd: worktreePath,
        stdio: "pipe",
      });
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      const hasUnstaged = msg.includes("unstaged") || msg.includes("uncommitted");

      if (hasUnstaged) {
        // Discard changes and rebase
        try {
          execFileSync("git", ["checkout", "--", "."], { cwd: worktreePath, stdio: "pipe" });
          execFileSync("git", ["clean", "-fd"], { cwd: worktreePath, stdio: "pipe" });
          execFileSync("git", ["rebase", baseBranch], { cwd: worktreePath, stdio: "pipe" });
        } catch (retryErr) {
          const retryMsg = retryErr instanceof Error ? retryErr.message : String(retryErr);
          try { execFileSync("git", ["rebase", "--abort"], { cwd: worktreePath, stdio: "pipe" }); } catch { /* ok */ }
          throw new Error(`Rebase failed after cleanup: ${retryMsg}`);
        }
      } else {
        try { execFileSync("git", ["rebase", "--abort"], { cwd: worktreePath, stdio: "pipe" }); } catch { /* ok */ }
        throw new Error(`Rebase failed: ${msg.slice(0, 300)}`);
      }
    }
  }
}
