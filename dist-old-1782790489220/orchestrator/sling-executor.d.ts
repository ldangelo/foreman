import type { NativeTaskStore } from "../lib/task-store.js";
import type { SlingPlan, SlingOptions, SlingResult, ParallelResult, Priority } from "./types.js";
export declare function toTrackerPriority(priority: Priority): string;
export declare function toTrackerType(kind: string): string;
export type ProgressCallback = (processed: number, total: number, tracker: "native") => void;
export declare function execute(plan: SlingPlan, parallel: ParallelResult, options: SlingOptions, taskStore: NativeTaskStore, onProgress?: ProgressCallback): Promise<SlingResult>;
//# sourceMappingURL=sling-executor.d.ts.map