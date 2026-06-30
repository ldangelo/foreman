import { createHash } from "node:crypto";
import { join } from "node:path";
import { existsSync, readFileSync } from "node:fs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
const execFileAsync = promisify(execFile);
/**
 * Build an environment for spawned setup processes that includes common binary
 * directories in PATH.
 */
function buildSetupEnv() {
    const home = process.env.HOME ?? "/home/nobody";
    return {
        ...process.env,
        PATH: `${home}/.local/bin:/opt/homebrew/bin:${process.env.PATH ?? ""}`,
    };
}
/**
 * Run a workspace lifecycle hook command.
 *
 * Executes the given shell command in the workspace directory with the
 * specified environment variables and timeout.
 *
 * @param hookCmd - Shell command to execute (e.g., "git clone https://github.com/org/repo.git")
 * @param workspacePath - Working directory for the hook
 * @param env - Additional environment variables to pass (FOREMAN_WORKSPACE_PATH etc.)
 * @param timeoutMs - Timeout in milliseconds (default: 60000)
 * @param label - Descriptive label for logging (e.g., "afterCreate", "beforeRun")
 * @returns Promise<HookResult> with success flag, combined stdout/stderr, and timedOut flag
 *
 * Hook commands run through the platform shell so quoted arguments,
 * environment expansion, pipes, redirection, and command chaining behave like
 * the examples in project config.
 */
export async function runHook(hookCmd, workspacePath, env, timeoutMs = 60_000, label = "hook") {
    const command = hookCmd.trim();
    if (!command) {
        return { success: true, output: "", timedOut: false };
    }
    console.error(`[hooks] Running ${label}: ${hookCmd} (cwd: ${workspacePath}, timeout: ${timeoutMs}ms)`);
    const hookEnv = { ...buildSetupEnv(), ...env };
    try {
        const { stdout, stderr } = await execFileAsync(command, {
            cwd: workspacePath,
            maxBuffer: 10 * 1024 * 1024,
            env: hookEnv,
            timeout: timeoutMs,
            shell: true,
        });
        const output = [stdout, stderr].map((s) => (s ?? "").trim()).filter(Boolean).join("\n");
        console.error(`[hooks] ${label} completed successfully`);
        return { success: true, output, timedOut: false };
    }
    catch (err) {
        const e = err;
        const errMsg = err instanceof Error ? err.message : String(err);
        const timedOut = e.code === "ETIMEDOUT" ||
            e.killed === true ||
            e.signal === "SIGTERM" ||
            errMsg.toLowerCase().includes("timeout") ||
            errMsg.includes("timed out");
        const output = [e.stdout, e.stderr].map((s) => (s ?? "").trim()).filter(Boolean).join("\n") || errMsg;
        console.error(`[hooks] ${label} ${timedOut ? "timed out" : "failed"}: ${output.slice(0, 300)}`);
        return { success: false, output, timedOut };
    }
}
/**
 * Run workspace lifecycle hooks for a given stage.
 *
 * @param hooks - WorkspaceHooks configuration
 * @param stage - One of: afterCreate, beforeRun, afterRun, beforeRemove
 * @param workspacePath - Working directory for the hooks
 * @param env - Environment variables to pass to hooks
 * @returns Promise that resolves when all hooks for the stage complete
 * @throws Error if afterCreate or beforeRun hooks fail (fatal stages)
 */
export async function runWorkspaceHook(hooks, stage, workspacePath, env) {
    const hookCmd = hooks[stage];
    if (!hookCmd)
        return;
    const timeoutMs = hooks.timeoutMs ?? 60_000;
    const result = await runHook(hookCmd, workspacePath, env, timeoutMs, stage);
    // Fatal stages: afterCreate, beforeRun — throw on failure
    if (!result.success && (stage === "afterCreate" || stage === "beforeRun")) {
        throw new Error(`Workspace hook '${stage}' failed: ${result.output}`);
    }
    // Non-fatal stages: afterRun, beforeRemove — log but don't throw
    // (already logged in runHook)
}
/**
 * Detect which package manager to use based on lock files present in a directory.
 * Priority order: pnpm > yarn > npm.
 */
export function detectPackageManager(dir) {
    if (existsSync(join(dir, "pnpm-lock.yaml")))
        return "pnpm";
    if (existsSync(join(dir, "yarn.lock")))
        return "yarn";
    if (existsSync(join(dir, "package-lock.json")))
        return "npm";
    return "npm";
}
/**
 * Install Node.js dependencies in the given directory.
 */
