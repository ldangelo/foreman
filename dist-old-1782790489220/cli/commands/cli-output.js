import chalk from "chalk";
import { InvalidArgumentError } from "commander";
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
export function parseNonNegativeIntOption(flag) {
    return (value) => {
        const trimmed = value.trim();
        if (!/^\d+$/.test(trimmed)) {
            throw new InvalidArgumentError(`${flag} must be a non-negative integer`);
        }
        return Number.parseInt(trimmed, 10);
    };
}
/**
 * Print the standard CLI dry-run notice when `dryRun` is truthy.
 *
 * Shared by reset, retry, stop, purge-logs, and purge-zombie-runs, which all
 * previously duplicated the exact same chalk call.
 */
export function printDryRunNotice(dryRun) {
    if (dryRun) {
        console.log(chalk.yellow("(dry run — no changes will be made)\n"));
    }
}
/**
 * Print the standard one-line deprecation notice for a renamed CLI spelling.
 *
 * Written to stderr (so scripted stdout parsing of the delegated command is
 * unaffected) in yellow, e.g.:
 *   'foreman purge-logs' is deprecated — use 'foreman purge logs' instead.
 */
export function printDeprecationNotice(oldSpelling, newSpelling) {
    console.error(chalk.yellow(`'${oldSpelling}' is deprecated — use '${newSpelling}' instead.`));
}
/**
 * Print the standard purge-style result summary (preceded by a blank line).
 *
 * Dry-run:  "Dry run complete — N <subject> would be <verb>[ (detail)], S skipped, E error(s)."
 * Applied:  "Done — N <subject> <verb>[ (detail)], S skipped, E error(s)."
 */
export function printPurgeSummary(opts) {
    console.log();
    const detail = opts.detail ? ` (${opts.detail})` : "";
    const tail = `${opts.skipped} skipped, ${opts.errors} error(s).`;
    if (opts.dryRun) {
        console.log(chalk.yellow(`Dry run complete — ${opts.count} ${opts.subject} would be ${opts.verb}${detail}, ${tail}`));
        if (opts.dryRunHint) {
            console.log(chalk.dim(opts.dryRunHint));
        }
    }
    else {
        const color = opts.warnOnErrors && opts.errors > 0 ? chalk.yellow : chalk.green;
        console.log(color(`Done — ${opts.count} ${opts.subject} ${opts.verb}${detail}, ${tail}`));
    }
}
//# sourceMappingURL=cli-output.js.map