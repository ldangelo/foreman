import { Command } from "commander";
import { BeadsRustClient } from "../../lib/beads-rust.js";
/**
 * Instantiate the br task-tracking client.
 *
 * TRD-024: sd backend removed. Always returns a BeadsRustClient.
 *
 * Exported for unit testing.
 */
export declare function createPlanClient(projectPath: string): BeadsRustClient;
export declare const planCommand: Command;
//# sourceMappingURL=plan.d.ts.map