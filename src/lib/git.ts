import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { join } from "node:path";

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
    const stderr = err.stderr?.trim() ?? err.message;
    throw new Error(`git ${args[0]} failed: ${stderr}`);
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
 * Create a worktree for a bead.
 *
 * - Branch: foreman/<beadId>
 * - Location: <repoPath>/.foreman-worktrees/<beadId>
 */
export async function createWorktree(
  repoPath: string,
  beadId: string,
  baseBranch = "main",
): Promise<{ worktreePath: string; branchName: string }> {
  const branchName = `foreman/${beadId}`;
  const worktreePath = join(repoPath, ".foreman-worktrees", beadId);

  await git(
    ["worktree", "add", "-b", branchName, worktreePath, baseBranch],
    repoPath,
  );

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
 * Merge a branch into the target branch.
 * Returns success status and any conflicting file paths.
 */
export async function mergeWorktree(
  repoPath: string,
  branchName: string,
  targetBranch = "main",
): Promise<MergeResult> {
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
}
