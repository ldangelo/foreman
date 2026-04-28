import { createHash } from "node:crypto";
import { join } from "node:path";
import { existsSync, readFileSync } from "node:fs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";

import type { WorkflowSetupStep, WorkflowSetupCache } from "./workflow-loader.js";

const execFileAsync = promisify(execFile);

/**
 * Build an environment for spawned setup processes that includes common binary
 * directories in PATH.
 */
function buildSetupEnv(): NodeJS.ProcessEnv {
  const home = process.env.HOME ?? "/home/nobody";
  return {
    ...process.env,
    PATH: `${home}/.local/bin:/opt/homebrew/bin:${process.env.PATH ?? ""}`,
  };
}

/**
 * Detect which package manager to use based on lock files present in a directory.
 * Priority order: pnpm > yarn > npm.
 */
export function detectPackageManager(dir: string): "npm" | "yarn" | "pnpm" {
  if (existsSync(join(dir, "pnpm-lock.yaml"))) return "pnpm";
  if (existsSync(join(dir, "yarn.lock"))) return "yarn";
  if (existsSync(join(dir, "package-lock.json"))) return "npm";
  return "npm";
}

/**
 * Install Node.js dependencies in the given directory.
 */
export async function installDependencies(dir: string): Promise<void> {
  if (!existsSync(join(dir, "package.json"))) {
    return;
  }

  const pm = detectPackageManager(dir);
  console.error(`[setup] Running ${pm} install in ${dir} …`);

  const args: string[] =
    pm === "npm"
      ? ["install", "--prefer-offline", "--no-audit"]
      : pm === "yarn"
        ? ["install", "--prefer-offline"]
        : ["install", "--prefer-offline"];

  try {
    await execFileAsync(pm, args, { cwd: dir, maxBuffer: 10 * 1024 * 1024, env: buildSetupEnv() });
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
 * Run workflow setup steps in a workspace directory.
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
      await execFileAsync(cmd, args, { cwd: dir, maxBuffer: 10 * 1024 * 1024, env: buildSetupEnv() });
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

  try {
    const stat = await fs.lstat(cachedPath);
    if (stat.isDirectory()) {
      const entries = await fs.readdir(cachedPath);
      if (entries.length === 0) {
        await fs.rm(join(cacheDir, ".complete"), { force: true });
        await fs.rm(cachedPath, { recursive: true, force: true });
        return false;
      }
    }
  } catch {
    return false;
  }

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
