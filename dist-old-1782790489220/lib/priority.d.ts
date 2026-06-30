/**
 * Normalize priority to a numeric value 0-4.
 * P0=critical, P1=high, P2=medium, P3=low, P4=backlog.
 * Returns 4 (lowest) for any invalid/unrecognized input.
 */
export declare function normalizePriority(p: string | number): number;
/**
 * Format a priority value as a string for the br CLI (returns "0"-"4").
 */
export declare function formatPriorityForBr(p: string | number): string;
//# sourceMappingURL=priority.d.ts.map