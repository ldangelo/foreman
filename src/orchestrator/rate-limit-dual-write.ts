import type { ForemanStore, RunProgress } from "../lib/store.js";
import type { PostgresStore } from "../lib/postgres-store.js";

export function createDualWriteStore(
  localStore: ForemanStore,
  pgStore: PostgresStore,
  preferRegisteredPostgres = false,
  logFn: (msg: string) => void = () => undefined,
) {
  const mirror = <T>(op: Promise<T>, label: string): void => {
    void op.catch((err: unknown) => {
      const msg = err instanceof Error ? err.message : String(err);
      logFn(`[postgres-mirror] ${label} failed (non-fatal): ${msg}`);
    });
  };

  return Object.assign(Object.create(Object.getPrototypeOf(localStore)), localStore, {
    close(): void {
      localStore.close();
      pgStore.close();
    },
    sendMessage(runId: string, senderAgentType: string, recipientAgentType: string, subject: string, body: string): void {
      void Promise.resolve().then(() => pgStore.sendMessage(runId, senderAgentType, recipientAgentType, subject, body)).catch((err: unknown) => {
        const msg = err instanceof Error ? err.message : String(err);
        logFn(`[postgres-mirror] sendMessage failed (non-fatal): ${msg}`);
      });
    },
    updateRun(runId: string, updates: Record<string, unknown>): void {
      localStore.updateRun(runId, updates as never);
      mirror(pgStore.updateRun(runId, updates as never), "updateRun");
    },
    updateRunProgress(runId: string, progress: RunProgress): void {
      localStore.updateRunProgress(runId, progress);
      const op = pgStore.updateRunProgress(runId, progress);
      mirror(op, "updateRunProgress");
    },
    logEvent(projectId: string, eventType: string, data: Record<string, unknown>, runId?: string): void {
      localStore.logEvent(projectId, eventType as never, data, runId);
      if (runId) {
        mirror(pgStore.logEvent(projectId, eventType as never, data, runId), `logEvent:${eventType}`);
      }
    },
    async logRateLimitEvent(
      projectId: string,
      model: string,
      phase: string,
      error: string,
      retryAfterSeconds?: number,
      runId?: string,
    ): Promise<void> {
      if (preferRegisteredPostgres) {
        try {
          await pgStore.logRateLimitEvent(
            projectId,
            model,
            phase,
            error,
            retryAfterSeconds,
            runId,
          );
          return;
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          logFn(`[postgres-mirror] logRateLimitEvent failed (non-fatal): ${msg}`);
        }
      }

      try {
        localStore.logRateLimitEvent(projectId, model, phase, error, retryAfterSeconds, runId);
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        logFn(`[postgres-mirror] logRateLimitEvent local fallback failed (non-fatal): ${msg}`);
      }
    },
  }) as ForemanStore;
}
