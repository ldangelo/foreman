import { Command } from "commander";
import { BeadsRustClient } from "../../lib/beads-rust.js";
import { ForemanStore } from "../../lib/store.js";
export interface PurgeZombieRunsOpts {
    dryRun?: boolean;
}
export interface PurgeZombieRunsResult {
    checked: number;
    purged: number;
    skipped: number;
    errors: number;
}
/**
 * Core purge logic extracted for testability.
 * Returns a summary result object.
 */
export declare function purgeZombieRunsAction(opts: PurgeZombieRunsOpts, beadsClient: BeadsRustClient, store: ForemanStore, projectPath: string): Promise<PurgeZombieRunsResult>;
export declare const purgeZombieRunsCommand: Command;
//# sourceMappingURL=purge-zombie-runs.d.ts.map