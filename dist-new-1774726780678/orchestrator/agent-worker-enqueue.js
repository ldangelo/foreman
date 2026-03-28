/**
 * Merge queue enqueue helper for agent-worker finalize phase.
 *
 * Extracted as a separate module so it can be unit-tested independently
 * of the agent-worker process lifecycle.
 */
import { MergeQueue } from "./merge-queue.js";
/**
 * Enqueue a completed branch into the merge queue.
 *
 * Fire-and-forget semantics: errors are captured in the result but never thrown.
 * This ensures finalization is never blocked by merge queue failures.
 */
export function enqueueToMergeQueue(options) {
    const { db, seedId, runId, getFilesModified } = options;
    try {
        // Collect modified files — tolerate failures
        let filesModified = [];
        try {
            filesModified = getFilesModified();
        }
        catch {
            // getFilesModified failed (e.g. git diff error) — proceed with empty list
        }
        const mq = new MergeQueue(db);
        const entry = mq.enqueue({
            branchName: `foreman/${seedId}`,
            seedId,
            runId,
            agentName: "pipeline",
            filesModified,
        });
        return { success: true, entry };
    }
    catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        return { success: false, error: msg };
    }
}
//# sourceMappingURL=agent-worker-enqueue.js.map