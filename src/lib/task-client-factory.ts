import { NativeTaskClient } from "./native-task-client.js";
import { PostgresAdapter } from "./db/postgres-adapter.js";
import { initPool, isPoolInitialised } from "./db/pool-manager.js";
import { resolveProjectDatabaseUrl } from "./project-mail-client.js";
import { ProjectRegistry } from "./project-registry.js";
import { ForemanStore } from "./store.js";
import type { ITaskClient } from "./task-client.js";

export type TaskClientBackend = "native";

export interface TaskClientFactoryResult {
  backendType: TaskClientBackend;
  taskClient: ITaskClient;
}

export interface TaskClientFactoryOptions {
  registeredProjectId?: string;
}

export interface TaskCounts {
  total: number;
  ready: number;
  inProgress: number;
  completed: number;
  blocked: number;
}

const NATIVE_TOTAL_STATUSES = [
  "backlog",
  "ready",
  "in-progress",
  "merged",
  "closed",
  "conflict",
  "failed",
  "stuck",
  "blocked",
] as const;

const NATIVE_BLOCKED_STATUSES = [
  "backlog",
  "conflict",
  "failed",
  "stuck",
  "blocked",
] as const;

async function resolveRegisteredProject(
  projectPath: string,
  registeredProjectId?: string,
): Promise<{ id: string; path: string } | null> {
  const databaseUrl = resolveProjectDatabaseUrl(projectPath);
  if (databaseUrl && !isPoolInitialised()) {
    try {
      initPool({ databaseUrl });
    } catch {
      // Best effort only — callers fall back to local behavior when the pool is unavailable.
    }
  }

  const registries = databaseUrl
    ? [new ProjectRegistry({ pg: new PostgresAdapter() }), new ProjectRegistry()]
    : [new ProjectRegistry()];

  for (const registry of registries) {
    try {
      const projects = await registry.list();
      if (registeredProjectId) {
        const byId = projects.find((project) => project.id === registeredProjectId);
        if (byId) {
          return { id: byId.id, path: byId.path };
        }
        continue;
      }

      const byPath = projects.find((project) => project.path === projectPath);
      if (byPath) {
        return { id: byPath.id, path: byPath.path };
      }
    } catch {
      // Keep falling back — local/unregistered mode should remain available.
    }
  }

  return null;
}

export async function createTaskClient(
  projectPath: string,
  opts?: TaskClientFactoryOptions,
): Promise<TaskClientFactoryResult> {
  const registered = await resolveRegisteredProject(projectPath, opts?.registeredProjectId);
  return {
    backendType: "native",
    taskClient: new NativeTaskClient(projectPath, { registeredProjectId: registered?.id }),
  };
}

async function fetchNativeTaskCounts(projectPath: string, registeredProjectId?: string): Promise<TaskCounts> {
  const registered = await resolveRegisteredProject(projectPath, registeredProjectId);
  if (registered) {
    const adapter = new PostgresAdapter();
    const [total, ready, inProgress, completed, blocked] = await Promise.all([
      adapter.listTasks(registered.id, { status: [...NATIVE_TOTAL_STATUSES], limit: 1000 }),
      adapter.listTasks(registered.id, { status: ["ready"], limit: 1000 }),
      adapter.listTasks(registered.id, { status: ["in-progress"], limit: 1000 }),
      adapter.listTasks(registered.id, { status: ["merged", "closed"], limit: 1000 }),
      adapter.listTasks(registered.id, { status: [...NATIVE_BLOCKED_STATUSES], limit: 1000 }),
    ]);

    return {
      total: total.length,
      ready: ready.length,
      inProgress: inProgress.length,
      completed: completed.length,
      blocked: blocked.length,
    };
  }

  const store = ForemanStore.forProject(projectPath);
  try {
    return {
      total: store.listTasksByStatus([...NATIVE_TOTAL_STATUSES]).length,
      ready: store.listTasksByStatus(["ready"]).length,
      inProgress: store.listTasksByStatus(["in-progress"]).length,
      completed: store.listTasksByStatus(["merged", "closed"]).length,
      blocked: store.listTasksByStatus([...NATIVE_BLOCKED_STATUSES]).length,
    };
  } finally {
    store.close();
  }
}

export async function fetchTaskCounts(projectPath: string): Promise<TaskCounts> {
  return fetchNativeTaskCounts(projectPath);
}
