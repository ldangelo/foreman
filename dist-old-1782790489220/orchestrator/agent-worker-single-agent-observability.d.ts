import type { ForemanStore, RunProgress } from "../lib/store.js";
import type { PostgresStore } from "../lib/postgres-store.js";
type SingleAgentProgressStore = Pick<ForemanStore, "updateRunProgress">;
type SingleAgentEventStore = Pick<ForemanStore, "logEvent">;
type RegisteredSingleAgentStore = Pick<PostgresStore, "updateRunProgress" | "logEvent">;
export declare function writeSingleAgentProgress(localStore: SingleAgentProgressStore, registeredReadStore: RegisteredSingleAgentStore | undefined, runId: string, progress: RunProgress, log: (msg: string) => void): Promise<void>;
export declare function writeSingleAgentTerminalEvent(localStore: SingleAgentEventStore, registeredReadStore: RegisteredSingleAgentStore | undefined, projectId: string, runId: string, eventType: "complete" | "fail" | "stuck", data: Record<string, unknown>, log: (msg: string) => void): Promise<void>;
export {};
//# sourceMappingURL=agent-worker-single-agent-observability.d.ts.map