import type { ForemanStore, RunProgress } from "../lib/store.js";
import type { PostgresStore } from "../lib/postgres-store.js";
export declare function writeMarkStuckProgress(localStore: ForemanStore, registeredReadStore: PostgresStore | undefined, runId: string, progress: RunProgress, log: (msg: string) => void): Promise<void>;
export declare function writeMarkStuckEvent(localStore: ForemanStore, registeredReadStore: PostgresStore | undefined, projectId: string, runId: string, eventType: "stuck" | "fail", data: Record<string, unknown>, log: (msg: string) => void): Promise<void>;
//# sourceMappingURL=agent-worker-mark-stuck-observability.d.ts.map