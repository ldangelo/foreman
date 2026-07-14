import type { CreateOptions, ITaskClient, Issue, UpdateOptions } from "./task-client.js";
import { ElixirServerClient, type ElixirTask } from "./elixir-server-client.js";
import { ElixirServerManager } from "./elixir-server-manager.js";

function str(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}

function toIssue(projectPath: string, task: ElixirTask): Issue {
  const now = new Date(0).toISOString();
  return {
    id: str(task.task_id ?? task.id),
    title: str(task.title),
    type: str(task.task_type ?? task.type, "task"),
    priority: String(task.priority ?? 2),
    status: str(task.status, "backlog"),
    assignee: null,
    parent: null,
    created_at: str(task.created_at, now),
    updated_at: str(task.updated_at, now),
    description: task.description ?? null,
    labels: [`project:${projectPath}`],
  };
}

/** Task client backed by Elixir HTTP commands/projections. */
export class ElixirTaskClient implements ITaskClient {
  private readonly clientPromise: Promise<ElixirServerClient>;

  constructor(
    private readonly projectPath: string,
    private readonly projectId: string,
    client?: ElixirServerClient,
  ) {
    this.clientPromise = client
      ? Promise.resolve(client)
      : process.env.FOREMAN_SERVER_URL
        ? Promise.resolve(new ElixirServerClient(process.env.FOREMAN_SERVER_URL, process.env.FOREMAN_WORKER_EVENT_TOKEN ?? process.env.FOREMAN_SERVER_AUTH_TOKEN))
        : new ElixirServerManager().ensureRunning().then((status) => (
            new ElixirServerClient(status.url, process.env.FOREMAN_WORKER_EVENT_TOKEN ?? process.env.FOREMAN_SERVER_AUTH_TOKEN)
          ));
  }

  async list(opts?: { status?: string; type?: string }): Promise<Issue[]> {
    const tasks = await (await this.clientPromise).listTasks();
    return tasks
      .filter((task) => !task.project_id || task.project_id === this.projectId)
      .filter((task) => !opts?.status || task.status === opts.status)
      .filter((task) => !opts?.type || (task.task_type ?? task.type) === opts.type)
      .map((task) => toIssue(this.projectPath, task));
  }

  async create(title: string, opts?: CreateOptions): Promise<Issue> {
    const response = await (await this.clientPromise).sendCommand({
      command_id: `task-create-${Date.now()}-${Math.random().toString(16).slice(2)}`,
      command_type: "task.create",
      payload: {
        project_id: this.projectId,
        title,
        description: opts?.description ?? null,
        task_type: opts?.type ?? "task",
        priority: Number(opts?.priority ?? 2),
      },
    });
    if (!response.ok) throw new Error(response.error.message);
    const created = await this.findNewestByTitle(title);
    if (!created) throw new Error(`Created task '${title}' not found in Elixir projection`);
    return created;
  }

  async ready(): Promise<Issue[]> {
    return this.list({ status: "ready" });
  }

  async show(id: string): Promise<Issue> {
    const task = await (await this.clientPromise).getTask(id);
    if (!task) throw new Error(`Task '${id}' not found`);
    return toIssue(this.projectPath, task);
  }

  async update(id: string, opts: UpdateOptions): Promise<void> {
    const response = await (await this.clientPromise).sendCommand({
      command_id: `task-update-${id}-${Date.now()}`,
      command_type: "task.update",
      payload: {
        project_id: this.projectId,
        task_id: id,
        ...(opts.status ? { status: opts.status === "in_progress" ? "in-progress" : opts.status } : {}),
        ...(opts.runId !== undefined ? { run_id: opts.runId } : {}),
        ...(opts.source !== undefined ? { source: opts.source } : {}),
        ...(opts.title !== undefined ? { title: opts.title } : {}),
        ...(opts.description !== undefined ? { description: opts.description } : {}),
      },
    });
    if (!response.ok) throw new Error(response.error.message);
  }

  async close(id: string, _reason?: string): Promise<void> {
    const response = await (await this.clientPromise).sendCommand({
      command_id: `task-close-${id}-${Date.now()}`,
      command_type: "task.close",
      payload: { project_id: this.projectId, task_id: id },
    });
    if (!response.ok) throw new Error(response.error.message);
  }

  async comments(_id: string): Promise<string | null> {
    return null;
  }

  private async findNewestByTitle(title: string): Promise<Issue | null> {
    const tasks = await this.list();
    return tasks
      .filter((task) => task.title === title)
      .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at))[0] ?? null;
  }
}

