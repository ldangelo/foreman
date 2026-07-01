import type { ForemanStore } from "../../lib/store.js";

/**
 * Async facade over the synchronous {@link ForemanStore} methods used by CLI
 * commands as the local fallback when the project is not registered with the
 * daemon (i.e. when no Postgres-backed store is available).
 *
 * Each command declares its own narrow store interface (e.g. ResetRunStore,
 * RetryStore, StopStore); this adapter is a structural superset of all of
 * them, replacing the previously copy-pasted wrapLocal*Store functions in
 * reset.ts, retry.ts, stop.ts, purge-logs.ts, and purge-zombie-runs.ts.
 */
export interface LocalRunStoreAdapter {
  getProjectByPath(path: string): Promise<ReturnType<ForemanStore["getProjectByPath"]>>;
  getRun(id: string): Promise<ReturnType<ForemanStore["getRun"]>>;
  getActiveRuns(projectId?: string): Promise<ReturnType<ForemanStore["getActiveRuns"]>>;
  getRunsByStatus(
    ...args: Parameters<ForemanStore["getRunsByStatus"]>
  ): Promise<ReturnType<ForemanStore["getRunsByStatus"]>>;
  getRunsForTask(
    ...args: Parameters<ForemanStore["getRunsForTask"]>
  ): Promise<ReturnType<ForemanStore["getRunsForTask"]>>;
  updateRun(...args: Parameters<ForemanStore["updateRun"]>): Promise<void>;
  deleteRun(runId: string): Promise<ReturnType<ForemanStore["deleteRun"]>>;
  logEvent(...args: Parameters<ForemanStore["logEvent"]>): Promise<void>;
  close(): void;
  isOpen(): boolean;
}

/**
 * Wrap a local ForemanStore in an async adapter so it can be used
 * interchangeably with the Postgres-backed store implementations.
 */
export function wrapLocalRunStore(store: ForemanStore): LocalRunStoreAdapter {
  return {
    getProjectByPath: async (path) => store.getProjectByPath(path),
    getRun: async (id) => store.getRun(id),
    getActiveRuns: async (projectId) => store.getActiveRuns(projectId),
    getRunsByStatus: async (status, projectId) => store.getRunsByStatus(status, projectId),
    getRunsForTask: async (taskId, projectId) => store.getRunsForTask(taskId, projectId),
    updateRun: async (runId, updates) => store.updateRun(runId, updates),
    deleteRun: async (runId) => store.deleteRun(runId),
    logEvent: async (projectId, eventType, data, runId) =>
      store.logEvent(projectId, eventType, data, runId),
    close: () => store.close(),
    isOpen: () => store.isOpen(),
  };
}

/**
 * Call `close()` on a store-like object if it exposes one.
 *
 * Replaces the repeated `if ("close" in store && typeof store.close ===
 * "function")` blocks in command teardown paths.
 */
export function closeStoreIfPossible(store: unknown): void {
  if (
    store !== null &&
    typeof store === "object" &&
    "close" in store &&
    typeof (store as { close?: unknown }).close === "function"
  ) {
    (store as { close: () => void }).close();
  }
}
