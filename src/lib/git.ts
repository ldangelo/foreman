import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { promisify } from "node:util";
import { join } from "node:path";
import { existsSync, readFileSync, lstatSync } from "node:fs";
import fs from "node:fs/promises";
import type { WorkflowSetupStep, WorkflowSetupCache } from "./workflow-loader.js";

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

/**
 * Run workflow setup steps in a worktree directory.
 *
 * Each step's `command` is split on whitespace to form an argv array and
 * executed via execFileAsync with `cwd` set to `dir`.
 *
 * Steps with `failFatal !== false` (i.e. default true) throw on non-zero exit.
 * Steps with `failFatal === false` log a warning and continue.
 */
export async function runSetupSteps(
  dir: string,
  steps: WorkflowSetupStep[],
): Promise<void> {
  for (const step of steps) {
    const label = step.description ?? step.command;
    console.error(`[setup] Running: ${step.command}`);

    const argv = step.command.trim().split(/\s+/);
    const [cmd, ...args] = argv;

    try {
      await execFileAsync(cmd, args, { cwd: dir, maxBuffer: 10 * 1024 * 1024 });
    } catch (err: unknown) {
      const e = err as { stdout?: string; stderr?: string; message?: string };
      const joined = [e.stdout, e.stderr]
        .map((s) => (s ?? "").trim())
        .filter(Boolean)
        .join("\n");
      const combined = joined || (e.message ?? String(err));

      if (step.failFatal !== false) {
        throw new Error(`Setup step failed (${label}): ${combined}`);
      } else {
        console.error(`[setup] Warning: step failed (non-fatal) — ${label}: ${combined}`);
      }
    }
  }
}

// ── Setup Cache (stack-agnostic) ─────────────────────────────────────────

/**
 * Compute a cache key by hashing the contents of the key file(s).
 * Returns a short hex hash suitable for use as a directory name.
 */
function computeCacheHash(worktreePath: string, keyFile: string): string | null {
  const keyPath = join(worktreePath, keyFile);
  if (!existsSync(keyPath)) return null;
  const content = readFileSync(keyPath);
  return createHash("sha256").update(content).digest("hex").slice(0, 16);
}

/**
 * Try to restore a cached dependency directory via symlink.
 * Returns true if cache hit (symlink created), false if cache miss.
 */
async function tryRestoreFromCache(
  worktreePath: string,
  projectRoot: string,
  cache: WorkflowSetupCache,
): Promise<boolean> {
  const hash = computeCacheHash(worktreePath, cache.key);
  if (!hash) return false;

  const cacheDir = join(projectRoot, ".foreman", "setup-cache", hash);
  const cachedPath = join(cacheDir, cache.path);
  const targetPath = join(worktreePath, cache.path);

  if (!existsSync(join(cacheDir, ".complete"))) return false;
  if (!existsSync(cachedPath)) return false;

  // Remove any existing target (e.g. empty dir from git worktree)
  try { await fs.rm(targetPath, { recursive: true, force: true }); } catch { /* ok */ }

  await fs.symlink(cachedPath, targetPath);
  console.error(`[setup-cache] Cache hit (${hash.slice(0, 8)}) — symlinked ${cache.path}`);
  return true;
}

/**
 * After running setup steps, populate the cache for future worktrees.
 */
async function populateCache(
  worktreePath: string,
  projectRoot: string,
  cache: WorkflowSetupCache,
): Promise<void> {
  const hash = computeCacheHash(worktreePath, cache.key);
  if (!hash) return;

  const cacheDir = join(projectRoot, ".foreman", "setup-cache", hash);
  const sourcePath = join(worktreePath, cache.path);
  const cachedPath = join(cacheDir, cache.path);

  if (!existsSync(sourcePath)) return;
  if (existsSync(join(cacheDir, ".complete"))) return; // already cached

  await fs.mkdir(cacheDir, { recursive: true });

  // Move the installed deps to the cache, then symlink back
  try { await fs.rm(cachedPath, { recursive: true, force: true }); } catch { /* ok */ }
  await fs.rename(sourcePath, cachedPath);
  await fs.symlink(cachedPath, sourcePath);
  await fs.writeFile(join(cacheDir, ".complete"), new Date().toISOString());
  console.error(`[setup-cache] Cached ${cache.path} (${hash.slice(0, 8)})`);
}

/**
 * Run setup steps with optional caching.
 *
 * If `cache` is configured in the workflow YAML:
 *   1. Try to restore from cache (symlink). If hit → skip setup steps.
 *   2. If miss → run setup steps → populate cache for next time.
 *
 * If no `cache` → just run setup steps normally.
 */
export async function runSetupWithCache(
  worktreePath: string,
  projectRoot: string,
  steps: WorkflowSetupStep[],
  cache?: WorkflowSetupCache,
): Promise<void> {
  if (cache) {
    const restored = await tryRestoreFromCache(worktreePath, projectRoot, cache);
    if (restored) return; // cache hit — skip setup steps
  }

  // Cache miss or no cache configured — run steps
  await runSetupSteps(worktreePath, steps);

  // Populate cache for future worktrees
  if (cache) {
    await populateCache(worktreePath, projectRoot, cache);
  }
}

// ── Interfaces ──────────────────────────────────────────────────────────

/**
 * @deprecated Use `Workspace` from `src/lib/vcs/types.ts` instead.
 * Kept for backward compatibility; structurally identical to Workspace.
 */
export interface Worktree {
  path: string;
  branch: string;
  head: string;
  bare: boolean;
}

