import { ForemanStore } from "../lib/store.js";
import { PostgresStore } from "../lib/postgres-store.js";

export async function updateFatalRunStatus(opts: {
  runId: string;
  projectId?: string;
  projectPath: string;
  completedAt: string;
}): Promise<void> {
  if (opts.projectId) {
    const store = PostgresStore.forProject(opts.projectId);
    try {
      await store.updateRun(opts.runId, { status: "failed", completed_at: opts.completedAt });
    } finally {
      store.close();
    }
    return;
  }

  const store = ForemanStore.forProject(opts.projectPath);
  try {
    await Promise.resolve(store.updateRun(opts.runId, { status: "failed", completed_at: opts.completedAt }));
  } finally {
    store.close();
  }
}
