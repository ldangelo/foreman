import { randomUUID } from "node:crypto";
import { ForemanStore } from "../lib/store.js";
import { ElixirServerClient } from "../lib/elixir-server-client.js";

function shouldPreserveTerminalSuccess(currentStatus: string | null | undefined): boolean {
  return currentStatus === "pr-created" || currentStatus === "merged";
}

export async function updateFatalRunStatus(opts: {
  runId: string;
  projectId?: string;
  projectPath: string;
  completedAt: string;
}): Promise<void> {
  if (opts.projectId) {
    const client = new ElixirServerClient(process.env.FOREMAN_ELIXIR_URL ?? "http://127.0.0.1:4766");
    const runs = await client.listRuns({ projectId: opts.projectId });
    const currentRun = runs.find((run) => (run.run_id ?? run.id) === opts.runId);
    if (shouldPreserveTerminalSuccess(currentRun?.status)) {
      return;
    }

    const response = await client.sendCommand({
      command_id: `run-update-${opts.runId}-${randomUUID()}`,
      command_type: "run.update",
      payload: { run_id: opts.runId, project_id: opts.projectId, status: "failed", completed_at: opts.completedAt },
    });
    if (!response.ok) throw new Error(response.error.message);
    return;
  }

  const store = ForemanStore.forProject(opts.projectPath);
  try {
    const currentRun = await Promise.resolve(store.getRun(opts.runId));
    if (shouldPreserveTerminalSuccess(currentRun?.status)) {
      return;
    }

    await Promise.resolve(store.updateRun(opts.runId, { status: "failed", completed_at: opts.completedAt }));
  } finally {
    store.close();
  }
}
