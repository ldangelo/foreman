import { Command } from "commander";
import { ForemanStore } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
export declare const sentinelCommand: Command;
export interface SentinelCommandTaskClient extends ITaskClient {
    create(title: string, opts: {
        type: string;
        priority: string;
        description?: string;
        labels?: string[];
    }): Promise<Issue>;
}
export declare function createSentinelTaskClient(projectPath: string): Promise<SentinelCommandTaskClient>;
export declare function wrapPostgresSentinelStore(store: PostgresStore, projectId: string): {
    close: () => void;
    isOpen: () => boolean;
    logEvent: (pid: string, eventType: "sentinel-start" | "sentinel-pass" | "sentinel-fail", data: Record<string, unknown>) => Promise<void>;
    recordSentinelRun: (run: Parameters<ForemanStore["recordSentinelRun"]>[0]) => Promise<void>;
    updateSentinelRun: (id: string, updates: Parameters<ForemanStore["updateSentinelRun"]>[1]) => Promise<void>;
    upsertSentinelConfig: (_projectId: string, config: Parameters<ForemanStore["upsertSentinelConfig"]>[1]) => Promise<void>;
    getSentinelConfig: (_projectId: string) => Promise<import("../../lib/store.js").SentinelConfigRow | null>;
    getSentinelRuns: (_projectId: string, limit?: number) => Promise<import("../../lib/store.js").SentinelRunRow[]>;
};
//# sourceMappingURL=sentinel.d.ts.map