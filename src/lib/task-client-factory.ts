import { NativeTaskClient } from "./native-task-client.js";
import { PostgresAdapter } from "./db/postgres-adapter.js";
import { initPool, isPoolInitialised } from "./db/pool-manager.js";
import { resolveProjectDatabaseUrl } from "./project-mail-client.js";
import { ProjectRegistry } from "./project-registry.js";
import { ForemanStore } from "./store.js";
import type { ITaskClient } from "./task-client.js";

export type TaskStoreMode = "native" | "beads" | "auto";
export type TaskClientBackend = "native" | "beads";

export interface TaskClientFactoryResult {
  backendType: TaskClientBackend;
  taskClient: ITaskClient;
}

export interface TaskClientFactoryOptions {
  ensureBrInstalled?: boolean;
  forceBeadsFallback?: boolean;
  autoSelectNativeWhenAvailable?: boolean;
  registeredProjectId?: string;
}

export interface TaskCounts {
  total: number;
  ready: number;
  inProgress: number;
  completed: number;
  blocked: number;
}

interface BeadsTaskClient extends ITaskClient {
  ensureBrInstalled(): Promise<void>;
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

export function resolveTaskStoreMode(raw = process.env.FOREMAN_TASK_STORE): TaskStoreMode {
  const normalized = raw?.trim().toLowerCase();
  if (!raw || normalized === "auto") return "auto";
  if (normalized === "native" || normalized === "beads") return normalized;
  console.error(
    `[dispatch] Warning: FOREMAN_TASK_STORE='${raw}' is not valid ('native'|'beads'|'auto'). Treating as 'auto'.`,
  );
  return "auto";
}

async function createBeadsFallbackClient(projectPath: string): Promise<BeadsTaskClient> {
  const { BeadsRustClient } = await import("./beads-rust.js");
  return new BeadsRustClient(projectPath) as BeadsTaskClient;
}

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

export function projectHasNativeTasks(projectPath: string): boolean {
  const store = ForemanStore.forProject(projectPath);
  try {
    return typeof store.hasNativeTasks === "function" && store.hasNativeTasks();
  } finally {
    store.close();
  }
}

export function selectTaskReadBackend(
  projectPath: string,
  opts?: { forceBeadsFallback?: boolean; autoSelectNativeWhenAvailable?: boolean },
): TaskClientBackend {
  const taskStoreMode = resolveTaskStoreMode();
  if (taskStoreMode === "native") return "native";
  if (taskStoreMode === "beads") return "beads";

  if (opts?.forceBeadsFallback === true || opts?.autoSelectNativeWhenAvailable === true) {
    return "beads";
  }

  return projectHasNativeTasks(projectPath) ? "native" : "beads";
}

async function projectHasNativeTasksAsync(
  projectPath: string,
  registeredProjectId?: string,
): Promise<{ hasNativeTasks: boolean; registeredProjectId?: string }> {
  const registered = await resolveRegisteredProject(projectPath, registeredProjectId);
  if (registered) {
    return {
      hasNativeTasks: await new PostgresAdapter().hasNativeTasks(registered.id),
      registeredProjectId: registered.id,
    };
  }

  return {
    hasNativeTasks: projectHasNativeTasks(projectPath),
  };
}

async function selectTaskReadBackendAsync(
  projectPath: string,
  opts?: TaskClientFactoryOptions,
): Promise<{ backendType: TaskClientBackend; registeredProjectId?: string }> {
  const taskStoreMode = resolveTaskStoreMode();
  if (opts?.forceBeadsFallback === true || opts?.autoSelectNativeWhenAvailable === true) {
    return { backendType: "beads" };
  }
  if (taskStoreMode === "native") {
    const registered = await resolveRegisteredProject(projectPath, opts?.registeredProjectId);
    return { backendType: "native", registeredProjectId: registered?.id };
  }
  if (taskStoreMode === "beads") return { backendType: "beads" };

  const nativeAvailability = await projectHasNativeTasksAsync(projectPath, opts?.registeredProjectId);
  return {
    backendType: nativeAvailability.hasNativeTasks ? "native" : "beads",
    registeredProjectId: nativeAvailability.registeredProjectId,
  };
}

export async function createTaskClient(
  projectPath: string,
  opts?: TaskClientFactoryOptions,
): Promise<TaskClientFactoryResult> {
  const { backendType, registeredProjectId } = await selectTaskReadBackendAsync(projectPath, opts);
  if (backendType === "native") {
    return {
      backendType,
      taskClient: new NativeTaskClient(projectPath, { registeredProjectId }),
    };
  }

  const taskClient = await createBeadsFallbackClient(projectPath);
  if (opts?.ensureBrInstalled) {
    await taskClient.ensureBrInstalled();
  }
  return { backendType, taskClient };
}

async function fetchBeadsTaskCounts(projectPath: string): Promise<TaskCounts> {
  const brClient = await createBeadsFallbackClient(projectPath);

  let openIssues: Array<{ id: string; status: string }> = [];
  try {
    openIssues = await brClient.list();
  } catch {
    // br not initialized or unavailable — treat as empty
  }

  let closedIssues: Array<{ id: string; status: string }> = [];
  try {
    closedIssues = await brClient.list({ status: "closed" });
  } catch {
    // no closed issues
  }

  let readyIssues: Array<{ id: string }> = [];
  try {
    readyIssues = await brClient.ready();
  } catch {
    // ready() may fail independently; keep other counts
  }

  const readyIds = new Set(readyIssues.map((issue) => issue.id));
  const inProgress = openIssues.filter((issue) => issue.status === "in_progress").length;
  const completed = closedIssues.length;
  const ready = readyIssues.length;
  const blocked = openIssues.filter(
    (issue) => issue.status !== "in_progress" && !readyIds.has(issue.id),
  ).length;

  return {
    total: openIssues.length + completed,
    ready,
    inProgress,
    completed,
    blocked,
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
  const { backendType, registeredProjectId } = await selectTaskReadBackendAsync(projectPath)
  return backendType === "native"
    ? fetchNativeTaskCounts(projectPath, registeredProjectId)
    : fetchBeadsTaskCounts(projectPath);
}
