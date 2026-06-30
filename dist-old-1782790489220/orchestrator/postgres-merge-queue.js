import { orderByCluster } from "./conflict-cluster.js";
import { VcsBackendFactory } from "../lib/vcs/index.js";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";
export class PostgresMergeQueue {
    projectId;
    adapter;
    constructor(projectId, adapter = new PostgresAdapter()) {
        this.projectId = projectId;
        this.adapter = adapter;
    }
    async enqueue(input) {
        return this.adapter.enqueueMergeQueueEntry({
            projectId: this.projectId,
            branchName: input.branchName,
            seedId: input.seedId,
            runId: input.runId,
            operation: input.operation,
            agentName: input.agentName ?? null,
            filesModified: input.filesModified,
        });
    }
    async list(status) {
        return await this.adapter.listMergeQueue(this.projectId, status);
    }
    async dequeue() {
        const entries = await this.list("pending");
        const entry = entries[0];
        if (!entry)
            return null;
        await this.updateStatus(entry.id, "merging", { lastAttemptedAt: new Date().toISOString() });
        const refreshed = (await this.list()).find((row) => row.id === entry.id);
        return refreshed ?? null;
    }
    async getOrderedPending() {
        return orderByCluster(await this.list("pending"));
    }
    async updateStatus(id, status, extra) {
        await this.adapter.updateMergeQueueStatus(this.projectId, id, status, extra);
    }
    async remove(id) {
        await this.adapter.removeMergeQueueEntry(this.projectId, id);
    }
    async resetForRetry(seedId) {
        return await this.adapter.resetMergeQueueForRetry(this.projectId, seedId);
    }
    async getRetryableEntries() {
        return await this.adapter.listRetryableMergeQueue(this.projectId);
    }
    async reEnqueue(id) {
        return await this.adapter.reEnqueueMergeQueue(this.projectId, id);
    }
    async missingFromQueue() {
        return await this.adapter.listMissingFromMergeQueue(this.projectId);
    }
    async reconcile(repoPath, backend) {
        const vcs = backend ?? await VcsBackendFactory.create({ backend: "auto" }, repoPath);
        const completedRuns = await this.adapter.listPipelineRuns(this.projectId, { status: "success", limit: 1000 });
        const mqRows = await this.list();
        const existingRunIds = new Set(mqRows.map((r) => r.run_id));
        const existingSeedIds = new Set(mqRows.map((r) => r.seed_id));
        const defaultBranch = await vcs.detectDefaultBranch(repoPath);
        let enqueued = 0;
        let skipped = 0;
        let invalidBranch = 0;
        const failedToEnqueue = [];
        for (const run of completedRuns) {
            if (existingRunIds.has(run.id) || existingSeedIds.has(run.bead_id)) {
                skipped++;
                continue;
            }
            const branchName = `foreman/${run.bead_id}`;
            const exists = await vcs.branchExists(repoPath, branchName);
            if (!exists) {
                invalidBranch++;
                failedToEnqueue.push({ run_id: run.id, seed_id: run.bead_id, reason: `branch '${branchName}' not found` });
                continue;
            }
            const filesModified = await vcs.getChangedFiles(repoPath, defaultBranch, branchName);
            await this.enqueue({
                branchName,
                seedId: run.bead_id,
                runId: run.id,
                operation: run.merge_strategy === "pr" ? "create_pr" : "auto_merge",
                filesModified,
            });
            existingSeedIds.add(run.bead_id);
            enqueued++;
        }
        return { enqueued, skipped, invalidBranch, failedToEnqueue };
    }
}
//# sourceMappingURL=postgres-merge-queue.js.map