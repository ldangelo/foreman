import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { join } from "node:path";
import { existsSync } from "node:fs";

const execFileAsync = promisify(execFile);

// ── Interfaces ──────────────────────────────────────────────────────────

export interface Worktree {
  path: string;
  branch: string;
  head: string;
  bare: boolean;
}

export interface MergeResult {
  success: boolean;
  conflicts?: string[];
}

export interface DeleteBranchResult {
  deleted: boolean;
  wasFullyMerged: boolean;
}

// ── Helpers ─────────────────────────────────────────────────────────────

async function git(
  args: string[],
  cwd: string,
): Promise<string> {
  try {
    const { stdout } = await execFileAsync("git", args, {
      cwd,
      maxBuffer: 10 * 1024 * 1024,
    });
    return stdout.trim();
  } catch (err: any) {
    const combined = [err.stdout, err.stderr]
      .map((s) => (s ?? "").trim())
      .filter(Boolean)
      .join("\n") || err.message;
    throw new Error(`git ${args[0]} failed: ${combined}`);
  }
}

// ── Public API ──────────────────────────────────────────────────────────

/**
 * Find the root of the git repository containing `path`.
 */
export async function getRepoRoot(path: string): Promise<string> {
  return git(["rev-parse", "--show-toplevel"], path);
}

/**
 * Get the current branch name.
 */
export async function getCurrentBranch(repoPath: string): Promise<string> {
  return git(["rev-parse", "--abbrev-ref", "HEAD"], repoPath);
}

/**
 * Create a worktree for a seed.
 *
 * - Branch: foreman/<seedId>
 * - Location: <repoPath>/.foreman-worktrees/<seedId>
 * - Base: current branch (auto-detected if not specified)
 */
export async function createWorktree(
  repoPath: string,
  seedId: string,
  baseBranch?: string,
): Promise<{ worktreePath: string; branchName: string }> {
  const base = baseBranch ?? await getCurrentBranch(repoPath);
  const branchName = `foreman/${seedId}`;
  const worktreePath = join(repoPath, ".foreman-worktrees", seedId);

  // If worktree already exists (e.g. from a failed previous run), reuse it
  if (existsSync(worktreePath)) {
    // Update the branch to the latest base so it picks up new code
    try {
      await git(["rebase", base], worktreePath);
    } catch {
      // Rebase may fail if there are conflicts — that's OK, use as-is
    }
    return { worktreePath, branchName };
  }

  // Branch may exist without a worktree (worktree was cleaned up but branch wasn't)
  try {
    await git(
      ["worktree", "add", "-b", branchName, worktreePath, base],
      repoPath,
    );
  } catch (err: unknown) {
    const msg = (err as Error).message ?? "";
    if (msg.includes("already exists")) {
      // Branch exists — create worktree using existing branch
      await git(["worktree", "add", worktreePath, branchName], repoPath);
    } else {
      throw err;
    }
  }

  return { worktreePath, branchName };
}

/**
 * Remove a worktree and prune stale entries.
 */
export async function removeWorktree(
  repoPath: string,
  worktreePath: string,
): Promise<void> {
  await git(["worktree", "remove", worktreePath, "--force"], repoPath);
}

/**
 * List all worktrees for the repo.
 */
export async function listWorktrees(
  repoPath: string,
): Promise<Worktree[]> {
  const raw = await git(
    ["worktree", "list", "--porcelain"],
    repoPath,
  );

  if (!raw) return [];

  const worktrees: Worktree[] = [];
  let current: Partial<Worktree> = {};

  for (const line of raw.split("\n")) {
    if (line.startsWith("worktree ")) {
      if (current.path) worktrees.push(current as Worktree);
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
      worktrees.push(current as Worktree);
      current = {};
    }
  }
  if (current.path) worktrees.push(current as Worktree);

  return worktrees;
}

/**
 * Delete a local branch with merge-safety checks.
 *
 * - If the branch is fully merged into targetBranch (default "main"), uses `git branch -d` (safe delete).
 * - If NOT merged and `force: true`, uses `git branch -D` (force delete).
 * - If NOT merged and `force: false` (default), skips deletion and returns `{ deleted: false, wasFullyMerged: false }`.
 * - If the branch does not exist, returns `{ deleted: false, wasFullyMerged: true }` (already gone).
 */
export async function deleteBranch(
  repoPath: string,
  branchName: string,
  options?: { force?: boolean; targetBranch?: string },
): Promise<DeleteBranchResult> {
  const force = options?.force ?? false;
  const targetBranch = options?.targetBranch ?? "main";

  // Check if branch exists
  try {
    await git(["rev-parse", "--verify", branchName], repoPath);
  } catch {
    // Branch not found — already gone
    return { deleted: false, wasFullyMerged: true };
  }

  // Check merge status: is branchName an ancestor of targetBranch?
  let isFullyMerged = false;
  try {
    await git(["merge-base", "--is-ancestor", branchName, targetBranch], repoPath);
    isFullyMerged = true;
  } catch {
    // merge-base --is-ancestor exits non-zero when branch is NOT an ancestor
    isFullyMerged = false;
  }

  if (isFullyMerged) {
    // We verified merge status via merge-base --is-ancestor against targetBranch.
    // Use -D because git branch -d checks against HEAD, which may differ from targetBranch.
    await git(["branch", "-D", branchName], repoPath);
    return { deleted: true, wasFullyMerged: true };
  }

  if (force) {
    // Force delete — caller explicitly asked for it
    await git(["branch", "-D", branchName], repoPath);
    return { deleted: true, wasFullyMerged: false };
  }

  // Not merged and not forced — skip deletion
  return { deleted: false, wasFullyMerged: false };
}

/**
 * Merge a branch into the target branch.
 * Returns success status and any conflicting file paths.
 */
export async function mergeWorktree(
  repoPath: string,
  branchName: string,
  targetBranch?: string,
): Promise<MergeResult> {
  targetBranch ??= await getCurrentBranch(repoPath);

  // Stash any local changes so checkout doesn't fail on a dirty tree
  let stashed = false;
  try {
    const stashOut = await git(["stash", "push", "-m", "foreman-merge-auto-stash"], repoPath);
    stashed = !stashOut.includes("No local changes");
  } catch {
    // stash may fail if there's nothing to stash — that's fine
  }

  try {
    // Checkout target branch
    await git(["checkout", targetBranch], repoPath);

    try {
      await git(["merge", branchName, "--no-ff"], repoPath);
      return { success: true };
    } catch (err: any) {
      const message: string = err.message ?? "";
      if (message.includes("CONFLICT") || message.includes("Merge conflict")) {
        // Gather conflicting files
        const statusOut = await git(["diff", "--name-only", "--diff-filter=U"], repoPath);
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
        await git(["stash", "pop"], repoPath);
      } catch {
        // Pop may conflict — leave in stash, user can recover with `git stash pop`
      }
    }
  }
}
