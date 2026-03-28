/**
 * git.ts — Backward-compatibility shim for VCS operations.
 *
 * @deprecated This file is a thin shim delegating to `GitBackend` from the
 * `src/lib/vcs/` layer (TRD-011). New code should import from `src/lib/vcs/`
 * directly. These exports exist to avoid breaking existing consumers during
 * the migration period; they will be removed in a future release.
 *
 * See TRD-011 in trd-2026-004-vcs-backend-abstraction for migration details.
 */

import { createHash } from "node:crypto";
import { join } from "node:path";
import { existsSync, readFileSync } from "node:fs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";

import { GitBackend } from "./vcs/git-backend.js";

import type { WorkflowSetupStep, WorkflowSetupCache } from "./workflow-loader.js";
import type { Workspace, MergeResult as VcsMergeResult, DeleteBranchResult as VcsDeleteBranchResult } from "./vcs/types.js";

const execFileAsync = promisify(execFile);

// ── Backward-Compat Type Re-exports ──────────────────────────────────────────

/**
 * @deprecated Use `Workspace` from `src/lib/vcs/types.js` instead.
 * Structurally identical to `Workspace`; provided for backward compatibility.
 */
export type Worktree = Workspace;

/**
 * @deprecated Use `MergeResult` from `src/lib/vcs/types.js` instead.
 */
export type MergeResult = VcsMergeResult;

/**
 * @deprecated Use `DeleteBranchResult` from `src/lib/vcs/types.js` instead.
 */
export type DeleteBranchResult = VcsDeleteBranchResult;

// ── Dependency Installation (non-git, kept in shim) ─────────────────────────

/**
 * Detect which package manager to use based on lock files present in a directory.
 * Returns the package manager command ("npm", "yarn", or "pnpm").
 * Priority order: pnpm > yarn > npm (explicit lock-file check for each).
 */
export function detectPackageManager(dir: string): "npm" | "yarn" | "pnpm" {
  if (existsSync(join(dir, "pnpm-lock.yaml"))) return "pnpm";
  if (existsSync(join(dir, "yarn.lock"))) return "yarn";
  if (existsSync(join(dir, "package-lock.json"))) return "npm";
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
  } catch (err: unknown) {
    const e = err as { stdout?: string; stderr?: string; message?: string };
    const combined = [e.stdout, e.stderr]
      .map((s: string | undefined) => (s ?? "").trim())
      .filter(Boolean)
      .join("\n") || e.message || String(err);
    throw new Error(`${pm} install failed in ${dir}: ${combined}`);
  }
}

/**
 * Run workflow setup steps in a worktree directory.
 *
 * Each step's `command` is split on whitespace to form an argv array and
 * executed via execFileAsync with `cwd` set to `dir`.
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

// ── Setup Cache (stack-agnostic) ─────────────────────────────────────────────

function computeCacheHash(worktreePath: string, keyFile: string): string | null {
  const keyPath = join(worktreePath, keyFile);
  if (!existsSync(keyPath)) return null;
  const content = readFileSync(keyPath);
  return createHash("sha256").update(content).digest("hex").slice(0, 16);
}

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

  try { await fs.rm(targetPath, { recursive: true, force: true }); } catch { /* ok */ }

  await fs.symlink(cachedPath, targetPath);
  console.error(`[setup-cache] Cache hit (${hash.slice(0, 8)}) — symlinked ${cache.path}`);
  return true;
}

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
  if (existsSync(join(cacheDir, ".complete"))) return;

  await fs.mkdir(cacheDir, { recursive: true });

  try { await fs.rm(cachedPath, { recursive: true, force: true }); } catch { /* ok */ }
  await fs.rename(sourcePath, cachedPath);
  await fs.symlink(cachedPath, sourcePath);
  await fs.writeFile(join(cacheDir, ".complete"), new Date().toISOString());
  console.error(`[setup-cache] Cached ${cache.path} (${hash.slice(0, 8)})`);
}

/**
 * Run setup steps with optional caching.
 */
export async function runSetupWithCache(
  worktreePath: string,
  projectRoot: string,
  steps: WorkflowSetupStep[],
  cache?: WorkflowSetupCache,
): Promise<void> {
  if (cache) {
    const restored = await tryRestoreFromCache(worktreePath, projectRoot, cache);
    if (restored) return;
  }

  await runSetupSteps(worktreePath, steps);

  if (cache) {
    await populateCache(worktreePath, projectRoot, cache);
  }
}

// ── VCS Shim Functions — delegate to GitBackend ───────────────────────────────

