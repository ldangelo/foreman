import { ForemanStore } from "../lib/store.js";
import { PostgresStore } from "../lib/postgres-store.js";
function shouldPreserveTerminalSuccess(currentStatus) {
    return currentStatus === "pr-created" || currentStatus === "merged";
}
export async function updateFatalRunStatus(opts) {
    if (opts.projectId) {
        const store = PostgresStore.forProject(opts.projectId);
        try {
            const currentRun = await store.getRun(opts.runId);
            if (shouldPreserveTerminalSuccess(currentRun?.status)) {
                return;
            }
            await store.updateRun(opts.runId, { status: "failed", completed_at: opts.completedAt });
        }
        finally {
            store.close();
        }
        return;
    }
    const store = ForemanStore.forProject(opts.projectPath);
    try {
        const currentRun = await Promise.resolve(store.getRun(opts.runId));
        if (shouldPreserveTerminalSuccess(currentRun?.status)) {
            return;
        }
        await Promise.resolve(store.updateRun(opts.runId, { status: "failed", completed_at: opts.completedAt }));
    }
    finally {
        store.close();
    }
}
//# sourceMappingURL=agent-worker-fatal-path.js.map