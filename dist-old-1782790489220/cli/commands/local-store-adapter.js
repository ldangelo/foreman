/**
 * Wrap a local ForemanStore in an async adapter so it can be used
 * interchangeably with the Postgres-backed store implementations.
 */
export function wrapLocalRunStore(store) {
    return {
        getProjectByPath: async (path) => store.getProjectByPath(path),
        getRun: async (id) => store.getRun(id),
        getActiveRuns: async (projectId) => store.getActiveRuns(projectId),
        getRunsByStatus: async (status, projectId) => store.getRunsByStatus(status, projectId),
        getRunsForSeed: async (seedId, projectId) => store.getRunsForSeed(seedId, projectId),
        updateRun: async (runId, updates) => store.updateRun(runId, updates),
        deleteRun: async (runId) => store.deleteRun(runId),
        logEvent: async (projectId, eventType, data, runId) => store.logEvent(projectId, eventType, data, runId),
        close: () => store.close(),
        isOpen: () => store.isOpen(),
    };
}
/**
 * Call `close()` on a store-like object if it exposes one.
 *
 * Replaces the repeated `if ("close" in store && typeof store.close ===
 * "function")` blocks in command teardown paths.
 */
export function closeStoreIfPossible(store) {
    if (store !== null &&
        typeof store === "object" &&
        "close" in store &&
        typeof store.close === "function") {
        store.close();
    }
}
//# sourceMappingURL=local-store-adapter.js.map