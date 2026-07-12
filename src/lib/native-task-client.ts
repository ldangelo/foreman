import { randomBytes, randomUUID } from "node:crypto";
import { basename } from "node:path";
import { ForemanStore } from "./store.js";
import {
  InvalidStatusTransitionError,
  NativeTaskStore,
  type TaskRow,
  TaskNotFoundError,
  normalizeTaskIdPrefix,
  parsePriority,
} from "./task-store.js";
import type { CreateOptions, ITaskClient, Issue, UpdateOptions } from "./task-client.js";
import type { NativeTaskStatus } from "../orchestrator/types.js";
import { ElixirServerClient, type ElixirTask } from "./elixir-server-client.js";

const COMPACT_TASK_ID_SUFFIX_HEX_LENGTH = 5;

function allocateTaskId(projectPath: string): string {
  const prefix = normalizeTaskIdPrefix(basename(projectPath));
  return `${prefix}-${randomBytes(3).toString("hex").slice(0, COMPACT_TASK_ID_SUFFIX_HEX_LENGTH)}`;
}

function toIssue(projectPath: string, issue: Issue): Issue {
  return {
    ...issue,
    description: issue.description ?? null,
    labels: issue.labels ?? [`project:${projectPath}`],
  };
}

/**
 * NativeTaskClient adapts the project-local task store to ITaskClient.
 *
 * This is primarily used by deterministic test-runtime and native-task-only
 * execution paths where the native task store CLI should not be required.
 */
export class NativeTaskClient implements ITaskClient {
  constructor(
    private readonly projectPath: string,
    private readonly opts: { registeredProjectId?: string } = {},
  ) {}

  private get registeredProjectId(): string | undefined {
    return this.opts.registeredProjectId;
  }

  private toNativeIssue(row: TaskRow): Issue {
    return toIssue(this.projectPath, {
      id: row.id,
      title: row.title,
      type: row.type,
      priority: String(row.priority),
      status: row.status,
      assignee: null,
      parent: null,
      created_at: row.created_at,
      updated_at: row.updated_at,
      description: row.description,
      labels: [`project:${this.projectPath}`],
    });
  }

  private elixirClient(): ElixirServerClient {
    return new ElixirServerClient(process.env.FOREMAN_ELIXIR_URL ?? "http://127.0.0.1:4766");
  }

  private toElixirIssue(task: ElixirTask): Issue {
    const id = task.task_id ?? task.id;
    if (!id) throw new TaskNotFoundError("<missing-id>");
    return toIssue(this.projectPath, {
      id,
      title: task.title ?? id,
      type: task.task_type ?? task.type ?? "task",
      priority: String(task.priority ?? 2),
      status: this.normalizeStatus(task.status) ?? "backlog",
      assignee: null,
      parent: null,
      created_at: task.created_at ?? new Date(0).toISOString(),
      updated_at: task.updated_at ?? task.created_at ?? new Date(0).toISOString(),
      description: task.description ?? null,
      labels: [`project:${this.projectPath}`],
    });
  }

  private async getElixirTask(id: string): Promise<ElixirTask> {
    const task = await this.elixirClient().getTask(id);
    if (!task || (task.project_id && task.project_id !== this.registeredProjectId)) {
      throw new TaskNotFoundError(id);
    }
    return task;
  }

  private async sendElixirCommand(commandType: string, payload: Record<string, unknown>): Promise<void> {
    const response = await this.elixirClient().sendCommand({
      command_id: `${commandType}-${payload.task_id ?? payload.id ?? "task"}-${randomUUID()}`,
      command_type: commandType,
      payload,
    });
    if (!response.ok) throw new Error(response.error.message);
  }

  private normalizeStatus(status: string | undefined): string | undefined {
    if (status === "in_progress") return "in-progress";
    return status;
  }

  private normalizePriority(priority: string | undefined): number | undefined {
    if (priority === undefined) return undefined;
    return parsePriority(priority);
  }

  private validateStatusTransition(id: string, fromStatus: string, toStatus: string): void {
    const statusOrder: Record<string, number> = {
      backlog: 0,
      ready: 1,
      "in-progress": 2,
      explorer: 3,
      developer: 3,
      qa: 3,
      reviewer: 3,
      finalize: 3,
      merged: 5,
      closed: 5,
      conflict: -1,
      failed: -1,
      stuck: -1,
      blocked: 0,
    };
    const fromOrder = statusOrder[fromStatus] ?? 0;
    const toOrder = statusOrder[toStatus] ?? 0;
    if (toOrder >= 0 && fromOrder > toOrder) {
      throw new InvalidStatusTransitionError(id, fromStatus, toStatus);
    }
  }

  private withStore<T>(fn: (taskStore: NativeTaskStore) => T): T {
    const store = ForemanStore.forProject(this.projectPath);
    try {
      return fn(new NativeTaskStore(store.getDb()));
    } finally {
      store.close();
    }
  }

