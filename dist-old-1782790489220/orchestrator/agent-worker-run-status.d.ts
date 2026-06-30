import type { Run } from "../lib/store.js";
export declare function updateTerminalRunStatus(opts: {
    runId: string;
    projectId?: string;
    projectPath: string;
    updates: Partial<Pick<Run, "status" | "completed_at" | "cooldown_until">>;
}): Promise<void>;
//# sourceMappingURL=agent-worker-run-status.d.ts.map