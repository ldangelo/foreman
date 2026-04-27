import type { ForemanStore, RunProgress } from "../lib/store.js";
import type { PostgresStore } from "../lib/postgres-store.js";

export async function writeMarkStuckProgress(
  localStore: ForemanStore,
  registeredReadStore: PostgresStore | undefined,
  runId: string,
  progress: RunProgress,
  log: (msg: string) => void,
): Promise<void> {
  if (registeredReadStore) {
    try {
      await registeredReadStore.updateRunProgress(runId, progress);
      return;
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      log(`[markStuck] registered progress write failed (non-fatal); falling back to local store: ${msg}`);
    }
  }

  await Promise.resolve(localStore.updateRunProgress(runId, progress));
}

export async function writeMarkStuckEvent(
  localStore: ForemanStore,
  registeredReadStore: PostgresStore | undefined,
  projectId: string,
  runId: string,
  eventType: "stuck" | "fail",
  data: Record<string, unknown>,
  log: (msg: string) => void,
): Promise<void> {
  if (registeredReadStore) {
    try {
      await registeredReadStore.logEvent(projectId, eventType, data, runId);
      return;
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      log(`[markStuck] registered ${eventType} event write failed (non-fatal); falling back to local store: ${msg}`);
    }
  }

  localStore.logEvent(projectId, eventType, data, runId);
}
