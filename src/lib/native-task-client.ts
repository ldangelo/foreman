import { ForemanStore } from "./store.js";
import { NativeTaskStore } from "./task-store.js";
import type { ITaskClient, Issue, UpdateOptions } from "./task-client.js";

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
  constructor(private readonly projectPath: string) {}

  private withStore<T>(fn: (taskStore: NativeTaskStore, store: ForemanStore) => T): T {
    const store = ForemanStore.forProject(this.projectPath);
    try {
      return fn(new NativeTaskStore(store.getDb()), store);
    } finally {
      store.close();
    }
  }

  async list(opts?: { status?: string; type?: string }): Promise<Issue[]> {
    return this.withStore((taskStore) =>
      taskStore
        .list(opts?.status ? { status: opts.status } : undefined)
        .filter((issue) => !opts?.type || issue.type === opts.type)
        .map((issue) => toIssue(this.projectPath, issue))
    );
  }

  async ready(): Promise<Issue[]> {
    const readyIssues = await this.withStore((taskStore) => taskStore.ready());
    return readyIssues.map((issue) => toIssue(this.projectPath, issue));
  }

  async show(id: string): Promise<{ status: string; description?: string | null; notes?: string | null; labels?: string[] }> {
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
    this.withStore((taskStore) => {
      taskStore.close(id, reason);
    });
  }

  async resetToReady(id: string, reason?: string): Promise<void> {
    this.withStore((taskStore) => {
      taskStore.resetToReady(id, reason);
    });
  }
}