export async function installDependencies(dir) {
    if (!existsSync(join(dir, "package.json"))) {
        return;
    }
    const pm = detectPackageManager(dir);
    console.error(`[setup] Running ${pm} install in ${dir} …`);
    const args = pm === "npm"
        ? ["install", "--prefer-offline", "--no-audit"]
        : pm === "yarn"
            ? ["install", "--prefer-offline"]
            : ["install", "--prefer-offline"];
    try {
        await execFileAsync(pm, args, { cwd: dir, maxBuffer: 10 * 1024 * 1024, env: buildSetupEnv() });
    }
    catch (err) {
        const e = err;
        const combined = [e.stdout, e.stderr]
            .map((s) => (s ?? "").trim())
            .filter(Boolean)
            .join("\n") || e.message || String(err);
        throw new Error(`${pm} install failed in ${dir}: ${combined}`);
    }
}
/**
 * Run workflow setup steps in a workspace directory.
 */
export async function runSetupSteps(dir, steps) {
    for (const step of steps) {
        const label = step.description ?? step.command;
        console.error(`[setup] Running: ${step.command}`);
        const argv = step.command.trim().split(/\s+/);
        const [cmd, ...args] = argv;
        try {
            await execFileAsync(cmd, args, { cwd: dir, maxBuffer: 10 * 1024 * 1024, env: buildSetupEnv() });
        }
        catch (err) {
            const e = err;
            const joined = [e.stdout, e.stderr]
                .map((s) => (s ?? "").trim())
                .filter(Boolean)
                .join("\n");
            const combined = joined || (e.message ?? String(err));
            if (step.failFatal !== false) {
                throw new Error(`Setup step failed (${label}): ${combined}`);
            }
            else {
                console.error(`[setup] Warning: step failed (non-fatal) — ${label}: ${combined}`);
            }
        }
    }
}
function computeCacheHash(worktreePath, keyFile) {
    const keyPath = join(worktreePath, keyFile);
    if (!existsSync(keyPath))
        return null;
    const content = readFileSync(keyPath);
    return createHash("sha256").update(content).digest("hex").slice(0, 16);
}
async function invalidateCache(cacheDir, cachedPath) {
    await fs.rm(join(cacheDir, ".complete"), { force: true });
    await fs.rm(cachedPath, { recursive: true, force: true });
}
async function isValidCachedPath(cachedPath, cache) {
    const stat = await fs.lstat(cachedPath);
    if (!stat.isDirectory())
        return true;
    const entries = await fs.readdir(cachedPath);
    if (entries.length === 0)
        return false;
    if (cache.path === "node_modules" && cache.key === "package-lock.json") {
        return existsSync(join(cachedPath, ".package-lock.json"));
    }
    return true;
}
async function tryRestoreFromCache(worktreePath, projectRoot, cache) {
    const hash = computeCacheHash(worktreePath, cache.key);
    if (!hash)
        return false;
    const cacheDir = join(projectRoot, ".foreman", "setup-cache", hash);
    const cachedPath = join(cacheDir, cache.path);
    const targetPath = join(worktreePath, cache.path);
    if (!existsSync(join(cacheDir, ".complete")))
        return false;
    if (!existsSync(cachedPath))
        return false;
    try {
        if (!(await isValidCachedPath(cachedPath, cache))) {
            await invalidateCache(cacheDir, cachedPath);
            return false;
        }
    }
    catch {
        return false;
    }
    try {
        await fs.rm(targetPath, { recursive: true, force: true });
    }
    catch { /* ok */ }
    await fs.symlink(cachedPath, targetPath);
    console.error(`[setup-cache] Cache hit (${hash.slice(0, 8)}) — symlinked ${cache.path}`);
    return true;
}
async function populateCache(worktreePath, projectRoot, cache) {
    const hash = computeCacheHash(worktreePath, cache.key);
    if (!hash)
        return;
    const cacheDir = join(projectRoot, ".foreman", "setup-cache", hash);
    const sourcePath = join(worktreePath, cache.path);
    const cachedPath = join(cacheDir, cache.path);
    if (!existsSync(sourcePath))
        return;
    if (existsSync(join(cacheDir, ".complete")))
        return;
    await fs.mkdir(cacheDir, { recursive: true });
    try {
        await fs.rm(cachedPath, { recursive: true, force: true });
    }
    catch { /* ok */ }
    await fs.rename(sourcePath, cachedPath);
    await fs.symlink(cachedPath, sourcePath);
    await fs.writeFile(join(cacheDir, ".complete"), new Date().toISOString());
    console.error(`[setup-cache] Cached ${cache.path} (${hash.slice(0, 8)})`);
}
/**
 * Run setup steps with optional caching.
 */
export async function runSetupWithCache(worktreePath, projectRoot, steps, cache) {
    if (cache) {
        const restored = await tryRestoreFromCache(worktreePath, projectRoot, cache);
        if (restored)
            return;
    }
    await runSetupSteps(worktreePath, steps);
    if (cache) {
        await populateCache(worktreePath, projectRoot, cache);
    }
}
//# sourceMappingURL=setup.js.map