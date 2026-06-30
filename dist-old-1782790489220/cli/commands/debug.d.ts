/**
 * `foreman debug <task-id>` — AI-powered execution analysis.
 *
 * Gathers all artifacts for a task's pipeline execution (logs, mail messages,
 * reports, run progress) and passes them to Opus in plan mode for deep-dive
 * analysis. Read-only — no file modifications.
 *
 * Note: `<task-id>` is the primary identifier. `--bead` is accepted as a
 * backward-compatible alias.
 */
import { Command } from "commander";
export declare const debugCommand: Command;
//# sourceMappingURL=debug.d.ts.map