/**
 * Find the root of the git repository containing `path`.
 *
 * @deprecated Use `GitBackend.getRepoRoot()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function getRepoRoot(path: string): Promise<string> {
  const backend = new GitBackend(path);
  return backend.getRepoRoot(path);
}

/**
 * Find the main (primary) worktree root from any git worktree.
 *
 * @deprecated Use `GitBackend.getMainRepoRoot()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function getMainRepoRoot(path: string): Promise<string> {
  const backend = new GitBackend(path);
  return backend.getMainRepoRoot(path);
}

/**
 * Detect the default/parent branch for a repository.
 *
 * @deprecated Use `GitBackend.detectDefaultBranch()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function detectDefaultBranch(repoPath: string): Promise<string> {
  const backend = new GitBackend(repoPath);
  return backend.detectDefaultBranch(repoPath);
}

/**
 * Get the current branch name.
 *
 * @deprecated Use `GitBackend.getCurrentBranch()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function getCurrentBranch(repoPath: string): Promise<string> {
  const backend = new GitBackend(repoPath);
  return backend.getCurrentBranch(repoPath);
}

/**
 * Checkout a branch by name.
 *
 * @deprecated Use `GitBackend.checkoutBranch()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function checkoutBranch(repoPath: string, branchName: string): Promise<void> {
  const backend = new GitBackend(repoPath);
  return backend.checkoutBranch(repoPath, branchName);
}

/**
 * Create a worktree for a seed.
 *
 * - Branch: foreman/<seedId>
 * - Location: <repoPath>/.foreman-worktrees/<seedId>
 * - Base: current branch (auto-detected if not specified)
 *
 * @deprecated Use `GitBackend.createWorkspace()` from `src/lib/vcs/git-backend.js` instead.
 * Note: `createWorkspace()` returns `{ workspacePath, branchName }`. This shim maps
 * `workspacePath` → `worktreePath` for backward compatibility.
 */
export async function createWorktree(
  repoPath: string,
  seedId: string,
  baseBranch?: string,
  setupSteps?: WorkflowSetupStep[],
  setupCache?: WorkflowSetupCache,
): Promise<{ worktreePath: string; branchName: string }> {
  const backend = new GitBackend(repoPath);
  const result = await backend.createWorkspace(repoPath, seedId, baseBranch);
  const { workspacePath, branchName } = result;

  // Handle setup steps (not part of GitBackend.createWorkspace)
  if (setupSteps && setupSteps.length > 0) {
    await runSetupWithCache(workspacePath, repoPath, setupSteps, setupCache);
  } else {
    await installDependencies(workspacePath);
  }

  // Map workspacePath → worktreePath for old API shape
  return { worktreePath: workspacePath, branchName };
}

/**
 * Remove a worktree and prune stale entries.
 *
 * @deprecated Use `GitBackend.removeWorkspace()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function removeWorktree(
  repoPath: string,
  worktreePath: string,
): Promise<void> {
  const backend = new GitBackend(repoPath);
  return backend.removeWorkspace(repoPath, worktreePath);
}

/**
 * List all worktrees for the repo.
 *
 * @deprecated Use `GitBackend.listWorkspaces()` from `src/lib/vcs/git-backend.js` instead.
 * The `Worktree` type is a structural alias for `Workspace`; both have identical fields.
 */
export async function listWorktrees(repoPath: string): Promise<Worktree[]> {
  const backend = new GitBackend(repoPath);
  return backend.listWorkspaces(repoPath);
}

/**
 * Delete a local branch with merge-safety checks.
 *
 * @deprecated Use `GitBackend.deleteBranch()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function deleteBranch(
  repoPath: string,
  branchName: string,
  options?: { force?: boolean; targetBranch?: string },
): Promise<DeleteBranchResult> {
  const backend = new GitBackend(repoPath);
  return backend.deleteBranch(repoPath, branchName, options);
}

/**
 * Check whether a local branch exists in the repository.
 *
 * @deprecated Use `GitBackend.branchExists()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function gitBranchExists(
  repoPath: string,
  branchName: string,
): Promise<boolean> {
  const backend = new GitBackend(repoPath);
  return backend.branchExists(repoPath, branchName);
}

/**
 * Check whether a branch exists on the origin remote.
 *
 * @deprecated Use `GitBackend.branchExistsOnRemote()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function branchExistsOnOrigin(
  repoPath: string,
  branchName: string,
): Promise<boolean> {
  const backend = new GitBackend(repoPath);
  return backend.branchExistsOnRemote(repoPath, branchName);
}

/**
 * Merge a branch into the target branch.
 * Returns success status and any conflicting file paths.
 *
 * @deprecated Use `GitBackend.merge()` from `src/lib/vcs/git-backend.js` instead.
 */
export async function mergeWorktree(
  repoPath: string,
  branchName: string,
  targetBranch?: string,
): Promise<MergeResult> {
  const backend = new GitBackend(repoPath);
  return backend.merge(repoPath, branchName, targetBranch);
}
