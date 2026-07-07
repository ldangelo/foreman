import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { NativeTaskClient } from "../lib/native-task-client.js";
import { ForemanStore } from "../lib/store.js";
import { NativeTaskStore } from "../lib/task-store.js";
import { installBundledPrompts } from "../lib/prompt-loader.js";
import { installBundledWorkflows } from "../lib/workflow-loader.js";
import { autoMerge } from "../orchestrator/auto-merge.js";

interface TaskTaskOptions {
  title: string;
  type?: string;
  priority?: number;
  scenario?: Record<string, unknown>;
  approved?: boolean;
}

export interface TempProjectHarness {
  projectPath: string;
  cleanup(): void;
  taskTask(opts: TaskTaskOptions): Promise<string>;
  addDependency(blockedTaskId: string, blockerTaskId: string): Promise<void>;
  getTaskStatus(taskId: string): Promise<string | null>;
  getRunStatuses(): Promise<string[]>;
  waitForRunCount(count: number, timeoutMs?: number): Promise<void>;
  waitForTerminalRuns(count: number, timeoutMs?: number): Promise<void>;
  drainMergeQueue(): Promise<void>;
  readRepoFile(relativePath: string): string;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function readLogTail(homeDir: string | undefined): string {
  if (!homeDir) return "";
  const logDir = join(homeDir, ".foreman", "logs");
  if (!existsSync(logDir)) return "";
  const files = readdirSync(logDir).filter((name) => name.endsWith(".err") || name.endsWith(".out")).sort();
  return files.slice(-4).map((name) => `--- ${name} ---\n${readFileSync(join(logDir, name), "utf-8").slice(-4000)}`).join("\n");
}

async function withRetry<T>(fn: () => T | Promise<T>): Promise<T> {
  let lastError: unknown;
  for (let attempt = 1; attempt <= 5; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastError = err;
      const message = err instanceof Error ? err.message : String(err);
      if (attempt === 5 || !/disk I\/O error|database is locked|busy|ioerr/i.test(message)) throw err;
      await sleep(200);
    }
  }
  throw lastError;
}

function initGitRepo(projectPath: string): void {
  execFileSync("git", ["init", "-b", "main"], { cwd: projectPath, stdio: "pipe" });
  execFileSync("git", ["config", "user.email", "foreman-test@example.com"], { cwd: projectPath, stdio: "pipe" });
  execFileSync("git", ["config", "user.name", "Foreman Test"], { cwd: projectPath, stdio: "pipe" });
  writeFileSync(join(projectPath, "package.json"), JSON.stringify({ name: "foreman-temp-project", private: true, version: "0.0.0", scripts: { test: "node -e \"process.exit(0)\"" } }, null, 2), "utf-8");
  writeFileSync(join(projectPath, "README.md"), "# temp project\n", "utf-8");
  writeFileSync(join(projectPath, "test.txt"), "base\n", "utf-8");
  execFileSync("git", ["add", "-A"], { cwd: projectPath, stdio: "pipe" });
  execFileSync("git", ["commit", "-m", "Initial commit"], { cwd: projectPath, stdio: "pipe" });
}

function initGitRemote(projectPath: string): void {
  const remotePath = mkdtempSync(join(tmpdir(), "foreman-e2e-remote-"));
  execFileSync("git", ["init", "--bare", remotePath], { stdio: "pipe" });
  execFileSync("git", ["remote", "add", "origin", remotePath], { cwd: projectPath, stdio: "pipe" });
  execFileSync("git", ["push", "-u", "origin", "main"], { cwd: projectPath, stdio: "pipe" });
}

function syncLocalMainFromOrigin(projectPath: string): void {
  execFileSync("git", ["fetch", "origin", "+refs/heads/main:refs/remotes/origin/main"], { cwd: projectPath, stdio: "pipe" });
  execFileSync("git", ["checkout", "main"], { cwd: projectPath, stdio: "pipe" });
  execFileSync("git", ["reset", "--hard", "origin/main"], { cwd: projectPath, stdio: "pipe" });
}

