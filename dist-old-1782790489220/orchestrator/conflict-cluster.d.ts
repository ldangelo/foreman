import type { MergeQueueEntry } from "./merge-queue.js";
/**
 * Build an adjacency list from files_modified overlap.
 * Two entries overlap if they share any file in their files_modified arrays.
 */
export declare function buildOverlapGraph(entries: MergeQueueEntry[]): Map<number, Set<number>>;
/**
 * Find connected components in the overlap graph using BFS.
 * Returns an array of clusters, where each cluster is a sorted array of entry IDs.
 */
export declare function findClusters(graph: Map<number, Set<number>>): number[][];
/**
 * Order entries so that entries within the same cluster are processed consecutively.
 * Within each cluster, maintain FIFO order (by enqueued_at).
 * Clusters are ordered by the earliest enqueued_at in each cluster.
 */
export declare function orderByCluster(entries: MergeQueueEntry[]): MergeQueueEntry[];
/**
 * After a merge commit, re-evaluate remaining entries for new overlaps.
 * Entries that both touch files in mergedFiles gain a new edge between them.
 * Returns updated cluster assignments.
 */
export declare function reCluster(entries: MergeQueueEntry[], mergedFiles: string[]): number[][];
//# sourceMappingURL=conflict-cluster.d.ts.map