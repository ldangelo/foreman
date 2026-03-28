import { Command } from "commander";
import { ForemanStore } from "../../lib/store.js";
export interface StopOpts {
    list?: boolean;
    force?: boolean;
    dryRun?: boolean;
}
export interface StopResult {
    stopped: number;
    errors: string[];
    skipped: number;
}
/**
 * Core stop logic extracted for testability.
 * Returns the exit code (0 = success, 1 = error).
 */
export declare function stopAction(id: string | undefined, opts: StopOpts, store: ForemanStore, projectPath: string): Promise<number>;
/**
 * List active runs with full details.
 */
export declare function listActiveRuns(store: ForemanStore, projectPath: string): void;
export declare const stopCommand: Command;
//# sourceMappingURL=stop.d.ts.map