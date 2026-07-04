import { ElixirServerClient } from "./elixir-server-client.js";
import { ElixirServerManager } from "./elixir-server-manager.js";
import { ElixirTaskClient } from "./elixir-task-client.js";
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

const TOTAL_STATUSES = new Set([
  "backlog",
  "ready",
  "in-progress",
  "merged",
  "closed",
  "conflict",
  "failed",
  "stuck",
  "blocked",
]);

const BLOCKED_STATUSES = new Set([
  "backlog",
  "conflict",
  "failed",
  "stuck",
  "blocked",
]);

async function createElixirClient(): Promise<ElixirServerClient> {
  const token = process.env.FOREMAN_WORKER_EVENT_TOKEN ?? process.env.FOREMAN_SERVER_AUTH_TOKEN;
  if (process.env.FOREMAN_SERVER_URL) {
    return new ElixirServerClient(process.env.FOREMAN_SERVER_URL, token);
  }

  const status = await new ElixirServerManager().ensureRunning();
  return new ElixirServerClient(status.url, token);
}

async function resolveProjectId(projectPath: string, registeredProjectId?: string): Promise<string> {
  if (registeredProjectId) return registeredProjectId;

  const client = await createElixirClient();
  const projects = await client.listProjects();
  const project = projects.find((record) => record.path === projectPath);
  const projectId = project?.id ?? project?.project_id;
  if (!projectId) {
    throw new Error(`Project at '${projectPath}' is not registered in Elixir projections.`);
  }
  return projectId;
}

export async function createTaskClient(
  projectPath: string,
  opts?: TaskClientFactoryOptions,
): Promise<TaskClientFactoryResult> {
  const projectId = await resolveProjectId(projectPath, opts?.registeredProjectId);
  return {
    backendType: "native",
    taskClient: new ElixirTaskClient(projectPath, projectId),
  };
}

export async function fetchTaskCounts(projectPath: string): Promise<TaskCounts> {
  const projectId = await resolveProjectId(projectPath);
  const client = new ElixirTaskClient(projectPath, projectId);
  const tasks = await client.list();

  return {
    total: tasks.filter((task) => TOTAL_STATUSES.has(task.status)).length,
    ready: tasks.filter((task) => task.status === "ready").length,
    inProgress: tasks.filter((task) => task.status === "in-progress").length,
    completed: tasks.filter((task) => task.status === "merged" || task.status === "closed").length,
    blocked: tasks.filter((task) => BLOCKED_STATUSES.has(task.status)).length,
  };
}
