/**
 * `foreman watch` — Single-pane unified operator dashboard.
 *
 * Surfaces three live data streams simultaneously:
 * 1. Agent Panel — Active running agents with phase, cost, tool activity
 * 2. Board Panel — Compact task status summary (read-only)
 * 3. Inbox Panel — Live agent mail stream
 *
 * Keyboard navigation:
 *   Tab        — Cycle focus: Agents → Board → Inbox
 *   1-9        — Expand agent card by index (Agents panel)
 *   a          — Approve backlog task (Board panel, focused)
 *   r          — Retry failed/stuck task (Board panel, focused)
 *   j / k      — Navigate tasks (Board panel)
 *   b          — Open full board (`foreman board`)
 *   i          — Open full inbox (`foreman inbox`)
 *   ?          — Toggle help overlay
 *   q / Esc    — Quit
 *
 * Options:
 *   --refresh <ms>   Refresh interval in ms (default: 5000)
 *   --inbox-limit <n> Max inbox messages shown (default: 5)
 *   --no-watch        One-shot snapshot, then exit
 *   --no-board        Hide board panel
 *   --no-inbox        Hide inbox panel
 *   --project <id>    Filter to specific project
 */
import { Command } from "commander";
/**
 * `foreman dashboard` is a deprecated alias of `foreman watch`. When the
 * command was invoked via the alias (detected from argv), print a one-line
 * deprecation notice. Exported for testing.
 *
 * Only argv[2] — the command token in `node foreman <command> ...` — is
 * checked, so option values like `foreman watch --project dashboard` never
 * trigger a false positive. (Commander reports the canonical name, not the
 * alias, at action time, so argv inspection is required; a global flag placed
 * before the command would merely skip the notice, which is harmless.)
 */
export declare function maybePrintDashboardAliasNotice(argv?: readonly string[]): void;
export declare const watchCommand: Command;
//# sourceMappingURL=index.d.ts.map