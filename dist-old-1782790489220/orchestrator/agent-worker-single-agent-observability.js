export async function writeSingleAgentProgress(localStore, registeredReadStore, runId, progress, log) {
    if (registeredReadStore) {
        try {
            await registeredReadStore.updateRunProgress(runId, progress);
            return;
        }
        catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            log(`[agent-worker] registered single-agent progress write failed (non-fatal); falling back to local store: ${msg}`);
        }
    }
    try {
        await Promise.resolve(localStore.updateRunProgress(runId, progress));
    }
    catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        log(`[agent-worker] local single-agent progress write failed (non-fatal): ${msg}`);
    }
}
export async function writeSingleAgentTerminalEvent(localStore, registeredReadStore, projectId, runId, eventType, data, log) {
    if (registeredReadStore) {
        try {
            await registeredReadStore.logEvent(projectId, eventType, data, runId);
            return;
        }
        catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            log(`[agent-worker] registered single-agent terminal event write failed (non-fatal); falling back to local store: ${msg}`);
        }
    }
    try {
        localStore.logEvent(projectId, eventType, data, runId);
    }
    catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        log(`[agent-worker] local single-agent terminal event write failed (non-fatal): ${msg}`);
    }
}
//# sourceMappingURL=agent-worker-single-agent-observability.js.map