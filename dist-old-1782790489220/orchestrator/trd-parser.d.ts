import type { Priority, TrdTask, SlingPlan, RiskLevel } from "./types.js";
export interface ColumnMap {
    id: number;
    task: number;
    estimate: number | null;
    deps: number | null;
    files: number | null;
    status: number | null;
}
/**
 * Auto-detect column indices from a markdown table header row.
 * Returns a ColumnMap. Throws SLING-010 if ID or Task columns are missing.
 */
export declare function parseTableHeader(headerRow: string): ColumnMap;
/**
 * Split a markdown table row into cell values, trimming whitespace.
 */
export declare function splitTableRow(row: string): string[];
/**
 * Parse a single table row into a TrdTask using the column map.
 */
export declare function parseTableRow(row: string, columns: ColumnMap): TrdTask;
export interface EpicMeta {
    title: string;
    description: string;
    documentId: string;
    version?: string;
    epicId?: string;
}
export declare function parseEpic(content: string): EpicMeta;
export interface SprintHeader {
    number: number;
    suffix: string;
    title: string;
    goal: string;
    frRefs: string[];
    priority: Priority;
}
export declare function parseSprintHeader(line: string): SprintHeader | null;
export declare function parseStoryHeader(line: string): {
    ref: string;
    title: string;
} | null;
export declare function parseAcceptanceCriteria(content: string): Map<string, string>;
export declare function parseRiskRegister(content: string): Map<string, RiskLevel>;
export declare function parseQualityRequirements(content: string): string | undefined;
export interface SprintSummary {
    focus: string;
    estimatedHours: number;
    deliverables: string;
}
export declare function parseSprintSummary(content: string): Map<number, SprintSummary>;
/**
 * Parse a TRD markdown document into a SlingPlan.
 * Throws SLING-002 if no tasks are extracted.
 */
export declare function parseTrd(content: string): SlingPlan;
//# sourceMappingURL=trd-parser.d.ts.map