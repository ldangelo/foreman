import type { ForemanStore, RunProgress } from "../lib/store.js";
import type { PostgresStore } from "../lib/postgres-store.js";

type SingleAgentProgressStore = Pick<ForemanStore, "updateRunProgress">;
type SingleAgentEventStore = Pick<ForemanStore, "logEvent">;
type RegisteredSingleAgentStore = Pick<PostgresStore, "updateRunProgress" | "logEvent">;

export async function writeSingleAgentProgress(
  localStore: SingleAgentProgressStore,
  registeredReadStore: RegisteredSingleAgentStore | undefined,
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
      log(`[agent-worker] registered single-agent progress write failed (non-fatal); falling back to local store: ${msg}`);
    }
  }

  try {
    await Promise.resolve(localStore.updateRunProgress(runId, progress));
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[agent-worker] local single-agent progress write failed (non-fatal): ${msg}`);
  }
}

export async function writeSingleAgentTerminalEvent(
  localStore: SingleAgentEventStore,
  registeredReadStore: RegisteredSingleAgentStore | undefined,
  projectId: string,
  runId: string,
  eventType: "complete" | "fail" | "stuck",
  data: Record<string, unknown>,
  log: (msg: string) => void,
): Promise<void> {
  if (registeredReadStore) {
    try {
      await registeredReadStore.logEvent(projectId, eventType, data, runId);
      return;
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      log(`[agent-worker] registered single-agent terminal event write failed (non-fatal); falling back to local store: ${msg}`);
    }
  }

  try {
    localStore.logEvent(projectId, eventType, data, runId);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[agent-worker] local single-agent terminal event write failed (non-fatal): ${msg}`);
  }
}
