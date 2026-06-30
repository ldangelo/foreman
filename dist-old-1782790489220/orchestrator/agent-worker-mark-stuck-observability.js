export async function writeMarkStuckProgress(localStore, registeredReadStore, runId, progress, log) {
    if (registeredReadStore) {
        try {
            await registeredReadStore.updateRunProgress(runId, progress);
            return;
        }
        catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            log(`[markStuck] registered progress write failed (non-fatal); falling back to local store: ${msg}`);
        }
    }
    await Promise.resolve(localStore.updateRunProgress(runId, progress));
}
export async function writeMarkStuckEvent(localStore, registeredReadStore, projectId, runId, eventType, data, log) {
    if (registeredReadStore) {
        try {
            await registeredReadStore.logEvent(projectId, eventType, data, runId);
            return;
        }
        catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            log(`[markStuck] registered ${eventType} event write failed (non-fatal); falling back to local store: ${msg}`);
        }
    }
    localStore.logEvent(projectId, eventType, data, runId);
}
//# sourceMappingURL=agent-worker-mark-stuck-observability.js.map