  async list(opts?: { status?: string; type?: string }): Promise<Issue[]> {
    if (this.registeredProjectId) {
      const normalizedStatus = this.normalizeStatus(opts?.status);
      return (await this.elixirClient().listTasks())
        .filter((task) => task.project_id === this.registeredProjectId)
        .filter((task) => !normalizedStatus || this.normalizeStatus(task.status) === normalizedStatus)
        .filter((task) => !opts?.type || (task.task_type ?? task.type) === opts.type)
        .map((task) => this.toElixirIssue(task));
    }

    return this.withStore((taskStore) =>
      taskStore
        .list(opts?.status ? { status: opts.status } : undefined)
        .filter((issue) => !opts?.type || issue.type === opts.type)
        .map((issue) => toIssue(this.projectPath, issue))
    );
  }

  async create(title: string, opts?: CreateOptions): Promise<Issue> {
    if (this.registeredProjectId) {
      const id = allocateTaskId(this.projectPath);
      const payload = {
        task_id: id,
        project_id: this.registeredProjectId,
        title,
        description: opts?.description ?? null,
        task_type: opts?.type ?? "task",
        priority: this.normalizePriority(opts?.priority) ?? 2,
        status: "backlog",
      };
      await this.sendElixirCommand("task.create", payload);
      if (opts?.parent) {
        await this.sendElixirCommand("task.add_dependency", {
          project_id: this.registeredProjectId,
          task_id: id,
          depends_on: opts.parent,
          kind: "parent-child",
        });
      }
      return this.toElixirIssue({ ...payload, id, created_at: new Date().toISOString(), updated_at: new Date().toISOString() });
    }

    return this.withStore((taskStore) => {
      const created = taskStore.create({
        title,
        description: opts?.description ?? null,
        type: opts?.type,
        priority: this.normalizePriority(opts?.priority),
      });

      if (opts?.parent) {
        taskStore.addDependency(created.id, opts.parent, "parent-child");
      }

      return this.toNativeIssue(created);
    });
  }

  async ready(): Promise<Issue[]> {
    if (this.registeredProjectId) return this.list({ status: "ready" });

    const readyIssues = await this.withStore((taskStore) => taskStore.ready());
    return readyIssues.map((issue) => toIssue(this.projectPath, issue));
  }

  async show(id: string): Promise<Issue> {
    if (this.registeredProjectId) return this.toElixirIssue(await this.getElixirTask(id));

    return this.withStore((taskStore) => {
      const row = taskStore.get(id);
      if (!row) {
        throw new Error(`Native task '${id}' not found`);
      }
      return this.toNativeIssue(row);
    });
  }

  async update(id: string, opts: UpdateOptions): Promise<void> {
    if (this.registeredProjectId) {
      const current = await this.getElixirTask(id);
      const nextStatus =
        opts.claim
          ? "in-progress"
          : opts.status === "in_progress"
            ? "in-progress"
            : (opts.status as NativeTaskStatus | undefined);
      if (nextStatus) this.validateStatusTransition(id, this.normalizeStatus(current.status) ?? "backlog", nextStatus);
      await this.sendElixirCommand("task.update", {
        task_id: id,
        project_id: this.registeredProjectId,
        ...(opts.title !== undefined ? { title: opts.title } : {}),
        ...(opts.description !== undefined ? { description: opts.description ?? null } : {}),
        ...(nextStatus !== undefined ? { status: nextStatus } : {}),
      });
      if (typeof opts.notes === "string" && opts.notes.trim()) {
        await this.sendElixirCommand("task.annotate", {
          task_id: id,
          project_id: this.registeredProjectId,
          body: opts.notes,
          author: "foreman",
          kind: "note",
        });
      }
      return;
    }

    this.withStore((taskStore) => {
      const nextStatus =
        opts.claim
          ? "in-progress"
          : opts.status === "in_progress"
            ? "in-progress"
            : (opts.status as NativeTaskStatus | undefined);

      taskStore.update(id, {
        ...(opts.title !== undefined ? { title: opts.title } : {}),
        ...(opts.description !== undefined ? { description: opts.description ?? null } : {}),
        ...(nextStatus !== undefined ? { status: nextStatus } : {}),
        ...(typeof opts.notes === "string" ? {} : {}),
      });
    });
  }

  async comments(id: string): Promise<string | null> {
    if (!this.registeredProjectId) return null;
    const task = await this.getElixirTask(id);
    const notes = task.annotations ?? [];
    if (notes.length === 0) return null;
    return notes
      .map((note) => `**${note.author ?? "foreman"}**${note.created_at ? ` (${note.created_at})` : ""}:\n${note.body}`)
      .join("\n\n");
  }

  async close(id: string, reason?: string): Promise<void> {
    if (this.registeredProjectId) {
      await this.getElixirTask(id);
      await this.sendElixirCommand("task.close", { task_id: id, project_id: this.registeredProjectId, reason });
      return;
    }

    this.withStore((taskStore) => {
      taskStore.close(id, reason);
    });
  }

  async resetToReady(id: string, reason?: string): Promise<void> {
    if (this.registeredProjectId) {
      const current = await this.getElixirTask(id);
      this.validateStatusTransition(id, this.normalizeStatus(current.status) ?? "backlog", "ready");
      await this.sendElixirCommand("task.update", { task_id: id, project_id: this.registeredProjectId, status: "ready", reason });
      return;
    }

    this.withStore((taskStore) => {
      taskStore.resetToReady(id, reason);
    });
  }

}