function removeDirWithRetries(dirPath: string): void {
  rmSync(dirPath, { recursive: true, force: true, maxRetries: 20, retryDelay: 250 });
}

export async function createTempProjectHarness(): Promise<TempProjectHarness> {
  const projectPath = realpathSync(mkdtempSync(join(tmpdir(), "foreman-e2e-project-")));
  mkdirSync(join(projectPath, ".foreman"), { recursive: true });
  initGitRepo(projectPath);
  initGitRemote(projectPath);
  installBundledPrompts(projectPath, true);
  installBundledWorkflows(projectPath, true);

  const store = ForemanStore.forProject(projectPath);
  const taskStore = new NativeTaskStore(store.getDb());
  const project = store.registerProject(`temp-project-${projectPath.split("-").pop()}`, projectPath);
  const registryBaseDir = process.env.FOREMAN_REGISTRY_BASE_DIR ?? join(process.env.HOME ?? tmpdir(), ".foreman");
  const registryDir = join(registryBaseDir, "projects");
  mkdirSync(registryDir, { recursive: true });
  writeFileSync(join(registryDir, "projects.json"), JSON.stringify([{ id: project.id, name: project.name, path: project.path, githubUrl: "", repoKey: null, defaultBranch: "main", status: "paused", createdAt: project.created_at, updatedAt: project.updated_at, lastSyncAt: null }], null, 2), "utf-8");

  const allStatuses = ["pending", "running", "completed", "failed", "stuck", "test-failed", "conflict", "merged", "pr-created"] as const;
  const getRuns = () => store.getRunsByStatuses([...allStatuses] as never, project.id);
  const getRunStatuses = () => withRetry(() => getRuns().map((run) => run.status));

  return {
    projectPath,
    cleanup() {
      store.close();
      removeDirWithRetries(projectPath);
    },
    taskTask(opts) {
      return withRetry(() => {
        const description = opts.scenario ? `FOREMAN_TEST_SCENARIO=${JSON.stringify(opts.scenario)}` : undefined;
        const task = taskStore.create({ title: opts.title, description, type: opts.type ?? "smoke", priority: opts.priority ?? 1 });
        if (opts.approved !== false) taskStore.update(task.id, { status: "ready" });
        return task.id;
      });
    },
    addDependency(blockedTaskId, blockerTaskId) {
      return withRetry(() => {
        taskStore.update(blockedTaskId, { status: "blocked" });
        taskStore.addDependency(blockedTaskId, blockerTaskId, "blocks");
      });
    },
    getTaskStatus(taskId) {
      return withRetry(() => taskStore.get(taskId)?.status ?? null);
    },
    getRunStatuses,
    async waitForRunCount(count, timeoutMs = 30_000) {
      const start = Date.now();
      while (Date.now() - start < timeoutMs) {
        if (getRuns().length >= count) return;
        await sleep(200);
      }
      throw new Error(`Timed out waiting for ${count} run(s)\n${readLogTail(process.env.HOME)}`);
    },
    async waitForTerminalRuns(count, timeoutMs = 60_000) {
      const terminalStatuses = new Set(["merged", "failed", "conflict", "completed", "test-failed", "pr-created"]);
      const start = Date.now();
      while (Date.now() - start < timeoutMs) {
        const runs = getRuns().slice().reverse();
        if (runs.length >= count && runs.slice(0, count).every((run) => terminalStatuses.has(run.status))) return;
        await sleep(250);
      }
      throw new Error(`Timed out waiting for ${count} terminal run(s). Current statuses: ${(await getRunStatuses()).join(", ")}\n${readLogTail(process.env.HOME)}`);
    },
    async drainMergeQueue() {
      await autoMerge({ store: store as never, taskClient: new NativeTaskClient(projectPath), projectPath });
      syncLocalMainFromOrigin(projectPath);
    },
    readRepoFile(relativePath) {
      return readFileSync(join(projectPath, relativePath), "utf-8");
    },
  };
}
