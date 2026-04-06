import type { Database } from "better-sqlite3";

import type { BeadGraph } from "./beads.js";
import type { ITaskClient, Issue, UpdateOptions } from "./task-client.js";
import { NativeTaskStore, type UpdateTaskOptions } from "./task-store.js";

/**
 * NativeTaskClient adapts NativeTaskStore to the ITaskClient / IRefineryTaskClient
 * surfaces used by Dispatcher, run.ts, and Refinery when Foreman operates
 * against native SQLite tasks instead of beads_rust.
 */
export class NativeTaskClient implements ITaskClient {
  private readonly taskStore: NativeTaskStore;

  constructor(db: Database) {
    this.taskStore = new NativeTaskStore(db);
  }

  async list(opts?: { status?: string; type?: string }): Promise<Issue[]> {
    const tasks = this.taskStore.list(opts?.status ? { status: opts.status } : undefined);
    if (!opts?.type) return tasks;
    return tasks.filter((task) => task.type === opts.type);
  }

  ready(): Promise<Issue[]> {
    return this.taskStore.ready();
  }

  async show(id: string): Promise<{ title?: string; description?: string | null; notes?: string | null; status: string; labels?: string[] }> {
    const task = this.taskStore.get(id);
    if (!task) {
      throw new Error(`Native task '${id}' not found`);
    }
    return {
      title: task.title,
      description: task.description,
      notes: null,
      status: task.status,
      labels: [],
    };
  }

  async update(id: string, opts: UpdateOptions): Promise<void> {
    const update: UpdateTaskOptions = {};
    if (opts.title !== undefined) update.title = opts.title;
    if (opts.description !== undefined) update.description = opts.description;
    if (opts.status !== undefined) update.status = opts.status;

    if (Object.keys(update).length > 0) {
      this.taskStore.update(id, update);
    }
  }

  async close(id: string, reason?: string): Promise<void> {
    this.taskStore.close(id, reason);
  }

  async comments(): Promise<string | null> {
    return null;
  }

  async getGraph(): Promise<BeadGraph> {
    return { nodes: [], edges: [] };
  }
}
