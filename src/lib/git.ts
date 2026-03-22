import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { join } from "node:path";
import { existsSync } from "node:fs";
import fs from "node:fs/promises";

const execFileAsync = promisify(execFile);

// ── Dependency Installation ──────────────────────────────────────────────

/**
 * Detect which package manager to use based on lock files present in a directory.
 * Returns the package manager command ("npm", "yarn", or "pnpm").
 * Priority order: pnpm > yarn > npm (explicit lock-file check for each).
 */
export function detectPackageManager(dir: string): "npm" | "yarn" | "pnpm" {
  if (existsSync(join(dir, "pnpm-lock.yaml"))) return "pnpm";
  if (existsSync(join(dir, "yarn.lock"))) return "yarn";
  if (existsSync(join(dir, "package-lock.json"))) return "npm";
  // Default to npm when no lock file is present (e.g. freshly created projects)
  return "npm";
}

/**
 * Install Node.js dependencies in the given directory.
 *
 * - Detects the package manager from lock files.
 * - Skips silently if no `package.json` is present (non-Node repos).
 * - Uses `--prefer-offline` and `--no-audit` for speed when npm is used.
 * - Throws if the installation fails.
 */
export async function installDependencies(dir: string): Promise<void> {
  // Skip if no package.json — not a Node.js project
  if (!existsSync(join(dir, "package.json"))) {
    return;
  }

  const pm = detectPackageManager(dir);
  console.error(`[git] Running ${pm} install in ${dir} …`);

  const args: string[] =
    pm === "npm"
      ? ["install", "--prefer-offline", "--no-audit"]
      : pm === "yarn"
        ? ["install", "--prefer-offline"]
        : ["install", "--prefer-offline"]; // pnpm

  try {
    await execFileAsync(pm, args, { cwd: dir, maxBuffer: 10 * 1024 * 1024 });
  } catch (err: any) {
    const combined = [err.stdout, err.stderr]
      .map((s: string | undefined) => (s ?? "").trim())
      .filter(Boolean)
      .join("\n") || err.message;
    throw new Error(`${pm} install failed in ${dir}: ${combined}`);
  }
}

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
 * Detect the default/parent branch for a repository.
 *
 * Resolution order:
 * 1. `git symbolic-ref refs/remotes/origin/HEAD --short` → strips "origin/" prefix
 *    (e.g. "origin/main" → "main"). Works when the remote has been fetched.
 * 2. Check whether "main" exists as a local branch.
 * 3. Check whether "master" exists as a local branch.
 * 4. Fall back to the current branch.
 */
