import type { ForemanStore, RunProgress } from "../lib/store.js";

type MirrorStore = {
  close(): void;
  sendMessage(runId: string, senderAgentType: string, recipientAgentType: string, subject: string, body: string): void | Promise<void>;
  updateRun(runId: string, updates: Record<string, unknown>): void | Promise<void>;
  updateRunProgress(runId: string, progress: RunProgress): void | Promise<void>;
  logEvent(projectId: string, eventType: string, data: Record<string, unknown>, runId?: string): void | Promise<void>;
  logRateLimitEvent(projectId: string, model: string, phase: string, error: string, retryAfterSeconds?: number, runId?: string): void | Promise<void>;
};

export function createDualWriteStore(
  localStore: ForemanStore,
  pgStore: MirrorStore,
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
      mirror(Promise.resolve(pgStore.updateRun(runId, updates)), "updateRun");
    },
    updateRunProgress(runId: string, progress: RunProgress): void {
      localStore.updateRunProgress(runId, progress);
      const op = Promise.resolve(pgStore.updateRunProgress(runId, progress));
      mirror(op, "updateRunProgress");
    },
    logEvent(projectId: string, eventType: string, data: Record<string, unknown>, runId?: string): void {
      localStore.logEvent(projectId, eventType as never, data, runId);
      if (runId) {
        mirror(Promise.resolve(pgStore.logEvent(projectId, eventType, data, runId)), `logEvent:${eventType}`);
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
