// ── buildOverlapGraph ────────────────────────────────────────────────────
/**
 * Build an adjacency list from files_modified overlap.
 * Two entries overlap if they share any file in their files_modified arrays.
 */
export function buildOverlapGraph(entries) {
    const graph = new Map();
    // Initialize all nodes
    for (const entry of entries) {
        graph.set(entry.id, new Set());
    }
    // Build a reverse index: file -> list of entry IDs that touch it
    const fileToEntries = new Map();
    for (const entry of entries) {
        for (const file of entry.files_modified) {
            const list = fileToEntries.get(file);
            if (list) {
                list.push(entry.id);
            }
            else {
                fileToEntries.set(file, [entry.id]);
            }
        }
    }
    // For each file touched by multiple entries, add edges between all of them
    for (const entryIds of fileToEntries.values()) {
        if (entryIds.length < 2)
            continue;
        for (let i = 0; i < entryIds.length; i++) {
            for (let j = i + 1; j < entryIds.length; j++) {
                graph.get(entryIds[i]).add(entryIds[j]);
                graph.get(entryIds[j]).add(entryIds[i]);
            }
        }
    }
    return graph;
}
// ── findClusters ─────────────────────────────────────────────────────────
/**
 * Find connected components in the overlap graph using BFS.
 * Returns an array of clusters, where each cluster is a sorted array of entry IDs.
 */
export function findClusters(graph) {
    const visited = new Set();
    const clusters = [];
    for (const nodeId of graph.keys()) {
        if (visited.has(nodeId))
            continue;
        // BFS from this node
        const cluster = [];
        const queue = [nodeId];
        visited.add(nodeId);
        while (queue.length > 0) {
            const current = queue.shift();
            cluster.push(current);
            const neighbors = graph.get(current);
            if (neighbors) {
                for (const neighbor of neighbors) {
                    if (!visited.has(neighbor)) {
                        visited.add(neighbor);
                        queue.push(neighbor);
                    }
                }
            }
        }
        clusters.push(cluster);
    }
    return clusters;
}
// ── orderByCluster ───────────────────────────────────────────────────────
/**
 * Order entries so that entries within the same cluster are processed consecutively.
 * Within each cluster, maintain FIFO order (by enqueued_at).
 * Clusters are ordered by the earliest enqueued_at in each cluster.
 */
export function orderByCluster(entries) {
    if (entries.length === 0)
        return [];
    const graph = buildOverlapGraph(entries);
    const clusterIds = findClusters(graph);
    // Build a lookup from entry ID to entry
    const entryById = new Map();
    for (const entry of entries) {
        entryById.set(entry.id, entry);
    }
    // For each cluster, resolve to entries and sort by enqueued_at (FIFO)
    const resolvedClusters = clusterIds.map((ids) => {
        const clusterEntries = ids.map((id) => entryById.get(id));
        clusterEntries.sort((a, b) => a.enqueued_at.localeCompare(b.enqueued_at));
        return clusterEntries;
    });
    // Sort clusters by the earliest enqueued_at in each cluster
    resolvedClusters.sort((a, b) => a[0].enqueued_at.localeCompare(b[0].enqueued_at));
    // Flatten: all entries from cluster 1, then cluster 2, etc.
    return resolvedClusters.flat();
}
// ── reCluster ────────────────────────────────────────────────────────────
/**
 * After a merge commit, re-evaluate remaining entries for new overlaps.
 * Entries that both touch files in mergedFiles gain a new edge between them.
 * Returns updated cluster assignments.
 */
export function reCluster(entries, mergedFiles) {
    if (entries.length === 0)
        return [];
    // Start with the natural overlap graph
    const graph = buildOverlapGraph(entries);
    // Find entries that overlap with the merged files
    const mergedFileSet = new Set(mergedFiles);
    const overlappingEntryIds = [];
    for (const entry of entries) {
        for (const file of entry.files_modified) {
            if (mergedFileSet.has(file)) {
                overlappingEntryIds.push(entry.id);
                break;
            }
        }
    }
    // Add edges between all entries that overlap with mergedFiles
    for (let i = 0; i < overlappingEntryIds.length; i++) {
        for (let j = i + 1; j < overlappingEntryIds.length; j++) {
            graph.get(overlappingEntryIds[i]).add(overlappingEntryIds[j]);
            graph.get(overlappingEntryIds[j]).add(overlappingEntryIds[i]);
        }
    }
    return findClusters(graph);
}
//# sourceMappingURL=conflict-cluster.js.map