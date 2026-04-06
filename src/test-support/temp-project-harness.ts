import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { installBundledPrompts } from "../lib/prompt-loader.js";
import { ForemanStore, type Project } from "../lib/store.js";
import { NativeTaskStore, type TaskRow } from "../lib/task-store.js";
import { installBundledWorkflows } from "../lib/workflow-loader.js";
import { runTsxModule, type ExecResult } from "./tsx-subprocess.js";

const CLI_ENTRYPOINT = fileURLToPath(new URL("../cli/index.ts", import.meta.url));

export interface TempProjectHarnessOptions {
  projectName?: string;
  initialFiles?: Record<string, string>;
  installPrompts?: boolean;
  installWorkflows?: boolean;
}

export interface NativeTaskFixture {
  key?: string;
  title: string;
  description?: string | null;
  type?: string;
  priority?: number;
  status?: string;
  externalId?: string | null;
  dependsOn?: string[];
}

export interface SeededNativeTasks {
  tasks: TaskRow[];
  byKey: Record<string, TaskRow>;
}

export interface TempProjectHarness {
  projectRoot: string;
  project: Project;
  store: ForemanStore;
  taskStore: NativeTaskStore;
  git(args: string[], encoding?: BufferEncoding): string;
  readFile(relativePath: string): string;
  writeFile(relativePath: string, content: string): void;
  runCli(args: string[], opts?: { timeout?: number; env?: NodeJS.ProcessEnv }): Promise<ExecResult>;
  seedNativeTasks(fixtures: NativeTaskFixture[]): SeededNativeTasks;
  cleanup(): void;
}

function writeProjectFiles(projectRoot: string, files: Record<string, string>): void {
  for (const [relativePath, content] of Object.entries(files)) {
    const absolutePath = join(projectRoot, relativePath);
    mkdirSync(dirname(absolutePath), { recursive: true });
    writeFileSync(absolutePath, content, "utf-8");
  }
}

function initGitRepo(projectRoot: string, hasInitialFiles: boolean): void {
  execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectRoot, stdio: "ignore" });
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectRoot, stdio: "ignore" });
  execFileSync("git", ["config", "user.name", "Test User"], { cwd: projectRoot, stdio: "ignore" });

  if (hasInitialFiles) {
    execFileSync("git", ["add", "."], { cwd: projectRoot, stdio: "ignore" });
    execFileSync("git", ["commit", "-m", "initial fixture"], { cwd: projectRoot, stdio: "ignore" });
    return;
  }

  execFileSync("git", ["commit", "--allow-empty", "-m", "initial fixture"], {
    cwd: projectRoot,
    stdio: "ignore",
  });
}

export function createTempProjectHarness(
  opts: TempProjectHarnessOptions = {},
): TempProjectHarness {
  const projectRoot = mkdtempSync(join(tmpdir(), "foreman-smoke-harness-"));
  const initialFiles = opts.initialFiles ?? {};

  writeProjectFiles(projectRoot, initialFiles);
  initGitRepo(projectRoot, Object.keys(initialFiles).length > 0);

  if (opts.installPrompts !== false) {
    installBundledPrompts(projectRoot, true);
  }
  if (opts.installWorkflows !== false) {
    installBundledWorkflows(projectRoot, true);
  }

  const store = ForemanStore.forProject(projectRoot);
  const projectName = opts.projectName ?? "smoke-e2e-fixture";
  const project = store.getProjectByPath(projectRoot) ?? store.registerProject(projectName, projectRoot);
  const taskStore = new NativeTaskStore(store.getDb());

  const harness: TempProjectHarness = {
    projectRoot,
    project,
    store,
    taskStore,
    git(args, encoding = "utf-8") {
      return execFileSync("git", args, { cwd: projectRoot, encoding }).trim();
    },
    readFile(relativePath) {
      return readFileSync(join(projectRoot, relativePath), "utf-8");
    },
    writeFile(relativePath, content) {
      const absolutePath = join(projectRoot, relativePath);
      mkdirSync(dirname(absolutePath), { recursive: true });
      writeFileSync(absolutePath, content, "utf-8");
    },
    runCli(args, runOpts) {
      return runTsxModule(CLI_ENTRYPOINT, args, {
        cwd: projectRoot,
        timeout: runOpts?.timeout,
        env: runOpts?.env,
      });
    },
    seedNativeTasks(fixtures) {
      const createdByKey = new Map<string, TaskRow>();
      const createdInOrder = fixtures.map((fixture, index) => {
        const task = taskStore.create({
          title: fixture.title,
          description: fixture.description ?? null,
          type: fixture.type ?? "task",
          priority: fixture.priority,
          externalId: fixture.externalId ?? null,
        });
        const key = fixture.key ?? `task-${index + 1}`;
        createdByKey.set(key, task);
        return { fixture, key, task };
      });

      for (const entry of createdInOrder) {
        for (const dependencyKey of entry.fixture.dependsOn ?? []) {
          const blocker = createdByKey.get(dependencyKey);
          if (!blocker) {
            throw new Error(`Unknown dependency key '${dependencyKey}' for fixture '${entry.key}'`);
          }
          taskStore.addDependency(entry.task.id, blocker.id);
        }
      }

      for (const entry of createdInOrder) {
        const desiredStatus = entry.fixture.status ?? ((entry.fixture.dependsOn?.length ?? 0) > 0 ? "blocked" : "backlog");
        if (desiredStatus === "ready") {
          taskStore.approve(entry.task.id);
        } else if (desiredStatus !== "backlog") {
          taskStore.updateStatus(entry.task.id, desiredStatus);
        }
      }

      const byKey = Object.fromEntries(
        Array.from(createdByKey.entries()).map(([key, task]) => {
          const refreshed = taskStore.get(task.id);
          if (!refreshed) {
            throw new Error(`Task '${task.id}' disappeared while seeding fixtures`);
          }
          return [key, refreshed];
        }),
      );

      return {
        tasks: createdInOrder.map(({ task }) => {
          const refreshed = taskStore.get(task.id);
          if (!refreshed) {
            throw new Error(`Task '${task.id}' disappeared while collecting seeded fixtures`);
          }
          return refreshed;
        }),
        byKey,
      };
    },
    cleanup() {
      try {
        store.close();
      } finally {
        if (existsSync(projectRoot)) {
          rmSync(projectRoot, { recursive: true, force: true });
        }
      }
    },
  };

  return harness;
}
