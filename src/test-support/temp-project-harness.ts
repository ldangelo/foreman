import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../lib/store.js";
import { NativeTaskClient } from "../lib/native-task-client.js";
import { NativeTaskStore } from "../lib/task-store.js";
import { installBundledPrompts } from "../lib/prompt-loader.js";
import { installBundledWorkflows } from "../lib/workflow-loader.js";
import { autoMerge } from "../orchestrator/auto-merge.js";

interface SeedTaskOptions {
  title: string;
  type?: string;
  priority?: number;
  scenario?: Record<string, unknown>;
  approved?: boolean;
}

export interface TempProjectHarness {
  projectPath: string;
  cleanup(): void;
  seedTask(opts: SeedTaskOptions): Promise<string>;
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

function isRetryableStoreError(err: unknown): boolean {
  const message = err instanceof Error ? err.message : String(err);
  return /disk I\/O error|database is locked|SQLITE_BUSY|SQLITE_IOERR/i.test(message);
}

function readLogTail(homeDir: string | undefined): string {
  if (!homeDir) return "";
  const logDir = join(homeDir, ".foreman", "logs");
  if (!existsSync(logDir)) return "";
  const files = readdirSync(logDir).filter((name) => name.endsWith(".err") || name.endsWith(".out")).sort();
  const selected = files.slice(-4);
  return selected.map((name) => {
    const fullPath = join(logDir, name);
    const content = readFileSync(fullPath, "utf-8");
    return `--- ${name} ---\n${content.slice(-4000)}`;
  }).join("\n");
}

async function withStore<T>(projectPath: string, fn: (store: ForemanStore, taskStore: NativeTaskStore) => T | Promise<T>): Promise<T> {
  let lastError: unknown;
  for (let attempt = 1; attempt <= 5; attempt++) {
    try {
      const store = ForemanStore.forProject(projectPath);
      try {
        return await fn(store, new NativeTaskStore(store.getDb()));
      } finally {
        store.close();
      }
    } catch (err) {
      lastError = err;
      if (attempt === 5 || !isRetryableStoreError(err)) {
        throw err;
      }
      await sleep(200);
    }
  }
  throw lastError;
}

function initGitRepo(projectPath: string): void {
  execFileSync("git", ["init", "-b", "main"], { cwd: projectPath, stdio: "pipe" });
  execFileSync("git", ["config", "user.email", "foreman-test@example.com"], { cwd: projectPath, stdio: "pipe" });
  execFileSync("git", ["config", "user.name", "Foreman Test"], { cwd: projectPath, stdio: "pipe" });

  writeFileSync(
    join(projectPath, "package.json"),
    JSON.stringify(
      {
        name: "foreman-temp-project",
        private: true,
        version: "0.0.0",
        scripts: {
          test: "node -e \"process.exit(0)\"",
        },
      },
      null,
      2,
    ),
    "utf-8",
  );
  writeFileSync(join(projectPath, "README.md"), "# temp project\n", "utf-8");
  writeFileSync(join(projectPath, "test.txt"), "base\n", "utf-8");
  execFileSync("git", ["add", "-A"], { cwd: projectPath, stdio: "pipe" });
  execFileSync("git", ["commit", "-m", "Initial commit"], { cwd: projectPath, stdio: "pipe" });
}

export function createTempProjectHarness(): TempProjectHarness {
  const projectPath = realpathSync(mkdtempSync(join(tmpdir(), "foreman-e2e-project-")));
  mkdirSync(join(projectPath, ".foreman"), { recursive: true });
  initGitRepo(projectPath);
  installBundledPrompts(projectPath, true);
  installBundledWorkflows(projectPath, true);

  void withStore(projectPath, (store) => {
    store.registerProject("temp-project", projectPath);
  });

  return {
    projectPath,
    cleanup() {
      rmSync(projectPath, { recursive: true, force: true });
    },
    seedTask(opts) {
      return withStore(projectPath, (_store, taskStore) => {
        const description = opts.scenario
          ? `FOREMAN_TEST_SCENARIO=${JSON.stringify(opts.scenario)}`
          : undefined;
        const task = taskStore.create({
          title: opts.title,
          description,
          type: opts.type ?? "smoke",
          priority: opts.priority ?? 1,
        });
        if (opts.approved !== false) {
          taskStore.approve(task.id);
        }
        return task.id;
      });
    },
    addDependency(blockedTaskId, blockerTaskId) {
      return withStore(projectPath, (_store, taskStore) => {
        taskStore.update(blockedTaskId, { status: "blocked", force: true });
        taskStore.addDependency(blockedTaskId, blockerTaskId, "blocks");
      });
    },
    getTaskStatus(taskId) {
      return withStore(projectPath, (_store, taskStore) => taskStore.get(taskId)?.status ?? null);
    },
    getRunStatuses() {
      return withStore(projectPath, (store) =>
        (
          store.getDb().prepare("SELECT status FROM runs ORDER BY created_at DESC, rowid DESC").all() as Array<{ status: string }>
        ).map((row) => row.status)
      );
    },
    async waitForRunCount(count, timeoutMs = 30_000) {
      const start = Date.now();
      while (Date.now() - start < timeoutMs) {
        const runCount = withStore(
          projectPath,
          (store) => (store.getDb().prepare("SELECT COUNT(*) as count FROM runs").get() as { count: number }).count,
        );
        if (await runCount >= count) return;
        await sleep(200);
      }
      throw new Error(
        `Timed out waiting for ${count} run(s)\n${readLogTail(process.env.HOME)}`,
      );
    },
    async waitForTerminalRuns(count, timeoutMs = 60_000) {
      const terminalStatuses = new Set(["merged", "failed", "conflict", "completed", "test-failed", "pr-created"]);
      const start = Date.now();
      while (Date.now() - start < timeoutMs) {
        const runs = withStore(
          projectPath,
          (store) => store.getDb().prepare("SELECT status FROM runs ORDER BY created_at ASC, rowid ASC").all() as Array<{ status: string }>,
        );
        const resolvedRuns = await runs;
        if (resolvedRuns.length >= count && resolvedRuns.slice(0, count).every((run) => terminalStatuses.has(run.status))) {
          return;
        }
        await sleep(250);
      }
      const resolvedStatuses = (await this.getRunStatuses()).join(", ");
      throw new Error(
        `Timed out waiting for ${count} terminal run(s). Current statuses: ${resolvedStatuses}\n${readLogTail(process.env.HOME)}`,
      );
    },
    async drainMergeQueue() {
      await withStore(projectPath, async (store) => {
        await autoMerge({
          store,
          taskClient: new NativeTaskClient(projectPath),
          projectPath,
        });
      });
    },
    readRepoFile(relativePath) {
      return readFileSync(join(projectPath, relativePath), "utf-8");
    },
  };
}
