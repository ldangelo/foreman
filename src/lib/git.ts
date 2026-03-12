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
  tier?: number;
  strategy?: string;
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
 * Create a worktree for a bead.
 *
 * - Branch: foreman/<beadId>
 * - Location: <repoPath>/.foreman-worktrees/<beadId>
 * - Base: current branch (auto-detected if not specified)
 */
export async function createWorktree(
  repoPath: string,
  beadId: string,
  baseBranch?: string,
): Promise<{ worktreePath: string; branchName: string }> {
  const base = baseBranch ?? await getCurrentBranch(repoPath);
  const branchName = `foreman/${beadId}`;
  const worktreePath = join(repoPath, ".foreman-worktrees", beadId);

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
 * Delete a local branch. Does not fail if the branch doesn't exist.
 */
export async function deleteBranch(
  repoPath: string,
  branchName: string,
): Promise<void> {
  try {
    await git(["branch", "-D", branchName], repoPath);
  } catch (err: unknown) {
    const msg = (err as Error).message ?? "";
    if (msg.includes("not found")) return; // already deleted
    throw err;
  }
}

/**
 * Abort any in-progress merge. Does not fail if no merge is in progress.
 */
async function abortMerge(repoPath: string): Promise<void> {
  try {
    await git(["merge", "--abort"], repoPath);
  } catch {
    // No merge in progress — ignore
  }
}

/**
 * Attempt a single merge with an optional strategy option (-X ours / -X theirs).
 * Caller must ensure the target branch is already checked out.
 * Returns success status and any conflicting file paths.
 */
export async function mergeWorktree(
  repoPath: string,
  branchName: string,
  targetBranch?: string,
  strategy?: "ours" | "theirs",
): Promise<MergeResult> {
  targetBranch ??= await getCurrentBranch(repoPath);
  // Checkout target branch
  await git(["checkout", targetBranch], repoPath);

  const args = ["merge", branchName, "--no-ff"];
  if (strategy) {
    args.push("-X", strategy);
  }

  try {
    await git(args, repoPath);
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

/**
 * Attempt to merge a branch using a 4-tier escalating strategy:
 *
 * - Tier 1 (recursive): Default git merge — auto-resolves simple conflicts
 * - Tier 2 (ours):      `-X ours`   — prefer target-branch (main) changes on conflict
 * - Tier 3 (theirs):    `-X theirs` — prefer agent-branch changes on conflict
 * - Tier 4 (manual):    All automatic strategies failed; requires human intervention
 *
 * After each failed attempt the in-progress merge is aborted so the repo is
 * left clean before the next tier is tried.
 *
 * Returns a `MergeResult` with `tier` (1–4) and `strategy` describing the
 * outcome. `success: false` with `tier: 4` means manual intervention is needed.
 */
export async function mergeWorktreeWithTiers(
  repoPath: string,
  branchName: string,
  targetBranch?: string,
): Promise<MergeResult> {
  targetBranch ??= await getCurrentBranch(repoPath);

  // Tier 1: Default recursive merge
  const tier1 = await mergeWorktree(repoPath, branchName, targetBranch);
  if (tier1.success) {
    return { success: true, tier: 1, strategy: "recursive" };
  }

  await abortMerge(repoPath);

  // Tier 2: Ours strategy — prefer target-branch changes
  const tier2 = await mergeWorktree(repoPath, branchName, targetBranch, "ours");
  if (tier2.success) {
    return { success: true, tier: 2, strategy: "ours" };
  }

  await abortMerge(repoPath);

  // Tier 3: Theirs strategy — prefer agent-branch changes
  const tier3 = await mergeWorktree(repoPath, branchName, targetBranch, "theirs");
  if (tier3.success) {
    return { success: true, tier: 3, strategy: "theirs" };
  }

  await abortMerge(repoPath);

  // Tier 4: All automatic strategies exhausted — manual intervention required
  return {
    success: false,
    tier: 4,
    strategy: "manual",
    conflicts: tier3.conflicts,
  };
}
