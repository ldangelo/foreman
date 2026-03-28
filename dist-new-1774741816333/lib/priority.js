/**
 * Normalize priority to a numeric value 0-4.
 * P0=critical, P1=high, P2=medium, P3=low, P4=backlog.
 * Returns 4 (lowest) for any invalid/unrecognized input.
 */
export function normalizePriority(p) {
    if (typeof p === "number") {
        return Number.isInteger(p) && p >= 0 && p <= 4 ? p : 4;
    }
    if (p == null) {
        return 4;
    }
    const s = String(p).trim();
    // Handle "P0" through "P4" (case-insensitive)
    const pPrefixed = /^[Pp]([0-4])$/.exec(s);
    if (pPrefixed) {
        return parseInt(pPrefixed[1], 10);
    }
    // Handle "0" through "4"
    const numeric = /^([0-4])$/.exec(s);
    if (numeric) {
        return parseInt(numeric[1], 10);
    }
    return 4;
}
/**
 * Format a priority value as a string for the br CLI (returns "0"-"4").
 */
export function formatPriorityForBr(p) {
    return String(normalizePriority(p));
}
//# sourceMappingURL=priority.js.map