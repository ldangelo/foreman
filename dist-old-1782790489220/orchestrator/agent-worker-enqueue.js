/**
 * Merge queue enqueue helper for agent-worker finalize phase.
 *
 * Extracted as a separate module so it can be unit-tested independently
 * of the agent-worker process lifecycle.
 */
import { MergeQueue } from "./merge-queue.js";
import { PostgresMergeQueue } from "./postgres-merge-queue.js";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";
/**
 * Enqueue a completed branch into the merge queue.
 *
 * Fire-and-forget semantics: errors are captured in the result but never thrown.
 * This ensures finalization is never blocked by merge queue failures.
 */
export async function enqueueToMergeQueue(options) {
    const { db, projectId, seedId, runId, operation = "auto_merge", getFilesModified } = options;
    try {
        // Collect modified files — tolerate failures
        let filesModified = [];
        try {
            filesModified = getFilesModified();
        }
        catch {
            // getFilesModified failed (e.g. git diff error) — proceed with empty list
        }
        const entry = projectId
            ? await new PostgresMergeQueue(projectId, new PostgresAdapter()).enqueue({
                branchName: `foreman/${seedId}`,
                seedId,
                runId,
                operation,
                agentName: "pipeline",
                filesModified,
            })
            : db
                ? new MergeQueue(db).enqueue({
                    branchName: `foreman/${seedId}`,
                    seedId,
                    runId,
                    operation,
                    agentName: "pipeline",
                    filesModified,
                })
                : null;
        if (!entry) {
            return { success: false, error: "merge queue db is required when projectId is not set" };
        }
        return { success: true, entry };
    }
    catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        return { success: false, error: msg };
    }
}
//# sourceMappingURL=agent-worker-enqueue.js.map