import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { NativeTaskClient } from "../lib/native-task-client.js";
import { installBundledPrompts } from "../lib/prompt-loader.js";
import { installBundledWorkflows } from "../lib/workflow-loader.js";
import { autoMerge } from "../orchestrator/auto-merge.js";
import { initPool, isPoolInitialised } from "../lib/db/pool-manager.js";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import { PostgresStore } from "../lib/postgres-store.js";
import { startPostgresTestcontainer } from "./postgres-testcontainer.js";
function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}
function isRetryableStoreError(err) {
    const message = err instanceof Error ? err.message : String(err);
    return /disk I\/O error|database is locked|busy|ioerr/i.test(message);
}
function readLogTail(homeDir) {
    if (!homeDir)
        return "";
    const logDir = join(homeDir, ".foreman", "logs");
    if (!existsSync(logDir))
        return "";
    const files = readdirSync(logDir).filter((name) => name.endsWith(".err") || name.endsWith(".out")).sort();
    const selected = files.slice(-4);
    return selected.map((name) => {
        const fullPath = join(logDir, name);
        const content = readFileSync(fullPath, "utf-8");
        return `--- ${name} ---\n${content.slice(-4000)}`;
    }).join("\n");
}
async function withRetry(fn) {
    let lastError;
    for (let attempt = 1; attempt <= 5; attempt++) {
        try {
            return await fn();
        }
        catch (err) {
            lastError = err;
            if (attempt === 5 || !isRetryableStoreError(err)) {
                throw err;
            }
            await sleep(200);
        }
    }
    throw lastError;
}
async function ensureTestDatabase(projectPath) {
    const databaseUrl = process.env.DATABASE_URL ?? await startPostgresTestcontainer();
    if (!isPoolInitialised()) {
        initPool({ databaseUrl });
    }
    writeFileSync(join(projectPath, ".env"), `DATABASE_URL=${databaseUrl}\n`, "utf-8");
    return databaseUrl;
}
function initGitRepo(projectPath) {
    execFileSync("git", ["init", "-b", "main"], { cwd: projectPath, stdio: "pipe" });
    execFileSync("git", ["config", "user.email", "foreman-test@example.com"], { cwd: projectPath, stdio: "pipe" });
    execFileSync("git", ["config", "user.name", "Foreman Test"], { cwd: projectPath, stdio: "pipe" });
    writeFileSync(join(projectPath, "package.json"), JSON.stringify({
        name: "foreman-temp-project",
        private: true,
        version: "0.0.0",
        scripts: {
            test: "node -e \"process.exit(0)\"",
        },
    }, null, 2), "utf-8");
    writeFileSync(join(projectPath, "README.md"), "# temp project\n", "utf-8");
    writeFileSync(join(projectPath, "test.txt"), "base\n", "utf-8");
    execFileSync("git", ["add", "-A"], { cwd: projectPath, stdio: "pipe" });
    execFileSync("git", ["commit", "-m", "Initial commit"], { cwd: projectPath, stdio: "pipe" });
}
function initGitRemote(projectPath) {
    const remotePath = mkdtempSync(join(tmpdir(), "foreman-e2e-remote-"));
    execFileSync("git", ["init", "--bare", remotePath], { stdio: "pipe" });
    execFileSync("git", ["remote", "add", "origin", remotePath], { cwd: projectPath, stdio: "pipe" });
    execFileSync("git", ["push", "-u", "origin", "main"], { cwd: projectPath, stdio: "pipe" });
}
function syncLocalMainFromOrigin(projectPath) {
    execFileSync("git", ["fetch", "origin", "+refs/heads/main:refs/remotes/origin/main"], { cwd: projectPath, stdio: "pipe" });
    execFileSync("git", ["checkout", "main"], { cwd: projectPath, stdio: "pipe" });
    execFileSync("git", ["reset", "--hard", "origin/main"], { cwd: projectPath, stdio: "pipe" });
}
function sleepSync(ms) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}
function removeDirWithRetries(dirPath) {
    let lastError;
    for (let attempt = 1; attempt <= 60; attempt++) {
        try {
            rmSync(dirPath, {
                recursive: true,
                force: true,
                maxRetries: 5,
                retryDelay: 250,
            });
            return;
        }
        catch (err) {
            lastError = err;
            sleepSync(250);
        }
    }
    throw lastError;
}
export async function createTempProjectHarness() {
    const projectPath = realpathSync(mkdtempSync(join(tmpdir(), "foreman-e2e-project-")));
    mkdirSync(join(projectPath, ".foreman"), { recursive: true });
    initGitRepo(projectPath);
    initGitRemote(projectPath);
    await ensureTestDatabase(projectPath);
    installBundledPrompts(projectPath, true);
    installBundledWorkflows(projectPath, true);
    const adapter = new PostgresAdapter();
    const projectName = `temp-project-${projectPath.split("-").pop()}`;
    const project = await adapter.createProject({
        name: projectName,
        path: projectPath,
        defaultBranch: "main",
        // Keep harness projects out of the real daemon's auto-dispatch loop when
        // tests reuse a developer DATABASE_URL while the daemon is running. Tests
        // address projects directly through the registry/project id, so they do
        // not need active-project daemon polling.
        status: "paused",
    });
    const registryBaseDir = process.env.FOREMAN_REGISTRY_BASE_DIR ?? join(process.env.HOME ?? tmpdir(), ".foreman");
    const registryDir = join(registryBaseDir, "projects");
    mkdirSync(registryDir, { recursive: true });
    writeFileSync(join(registryDir, "projects.json"), JSON.stringify([
        {
            id: project.id,
            name: project.name,
            path: project.path,
            githubUrl: project.github_url ?? "",
            repoKey: project.repo_key ?? null,
            defaultBranch: project.default_branch ?? "main",
            status: project.status ?? "active",
            createdAt: project.created_at,
            updatedAt: project.updated_at,
            lastSyncAt: project.last_sync_at ?? null,
        },
    ], null, 2), "utf-8");
    const getRunStatuses = () => withRetry(async () => (await adapter.listRuns(project.id, { limit: 1000 })).map((row) => row.status));
    const store = new PostgresStore(project.id, adapter);
    return {
        projectPath,
        cleanup() {
            removeDirWithRetries(projectPath);
        },
        seedTask(opts) {
            return withRetry(async () => {
                const description = opts.scenario
                    ? `FOREMAN_TEST_SCENARIO=${JSON.stringify(opts.scenario)}`
                    : undefined;
                const task = await adapter.createTask(project.id, {
                    title: opts.title,
                    description,
                    type: opts.type ?? "smoke",
                    priority: opts.priority ?? 1,
                });
                if (opts.approved !== false) {
                    await adapter.approveTask(project.id, task.id);
                }
                return task.id;
            });
        },
        addDependency(blockedTaskId, blockerTaskId) {
            return withRetry(async () => {
                await adapter.updateTask(project.id, blockedTaskId, { status: "blocked" });
                await adapter.addTaskDependency(project.id, blockedTaskId, blockerTaskId, "blocks");
            });
        },
        getTaskStatus(taskId) {
            return withRetry(async () => (await adapter.getTask(project.id, taskId))?.status ?? null);
        },
        getRunStatuses,
        async waitForRunCount(count, timeoutMs = 30_000) {
            const start = Date.now();
            while (Date.now() - start < timeoutMs) {
                const runCount = (await adapter.listRuns(project.id, { limit: 1000 })).length;
                if (runCount >= count)
                    return;
                await sleep(200);
            }
            throw new Error(`Timed out waiting for ${count} run(s)\n${readLogTail(process.env.HOME)}`);
        },
        async waitForTerminalRuns(count, timeoutMs = 60_000) {
            const terminalStatuses = new Set(["merged", "failed", "conflict", "completed", "test-failed", "pr-created"]);
            const start = Date.now();
            while (Date.now() - start < timeoutMs) {
                const resolvedRuns = (await adapter.listRuns(project.id, { limit: 1000 })).slice().reverse();
                if (resolvedRuns.length >= count && resolvedRuns.slice(0, count).every((run) => terminalStatuses.has(run.status))) {
                    return;
                }
                await sleep(250);
            }
            const resolvedStatuses = (await getRunStatuses()).join(", ");
            throw new Error(`Timed out waiting for ${count} terminal run(s). Current statuses: ${resolvedStatuses}\n${readLogTail(process.env.HOME)}`);
        },
        async drainMergeQueue() {
            await autoMerge({
                store: store,
                taskClient: new NativeTaskClient(projectPath, { registeredProjectId: project.id }),
                projectPath,
                registeredProjectId: project.id,
            });
            syncLocalMainFromOrigin(projectPath);
        },
        readRepoFile(relativePath) {
            return readFileSync(join(projectPath, relativePath), "utf-8");
        },
    };
}
//# sourceMappingURL=temp-project-harness.js.map