export async function detectDefaultBranch(repoPath: string): Promise<string> {
  // 1. Try origin/HEAD symbolic ref
  try {
    const ref = await git(
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

  // 2. Check if "main" exists locally
  try {
    await git(["rev-parse", "--verify", "main"], repoPath);
    return "main";
  } catch {
    // "main" does not exist — fall through
  }

  // 3. Check if "master" exists locally
  try {
    await git(["rev-parse", "--verify", "master"], repoPath);
    return "master";
  } catch {
    // "master" does not exist — fall through
  }

  // 4. Fall back to the current branch
  return getCurrentBranch(repoPath);
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
    // Update the branch to the latest base so it picks up new code.
    // Rebase may fail when there are unstaged changes in the worktree —
    // attempt a `git checkout -- .` to discard them before retrying.
    try {
      await git(["rebase", base], worktreePath);
    } catch (rebaseErr) {
      const rebaseMsg = rebaseErr instanceof Error ? rebaseErr.message : String(rebaseErr);
      const hasUnstagedChanges =
        rebaseMsg.includes("unstaged changes") ||
        rebaseMsg.includes("uncommitted changes") ||
        rebaseMsg.includes("please stash");

      if (hasUnstagedChanges) {
        console.error(`[git] Rebase failed due to unstaged changes in ${worktreePath} — cleaning and retrying`);
        try {
          // Discard all unstaged changes and untracked files so rebase can proceed
          await git(["checkout", "--", "."], worktreePath);
          await git(["clean", "-fd"], worktreePath);
          // Retry the rebase after cleaning
          await git(["rebase", base], worktreePath);
        } catch (retryErr) {
          const retryMsg = retryErr instanceof Error ? retryErr.message : String(retryErr);
          // Abort any partial rebase to leave the worktree in a usable state
          try { await git(["rebase", "--abort"], worktreePath); } catch { /* already clean */ }
          throw new Error(`Rebase failed even after cleaning unstaged changes: ${retryMsg}`);
        }
      } else {
        // Non-unstaged-changes rebase failure (e.g. real conflicts): throw so
        // the dispatcher does not spawn an agent into a broken worktree.
        try { await git(["rebase", "--abort"], worktreePath); } catch { /* already clean */ }
        throw new Error(`Rebase failed in ${worktreePath}: ${rebaseMsg.slice(0, 300)}`);
      }
    }
    // Reinstall in case dependencies changed after rebase
    await installDependencies(worktreePath);
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

  // Install Node.js dependencies in the new worktree
  await installDependencies(worktreePath);

  return { worktreePath, branchName };
}

/**
 * Remove a worktree and prune stale entries.
 *
 * After removing the worktree, runs `git worktree prune` to delete any stale
 * `.git/worktrees/<name>` metadata left behind. The prune step is non-fatal —
 * if it fails, a warning is logged but the function still resolves successfully.
 */
export async function removeWorktree(
  repoPath: string,
  worktreePath: string,
): Promise<void> {
  // Try the standard git removal first.
  try {
    await git(["worktree", "remove", worktreePath, "--force"], repoPath);
  } catch (removeErr) {
    // git worktree remove --force can fail when the directory has untracked
    // files (e.g. written by a spawned process).  In that case git exits with
    // "Directory not empty", leaving a dangling .git file that breaks the next
    // dispatch.  Fall back to a plain recursive directory removal so the
    // subsequent worktree prune can clean up the stale metadata.
    const removeMsg = removeErr instanceof Error ? removeErr.message : String(removeErr);
    console.error(`[git] Warning: git worktree remove --force failed for ${worktreePath}: ${removeMsg}`);
    console.error(`[git] Falling back to fs.rm for ${worktreePath}`);
    try {
      await fs.rm(worktreePath, { recursive: true, force: true });
    } catch (rmErr) {
      const rmMsg = rmErr instanceof Error ? rmErr.message : String(rmErr);
      console.error(`[git] Warning: fs.rm fallback also failed for ${worktreePath}: ${rmMsg}`);
    }
  }

  // Prune stale .git/worktrees/<seed> metadata so the next dispatch does not
  // fail with "fatal: not a git repository: .git/worktrees/<seed>".
  try {
    await git(["worktree", "prune"], repoPath);
  } catch (pruneErr) {
    // Non-fatal: log a warning and continue.
    const msg = pruneErr instanceof Error ? pruneErr.message : String(pruneErr);
    console.error(`[git] Warning: worktree prune failed after removing ${worktreePath}: ${msg}`);
  }
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
  const targetBranch = options?.targetBranch ?? await detectDefaultBranch(repoPath);

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
 * Check whether a local branch exists in the repository.
 *
 * Uses `git show-ref --verify --quiet refs/heads/<branchName>`.
 * Returns `false` if the branch does not exist or any error occurs.
 */
export async function gitBranchExists(
  repoPath: string,
  branchName: string,
): Promise<boolean> {
  try {
    await git(["show-ref", "--verify", "--quiet", `refs/heads/${branchName}`], repoPath);
    return true;
  } catch {
    return false;
  }
}

/**
 * Check whether a branch exists on the origin remote.
 *
 * Uses `git rev-parse origin/<branchName>` against local remote-tracking refs.
 * Returns `false` if there is no remote, the branch doesn't exist on origin,
 * or any other error occurs (fail-safe: unknown → don't delete).
 */
export async function branchExistsOnOrigin(
  repoPath: string,
  branchName: string,
): Promise<boolean> {
  try {
    await git(["rev-parse", "--verify", `origin/${branchName}`], repoPath);
    return true;
  } catch {
    return false;
  }
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
