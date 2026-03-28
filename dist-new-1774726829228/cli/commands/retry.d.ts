import { Command } from "commander";
import { BeadsRustClient } from "../../lib/beads-rust.js";
import { ForemanStore } from "../../lib/store.js";
import { Dispatcher } from "../../orchestrator/dispatcher.js";
import type { ModelSelection } from "../../orchestrator/types.js";
export interface RetryOpts {
    dispatch?: boolean;
    model?: ModelSelection;
    dryRun?: boolean;
}
/**
 * Core retry logic extracted for testability.
 * Returns the exit code (0 = success, 1 = error).
 */
export declare function retryAction(beadId: string, opts: RetryOpts, beadsClient: BeadsRustClient, store: ForemanStore, projectPath: string, dispatcher?: Dispatcher): Promise<number>;
export declare const retryCommand: Command;
//# sourceMappingURL=retry.d.ts.map