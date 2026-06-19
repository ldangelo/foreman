import { ForemanStore } from "../lib/store.js";
import type { Run } from "../lib/store.js";
import { PostgresStore } from "../lib/postgres-store.js";

const TERMINAL_TASK_STATUS_BY_RUN_STATUS: Partial<Record<Run["status"], "failed" | "stuck" | "merged">> = {
  failed: "failed",
  stuck: "stuck",
  merged: "merged",
};

const TERMINAL_SUCCESS_STATUSES = new Set<Run["status"]>(["pr-created", "merged"]);
const FAILURE_STATUSES = new Set<Run["status"]>(["failed", "stuck"]);

function shouldPreserveTerminalSuccess(currentStatus: Run["status"] | undefined, nextStatus: Run["status"] | undefined): boolean {
  return currentStatus !== undefined
    && nextStatus !== undefined
    && TERMINAL_SUCCESS_STATUSES.has(currentStatus)
    && FAILURE_STATUSES.has(nextStatus);
}

export async function updateTerminalRunStatus(opts: {
  runId: string;
  projectId?: string;
  projectPath: string;
  updates: Partial<Pick<Run, "status" | "completed_at" | "cooldown_until">>;
}): Promise<void> {
  if (opts.projectId) {
    const pgStore = PostgresStore.forProject(opts.projectId);
    try {
      const currentRun = await pgStore.getRun(opts.runId);
      if (shouldPreserveTerminalSuccess(currentRun?.status, opts.updates.status)) {
        return;
      }

      await pgStore.updateRun(opts.runId, opts.updates);
      const linkedTaskStatus = opts.updates.status
        ? TERMINAL_TASK_STATUS_BY_RUN_STATUS[opts.updates.status]
        : undefined;
      if (linkedTaskStatus) {
        await pgStore.updateTaskStatusForRun(opts.runId, linkedTaskStatus);
      }
      return;
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.warn(
        `[agent-worker-run-status] Postgres updateRun failed for ${opts.runId} (${opts.projectId}); falling back to local store: ${msg}`,
      );
    } finally {
      pgStore.close();
    }
  }

  const localStore = ForemanStore.forProject(opts.projectPath);
  try {
    const currentRun = await Promise.resolve(localStore.getRun(opts.runId));
    if (shouldPreserveTerminalSuccess(currentRun?.status, opts.updates.status)) {
      return;
    }

    await Promise.resolve(localStore.updateRun(opts.runId, opts.updates));
  } finally {
    localStore.close();
  }
}