/**
 * @deprecated Use `MergeResult` from `src/lib/vcs/types.ts` instead.
 * Kept for backward compatibility; structurally identical to VCS MergeResult.
 */
export interface MergeResult {
  success: boolean;
  conflicts?: string[];
}

/**
 * @deprecated Use `DeleteBranchResult` from `src/lib/vcs/types.ts` instead.
 * Kept for backward compatibility; structurally identical to VCS DeleteBranchResult.
 */
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
//
// NOTE (TRD-011): These functions are backward-compatibility shims.
// They retain their original implementations to avoid a circular import
// (git-backend.ts imports utilities from this module). A full refactor to
// delegate to a GitBackend singleton would require moving the utility
// functions (installDependencies, runSetupWithCache, etc.) to a separate
// `src/lib/setup.ts` module — deferred to Phase C.

/**
 * Find the root of the git repository containing `path`.
 * @deprecated Use `GitBackend.getRepoRoot()` from `src/lib/vcs/git-backend.ts` instead.
 */
export async function getRepoRoot(path: string): Promise<string> {
  return git(["rev-parse", "--show-toplevel"], path);
}

/**
 * Find the main (primary) worktree root from any git worktree.
 *
 * `git rev-parse --show-toplevel` returns the *current* worktree root,
 * which for a linked worktree is the worktree directory itself — not the
 * main project root.  This function resolves the common `.git` directory
 * and strips the trailing `/.git` to always return the main project root.
 * @deprecated Use `GitBackend.getMainRepoRoot()` from `src/lib/vcs/git-backend.ts` instead.
 */
export async function getMainRepoRoot(path: string): Promise<string> {
  const commonDir = await git(["rev-parse", "--git-common-dir"], path);
  // commonDir is e.g. "/path/to/project/.git" — strip the trailing "/.git"
  if (commonDir.endsWith("/.git")) {
    return commonDir.slice(0, -5);
  }
  // Fallback: if not a standard path, use show-toplevel
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
 * @deprecated Use `GitBackend.detectDefaultBranch()` from `src/lib/vcs/git-backend.ts` instead.
 */
export async function detectDefaultBranch(repoPath: string): Promise<string> {
  // 1. Respect git-town.main-branch config (user's explicit development trunk)
  try {
    const gtMain = await git(
      ["config", "get", "git-town.main-branch"],
      repoPath,
    );
    if (gtMain) return gtMain;
  } catch {
    // git-town not configured or command unavailable — fall through
  }

  // 2. Try origin/HEAD symbolic ref
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

  // 3. Check if "main" exists locally
  try {
    await git(["rev-parse", "--verify", "main"], repoPath);
    return "main";
  } catch {
    // "main" does not exist — fall through
  }

  // 4. Check if "master" exists locally
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
 * @deprecated Use `GitBackend.getCurrentBranch()` from `src/lib/vcs/git-backend.ts` instead.
 */
export async function getCurrentBranch(repoPath: string): Promise<string> {
  return git(["rev-parse", "--abbrev-ref", "HEAD"], repoPath);
}

/**
 * Checkout a branch by name.
 * Throws if the branch does not exist or the checkout fails.
 * @deprecated Use `GitBackend.checkoutBranch()` from `src/lib/vcs/git-backend.ts` instead.
 */
export async function checkoutBranch(repoPath: string, branchName: string): Promise<void> {
  await git(["checkout", branchName], repoPath);
}

/**
 * Create a worktree for a seed.
 *
 * - Branch: foreman/<seedId>
 * - Location: <repoPath>/.foreman-worktrees/<seedId>
 * - Base: current branch (auto-detected if not specified)
 * @deprecated Use `GitBackend.createWorkspace()` from `src/lib/vcs/git-backend.ts` instead.
 */
export async function createWorktree(
  repoPath: string,
  seedId: string,
  baseBranch?: string,
  setupSteps?: WorkflowSetupStep[],
  setupCache?: WorkflowSetupCache,
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
    if (setupSteps && setupSteps.length > 0) {
      await runSetupWithCache(worktreePath, repoPath, setupSteps, setupCache);
    } else {
      await installDependencies(worktreePath);
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

  // Run setup steps with caching (or fallback to Node.js dependency install)
  if (setupSteps && setupSteps.length > 0) {
    await runSetupWithCache(worktreePath, repoPath, setupSteps, setupCache);
  } else {
    await installDependencies(worktreePath);
  }

  return { worktreePath, branchName };
}

/**
 * Remove a worktree and prune stale entries.
 *
 * After removing the worktree, runs `git worktree prune` to delete any stale
 * `.git/worktrees/<name>` metadata left behind. The prune step is non-fatal —
 * if it fails, a warning is logged but the function still resolves successfully.
 * @deprecated Use `GitBackend.removeWorkspace()` from `src/lib/vcs/git-backend.ts` instead.
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
 * @deprecated Use `GitBackend.listWorkspaces()` from `src/lib/vcs/git-backend.ts` instead.
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
 * @deprecated Use `GitBackend.deleteBranch()` from `src/lib/vcs/git-backend.ts` instead.
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
 * @deprecated Use `GitBackend.branchExists()` from `src/lib/vcs/git-backend.ts` instead.
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
 * @deprecated Use `GitBackend.branchExistsOnRemote()` from `src/lib/vcs/git-backend.ts` instead.
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
 * @deprecated Use `GitBackend.merge()` from `src/lib/vcs/git-backend.ts` instead.
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
