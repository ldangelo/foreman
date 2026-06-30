/**
 * Build a commander option argParser that strictly accepts non-negative
 * base-10 integers ("0", "7").
 *
 * Unlike bare parseInt, it rejects values parseInt would silently truncate
 * ("1.5" → 1, "7abc" → 7) by throwing commander's InvalidArgumentError, which
 * commander renders as a friendly `error: option '<flag>' argument ... is
 * invalid.` message.
 *
 * Shared by `purge logs --days` and `doctor --log-days`.
 */
export declare function parseNonNegativeIntOption(flag: string): (value: string) => number;
/**
 * Print the standard CLI dry-run notice when `dryRun` is truthy.
 *
 * Shared by reset, retry, stop, purge-logs, and purge-zombie-runs, which all
 * previously duplicated the exact same chalk call.
 */
export declare function printDryRunNotice(dryRun: boolean | undefined): void;
/**
 * Print the standard one-line deprecation notice for a renamed CLI spelling.
 *
 * Written to stderr (so scripted stdout parsing of the delegated command is
 * unaffected) in yellow, e.g.:
 *   'foreman purge-logs' is deprecated — use 'foreman purge logs' instead.
 */
export declare function printDeprecationNotice(oldSpelling: string, newSpelling: string): void;
export interface PurgeSummaryOptions {
    dryRun: boolean;
    /** Subject noun phrase, e.g. "log group(s)" or "zombie run(s)". */
    subject: string;
    /** Past-tense verb, e.g. "deleted" or "purged". */
    verb: string;
    /** Number of items affected (or that would be affected in dry-run mode). */
    count: number;
    skipped: number;
    errors: number;
    /** Extra detail rendered in parentheses after the count phrase, e.g. "2.0 MB". */
    detail?: string;
    /** Dim hint printed after a dry-run summary. */
    dryRunHint?: string;
    /** Render the done summary in yellow when errors occurred (purge-logs behavior). */
    warnOnErrors?: boolean;
}
/**
 * Print the standard purge-style result summary (preceded by a blank line).
 *
 * Dry-run:  "Dry run complete — N <subject> would be <verb>[ (detail)], S skipped, E error(s)."
 * Applied:  "Done — N <subject> <verb>[ (detail)], S skipped, E error(s)."
 */
export declare function printPurgeSummary(opts: PurgeSummaryOptions): void;
//# sourceMappingURL=cli-output.d.ts.map