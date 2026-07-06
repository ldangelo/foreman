import { randomBytes } from "node:crypto";
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
 * execution paths where the br CLI should not be required.
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

  private requireElixirTaskBackend(): never {
    throw new Error("Registered native task access must use the Elixir backend; Postgres backend was removed");
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
    if (this.registeredProjectId) this.requireElixirTaskBackend();

    return this.withStore((taskStore) =>
      taskStore
        .list(opts?.status ? { status: opts.status } : undefined)
        .filter((issue) => !opts?.type || issue.type === opts.type)
        .map((issue) => toIssue(this.projectPath, issue))
    );
  }

  async create(title: string, opts?: CreateOptions): Promise<Issue> {
    if (this.registeredProjectId) this.requireElixirTaskBackend();

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
    if (this.registeredProjectId) this.requireElixirTaskBackend();

    const readyIssues = await this.withStore((taskStore) => taskStore.ready());
    return readyIssues.map((issue) => toIssue(this.projectPath, issue));
  }

  async show(id: string): Promise<Issue> {
    if (this.registeredProjectId) this.requireElixirTaskBackend();

    return this.withStore((taskStore) => {
      const row = taskStore.get(id);
      if (!row) {
        throw new Error(`Native task '${id}' not found`);
      }
      return this.toNativeIssue(row);
    });
  }

  async update(id: string, opts: UpdateOptions): Promise<void> {
    if (this.registeredProjectId) this.requireElixirTaskBackend();

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
    this.requireElixirTaskBackend();
  }

  async close(id: string, reason?: string): Promise<void> {
    if (this.registeredProjectId) this.requireElixirTaskBackend();

    this.withStore((taskStore) => {
      taskStore.close(id, reason);
    });
  }

  async resetToReady(id: string, reason?: string): Promise<void> {
    if (this.registeredProjectId) this.requireElixirTaskBackend();

    this.withStore((taskStore) => {
      taskStore.resetToReady(id, reason);
    });
  }
}
