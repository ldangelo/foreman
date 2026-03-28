import { Command } from "commander";
import type { ITaskClient } from "../../lib/task-client.js";
/**
 * Instantiate the br task-tracking client.
 *
 * TRD-024: sd backend removed. Always returns a BeadsRustClient after verifying
 * the binary exists.
 *
 * Throws if the br binary cannot be found.
 */
export declare function createMergeTaskClient(projectPath: string): Promise<ITaskClient>;
export declare const mergeCommand: Command;
//# sourceMappingURL=merge.d.ts.map