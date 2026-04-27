import { ForemanStore } from "../lib/store.js";
import type { Run } from "../lib/store.js";
import { PostgresStore } from "../lib/postgres-store.js";

export async function updateTerminalRunStatus(opts: {
  runId: string;
  projectId?: string;
  projectPath: string;
  updates: Partial<Pick<Run, "status" | "completed_at">>;
}): Promise<void> {
  if (opts.projectId) {
    const pgStore = PostgresStore.forProject(opts.projectId);
    try {
      await pgStore.updateRun(opts.runId, opts.updates);
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
    await Promise.resolve(localStore.updateRun(opts.runId, opts.updates));
  } finally {
    localStore.close();
  }
}
