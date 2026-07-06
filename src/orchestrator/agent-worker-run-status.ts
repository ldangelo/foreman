import { randomUUID } from "node:crypto";
import { ForemanStore } from "../lib/store.js";
import type { Run } from "../lib/store.js";
import { ElixirServerClient } from "../lib/elixir-server-client.js";

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
    try {
      const client = new ElixirServerClient(process.env.FOREMAN_ELIXIR_URL ?? "http://127.0.0.1:4766");
      const runs = await client.listRuns({ projectId: opts.projectId });
      const currentRun = runs.find((run) => (run.run_id ?? run.id) === opts.runId);
      if (shouldPreserveTerminalSuccess(currentRun?.status as Run["status"] | undefined, opts.updates.status)) {
        return;
      }

      const response = await client.sendCommand({
        command_id: `run-update-${opts.runId}-${randomUUID()}`,
        command_type: "run.update",
        payload: { run_id: opts.runId, project_id: opts.projectId, ...opts.updates },
      });
      if (!response.ok) throw new Error(response.error.message);
      const linkedTaskStatus = opts.updates.status ? TERMINAL_TASK_STATUS_BY_RUN_STATUS[opts.updates.status] : undefined;
      if (linkedTaskStatus && currentRun?.task_id) {
        const taskResponse = await client.sendCommand({
          command_id: `task-update-${currentRun.task_id}-${randomUUID()}`,
          command_type: "task.update",
          payload: { task_id: currentRun.task_id, project_id: opts.projectId, status: linkedTaskStatus },
        });
        if (!taskResponse.ok) throw new Error(taskResponse.error.message);
      }
      return;
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.warn(
        `[agent-worker-run-status] Elixir updateRun failed for ${opts.runId} (${opts.projectId}); falling back to local store: ${msg}`,
      );
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
