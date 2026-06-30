import { Command } from "commander";
import type { ITaskClient } from "../../lib/task-client.js";
/**
 * Instantiate the native task-tracking client.
 */
export declare function createMergeTaskClient(projectPath: string, registeredProjectId?: string): Promise<ITaskClient>;
export declare const mergeCommand: Command;
//# sourceMappingURL=merge.d.ts.map