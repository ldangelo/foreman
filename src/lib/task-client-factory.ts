import { BeadsRustClient } from "./beads-rust.js";
import { NativeTaskClient } from "./native-task-client.js";
import { ForemanStore } from "./store.js";
import type { ITaskClient } from "./task-client.js";

export type TaskStoreMode = "native" | "beads" | "auto";
export type TaskClientBackend = "native" | "beads";

export interface TaskClientFactoryResult {
  backendType: TaskClientBackend;
  taskClient: ITaskClient;
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

export function resolveTaskStoreMode(raw = process.env.FOREMAN_TASK_STORE): TaskStoreMode {
  const normalized = raw?.trim().toLowerCase();
  if (normalized === "native" || normalized === "beads") return normalized;
  return "auto";
}

export function selectTaskReadBackend(projectPath: string): TaskClientBackend {
  const taskStoreMode = resolveTaskStoreMode();
  if (taskStoreMode === "native") return "native";
  if (taskStoreMode === "beads") return "beads";

  const store = ForemanStore.forProject(projectPath);
  try {
    return typeof store.hasNativeTasks === "function" && store.hasNativeTasks()
      ? "native"
      : "beads";
  } finally {
    store.close();
  }
}

export async function createTaskClient(
  projectPath: string,
  opts?: { ensureBrInstalled?: boolean },
): Promise<TaskClientFactoryResult> {
  const backendType = selectTaskReadBackend(projectPath);
  if (backendType === "native") {
    return {
      backendType,
      taskClient: new NativeTaskClient(projectPath),
    };
  }

  const taskClient = new BeadsRustClient(projectPath);
  if (opts?.ensureBrInstalled) {
    await taskClient.ensureBrInstalled();
  }
  return { backendType, taskClient };
}

async function fetchBeadsTaskCounts(projectPath: string): Promise<TaskCounts> {
  const brClient = new BeadsRustClient(projectPath);

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

function fetchNativeTaskCounts(projectPath: string): TaskCounts {
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
  return selectTaskReadBackend(projectPath) === "native"
    ? fetchNativeTaskCounts(projectPath)
    : fetchBeadsTaskCounts(projectPath);
}
