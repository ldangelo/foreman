/**
 * Backward-compatibility re-exports from beads.ts.
 * New code should import from beads.ts directly.
 */
export type { Bead as Task, BeadDetail as TaskDetail, BeadGraph as TaskGraph } from "./beads.js";
export { BeadsClient as TasksClient, execBd as execSd, unwrapBdResponse as unwrapSdResponse } from "./beads.js";
