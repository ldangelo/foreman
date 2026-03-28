import type { BeadsRustClient } from "../lib/beads-rust.js";
import type { SlingPlan, SlingOptions, SlingResult, ParallelResult, Priority } from "./types.js";
export declare function toTrackerPriority(priority: Priority): string;
export declare function toTrackerType(kind: string): string;
export type ProgressCallback = (created: number, total: number, tracker: "sd" | "br") => void;
export declare function detectExistingEpic(documentId: string, seeds: BeadsRustClient | null, beadsRust: BeadsRustClient | null): Promise<{
    sdEpicId: string | null;
    brEpicId: string | null;
}>;
export declare function execute(plan: SlingPlan, parallel: ParallelResult, options: SlingOptions, seeds: BeadsRustClient | null, beadsRust: BeadsRustClient | null, onProgress?: ProgressCallback): Promise<SlingResult>;
//# sourceMappingURL=sling-executor.d.ts.map