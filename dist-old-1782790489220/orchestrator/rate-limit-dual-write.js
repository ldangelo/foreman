export function createDualWriteStore(localStore, pgStore, preferRegisteredPostgres = false, logFn = () => undefined) {
    const mirror = (op, label) => {
        void op.catch((err) => {
            const msg = err instanceof Error ? err.message : String(err);
            logFn(`[postgres-mirror] ${label} failed (non-fatal): ${msg}`);
        });
    };
    return Object.assign(Object.create(Object.getPrototypeOf(localStore)), localStore, {
        close() {
            localStore.close();
            pgStore.close();
        },
        sendMessage(runId, senderAgentType, recipientAgentType, subject, body) {
            void Promise.resolve().then(() => pgStore.sendMessage(runId, senderAgentType, recipientAgentType, subject, body)).catch((err) => {
                const msg = err instanceof Error ? err.message : String(err);
                logFn(`[postgres-mirror] sendMessage failed (non-fatal): ${msg}`);
            });
        },
        updateRun(runId, updates) {
            localStore.updateRun(runId, updates);
            mirror(pgStore.updateRun(runId, updates), "updateRun");
        },
        updateRunProgress(runId, progress) {
            localStore.updateRunProgress(runId, progress);
            const op = pgStore.updateRunProgress(runId, progress);
            mirror(op, "updateRunProgress");
        },
        logEvent(projectId, eventType, data, runId) {
            localStore.logEvent(projectId, eventType, data, runId);
            if (runId) {
                mirror(pgStore.logEvent(projectId, eventType, data, runId), `logEvent:${eventType}`);
            }
        },
        async logRateLimitEvent(projectId, model, phase, error, retryAfterSeconds, runId) {
            if (preferRegisteredPostgres) {
                try {
                    await pgStore.logRateLimitEvent(projectId, model, phase, error, retryAfterSeconds, runId);
                    return;
                }
                catch (err) {
                    const msg = err instanceof Error ? err.message : String(err);
                    logFn(`[postgres-mirror] logRateLimitEvent failed (non-fatal): ${msg}`);
                }
            }
            try {
                localStore.logRateLimitEvent(projectId, model, phase, error, retryAfterSeconds, runId);
            }
            catch (err) {
                const msg = err instanceof Error ? err.message : String(err);
                logFn(`[postgres-mirror] logRateLimitEvent local fallback failed (non-fatal): ${msg}`);
            }
        },
    });
}
//# sourceMappingURL=rate-limit-dual-write.js.map