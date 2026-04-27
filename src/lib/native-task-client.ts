import { randomBytes } from "node:crypto";
import { basename } from "node:path";
import { PostgresAdapter, type TaskRow as PostgresTaskRow } from "./db/postgres-adapter.js";
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
 * NativeTaskClient adapts the project-local SQLite task store to ITaskClient.
 *
 * This is primarily used by deterministic test-runtime and native-task-only
 * execution paths where the br CLI should not be required.
 */
export class NativeTaskClient implements ITaskClient {
  private readonly postgres = new PostgresAdapter();

  constructor(
    private readonly projectPath: string,
    private readonly opts: { registeredProjectId?: string } = {},
  ) {}

  private get registeredProjectId(): string | undefined {
    return this.opts.registeredProjectId;
  }

  private toPostgresIssue(row: PostgresTaskRow): Issue {
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

  private async withPostgresTask<T>(id: string, fn: (task: PostgresTaskRow) => Promise<T>): Promise<T> {
    const projectId = this.registeredProjectId;
    if (!projectId) {
      throw new Error("Postgres task access requires a registered project id");
    }

    const task = await this.postgres.getTask(projectId, id);
    if (!task) {
      throw new TaskNotFoundError(id);
    }
    return fn(task);
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
      finalize: 4,
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
      return (await this.postgres.listTasks(this.registeredProjectId, {
        ...(opts?.status ? { status: [this.normalizeStatus(opts.status) ?? opts.status] } : {}),
        limit: 1000,
      }))
        .filter((issue) => !opts?.type || issue.type === opts.type)
        .map((issue) => this.toPostgresIssue(issue));
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
      const task = await this.postgres.createTask(this.registeredProjectId, {
        id,
        title,
        description: opts?.description ?? null,
        type: opts?.type ?? "task",
        priority: this.normalizePriority(opts?.priority) ?? 2,
      });

      if (opts?.parent) {
        await this.postgres.addTaskDependency(this.registeredProjectId, task.id, opts.parent, "parent-child");
      }

      return this.toPostgresIssue(task);
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
    if (this.registeredProjectId) {
      return (await this.postgres.listReadyTasks(this.registeredProjectId)).map((issue) =>
        this.toPostgresIssue(issue)
      );
    }

    const readyIssues = await this.withStore((taskStore) => taskStore.ready());
    return readyIssues.map((issue) => toIssue(this.projectPath, issue));
  }

  async show(id: string): Promise<{ status: string; description?: string | null; notes?: string | null; labels?: string[] }> {
    if (this.registeredProjectId) {
      return this.withPostgresTask(id, async (row) => ({
        status: row.status,
        description: row.description ?? null,
        notes: null,
        labels: [`project:${this.projectPath}`],
      }));
    }

    return this.withStore((taskStore) => {
      const row = taskStore.get(id);
      if (!row) {
        throw new Error(`Native task '${id}' not found`);
      }
      return {
        status: row.status,
        description: row.description ?? null,
        notes: null,
        labels: [`project:${this.projectPath}`],
      };
    });
  }

  async update(id: string, opts: UpdateOptions): Promise<void> {
    if (this.registeredProjectId) {
      await this.withPostgresTask(id, async (task) => {
        const nextStatus =
          opts.claim
            ? "in-progress"
            : this.normalizeStatus(opts.status);

        if (nextStatus !== undefined) {
          this.validateStatusTransition(id, task.status, nextStatus);
        }

        await this.postgres.updateTask(this.registeredProjectId!, id, {
          ...(opts.title !== undefined ? { title: opts.title } : {}),
          ...(opts.description !== undefined ? { description: opts.description ?? null } : {}),
          ...(nextStatus !== undefined ? { status: nextStatus } : {}),
        });
      });
      return;
    }

    this.withStore((taskStore) => {
      const nextStatus =
        opts.claim
          ? "in-progress"
          : opts.status === "in_progress"
            ? "in-progress"
            : opts.status;

      taskStore.update(id, {
        ...(opts.title !== undefined ? { title: opts.title } : {}),
        ...(opts.description !== undefined ? { description: opts.description ?? null } : {}),
        ...(nextStatus !== undefined ? { status: nextStatus } : {}),
        ...(typeof opts.notes === "string" ? {} : {}),
      });
    });
  }

  async close(id: string, reason?: string): Promise<void> {
    if (this.registeredProjectId) {
      await this.withPostgresTask(id, async () => {
        await this.postgres.closeTask(this.registeredProjectId!, id);
      });
      return;
    }

    this.withStore((taskStore) => {
      taskStore.close(id, reason);
    });
  }

  async resetToReady(id: string, reason?: string): Promise<void> {
    if (this.registeredProjectId) {
      await this.withPostgresTask(id, async (task) => {
        if (task.status === "closed" || task.status === "merged") {
          throw new InvalidStatusTransitionError(id, task.status, "ready");
        }
        await this.postgres.resetTask(this.registeredProjectId!, id);
      });
      return;
    }

    this.withStore((taskStore) => {
      taskStore.resetToReady(id, reason);
    });
  }
}
