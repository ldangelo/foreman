import chalk from "chalk";

/**
 * Print the standard CLI dry-run notice when `dryRun` is truthy.
 *
 * Shared by reset, retry, stop, purge-logs, and purge-zombie-runs, which all
 * previously duplicated the exact same chalk call.
 */
export function printDryRunNotice(dryRun: boolean | undefined): void {
  if (dryRun) {
    console.log(chalk.yellow("(dry run — no changes will be made)\n"));
  }
}

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
export function printPurgeSummary(opts: PurgeSummaryOptions): void {
  console.log();
  const detail = opts.detail ? ` (${opts.detail})` : "";
  const tail = `${opts.skipped} skipped, ${opts.errors} error(s).`;

  if (opts.dryRun) {
    console.log(
      chalk.yellow(
        `Dry run complete — ${opts.count} ${opts.subject} would be ${opts.verb}${detail}, ${tail}`,
      ),
    );
    if (opts.dryRunHint) {
      console.log(chalk.dim(opts.dryRunHint));
    }
  } else {
    const color = opts.warnOnErrors && opts.errors > 0 ? chalk.yellow : chalk.green;
    console.log(
      color(`Done — ${opts.count} ${opts.subject} ${opts.verb}${detail}, ${tail}`),
    );
  }
}
