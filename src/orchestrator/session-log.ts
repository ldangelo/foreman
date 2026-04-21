/**
 * Session log generation for pipeline-executed seeds.
 *
 * The /ensemble:sessionlog skill is only available in interactive Claude Code
 * (human-invoked), not through the Anthropic SDK's query() method. This module
 * provides a direct TypeScript replacement that the pipeline calls automatically
 * at completion, accumulating the same data that /ensemble:sessionlog would
 * otherwise capture interactively.
 *
 * Output: SessionLogs/session-DDMMYY-HH:MM.md in the worktree root.
 * These files are picked up by `git add -A` in finalize() and committed
 * to the branch, so they persist through merge to main.
 */

import { writeFile, mkdir } from "node:fs/promises";
import { join } from "node:path";

// ── Types ─────────────────────────────────────────────────────────────────

/**
 * Record of a single pipeline phase execution.
 */
export interface PhaseRecord {
  /** Phase name (e.g., "explorer", "developer", "qa", "reviewer") */
  name: string;
  /** Execution surface used for this phase. */
  phaseType?: "prompt" | "command" | "bash" | "builtin";
  /** True if this phase was skipped (e.g., --skip-explore or artifact already exists) */
  skipped: boolean;
  /** Whether the phase succeeded (undefined if skipped) */
  success?: boolean;
  /** Cost in USD (undefined if skipped) */
  costUsd?: number;
  /** Number of SDK turns (undefined if skipped) */
  turns?: number;
  /** Error message if the phase failed */
  error?: string;
  /** Commands run or prompts injected for this phase. */
  commandsRun?: string[];
  /** Expected artifact filename for this phase. */
  artifactExpected?: string;
  /** Whether the expected artifact existed when the phase finished. */
  artifactPresent?: boolean;
  /** Relative JSON trace path for this phase. */
  traceFile?: string;
  /** Relative markdown trace path for this phase. */
  traceMarkdownFile?: string;
  /** Observability warnings recorded for this phase. */
  phaseWarnings?: string[];
  /** Heuristic for whether a command workflow was actually honored. */
  commandHonored?: boolean;
  /** Workflow name used for this phase. */
  workflowName?: string;
  /** Workflow YAML source path used for this phase. */
  workflowPath?: string;
}

/**
 * Data collected during a pipeline run, used to generate a session log.
 * Populated incrementally by runPipeline() as each phase completes.
 */
export interface SessionLogData {
  /** Seed ID (e.g., "bd-p4y7") */
  seedId: string;
  /** Seed title */
  seedTitle: string;
  /** Seed description */
  seedDescription: string;
  /** Git branch name (e.g., "foreman/bd-p4y7") */
  branchName: string;
  /** Optional project name (basename of project directory) */
  projectName?: string;
  /** Phases executed in order, including skipped and retried phases */
  phases: PhaseRecord[];
  /** Total cost in USD across all phases */
  totalCostUsd: number;
  /** Total SDK turns across all phases */
  totalTurns: number;
  /** Unique files changed during development */
  filesChanged: string[];
  /** Number of developer retries (QA or review feedback loops) */
  devRetries: number;
  /** Final QA verdict ("pass", "fail", or "unknown") */
  qaVerdict: string;
}

// ── Filename formatting ───────────────────────────────────────────────────

/**
 * Format a Date as the session log filename.
 *
 * Convention matches existing SessionLogs/:
 *   session-DDMMYY-HH:MM.md
 *   e.g. session-170326-14:32.md for 2026-03-17 at 14:32
 */
export function formatSessionLogFilename(date: Date): string {
  const day = String(date.getDate()).padStart(2, "0");
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const year = String(date.getFullYear()).slice(-2);
  const hours = String(date.getHours()).padStart(2, "0");
  const minutes = String(date.getMinutes()).padStart(2, "0");
  return `session-${day}${month}${year}-${hours}:${minutes}.md`;
}

// ── Content generation ────────────────────────────────────────────────────

/**
 * Generate session log markdown content from pipeline run data.
 *
 * Produces a structured markdown document in the same format as manually-created
 * SessionLogs, capturing phases executed, costs, files changed, and any problems
 * encountered during the pipeline run.
 */
export function generateSessionLogContent(data: SessionLogData, date: Date): string {
  // NOTE: toISOString() derives the date in UTC, while formatSessionLogFilename()
  // uses local time. These can diverge for UTC+ users late at night (e.g. the
  // file is named session-180326-01:30.md but frontmatter says date: 2026-03-17).
  // This matches the inherited convention from /ensemble:sessionlog and is
  // accepted as-is; a future SessionLogData.baseBranch field could also carry
  // the caller's preferred date representation if this ever matters.
  const isoDate = date.toISOString().slice(0, 10); // YYYY-MM-DD (UTC)
  const {
    seedId,
    seedTitle,
    seedDescription,
    branchName,
    projectName,
    phases,
    totalCostUsd,
    totalTurns,
    filesChanged,
    devRetries,
    qaVerdict,
  } = data;

  const failedPhases = phases.filter((p) => !p.skipped && p.success === false);

  const lines: string[] = [];

  // ── Frontmatter ──────────────────────────────────────────────────────────
  lines.push("---");
  lines.push(`date: ${isoDate}`);
  if (projectName) {
    lines.push(`project: ${projectName}`);
  }
  lines.push(`branch: ${branchName}`);
  lines.push(`base_branch: main`);
  lines.push(`seed: ${seedId}`);
  lines.push("---");
  lines.push("");

  // ── Title ────────────────────────────────────────────────────────────────
  lines.push(`# Session Log: ${seedTitle}`);
  lines.push("");

  // ── Summary ──────────────────────────────────────────────────────────────
  lines.push("## Summary");
  lines.push("");
  lines.push(
    `Pipeline run for **${seedId}** — ${seedTitle}.`,
  );

  const desc = seedDescription.trim();
  if (desc && desc !== "(no description provided)") {
    lines.push("");
    const truncated = desc.length > 200 ? `${desc.slice(0, 200)}…` : desc;
    lines.push(`> ${truncated}`);
  }
  lines.push("");

  // Active (non-skipped) phase names form the pipeline description
  const activePhaseName = phases
    .filter((p) => !p.skipped)
    .map((p) => p.name)
    .join(" → ");
  lines.push(`Phases executed: ${activePhaseName || "(none)"}`);
  lines.push("");

  lines.push(`- **Total cost:** $${totalCostUsd.toFixed(4)}`);
  lines.push(`- **Total turns:** ${totalTurns}`);
  lines.push(`- **Files changed:** ${filesChanged.length}`);
  if (devRetries > 0) {
    lines.push(`- **Developer retries:** ${devRetries}`);
  }
  lines.push(`- **QA verdict:** ${qaVerdict}`);
  lines.push("");

  // ── Phases table ─────────────────────────────────────────────────────────
  lines.push("## Phases");
  lines.push("");
  lines.push("| Phase | Status | Cost | Turns |");
  lines.push("|-------|--------|------|-------|");
  for (const phase of phases) {
    let status: string;
    if (phase.skipped) {
      status = "⏭ skipped";
    } else if (phase.success === true) {
      status = "✓ passed";
    } else {
      status = "✗ failed";
    }
    const cost =
      phase.costUsd !== undefined ? `$${phase.costUsd.toFixed(4)}` : "—";
    const turns = phase.turns !== undefined ? String(phase.turns) : "—";
    lines.push(`| ${phase.name} | ${status} | ${cost} | ${turns} |`);
  }
  lines.push("");

  // ── Files changed ────────────────────────────────────────────────────────
  if (filesChanged.length > 0) {
    lines.push("## Files Changed");
    lines.push("");
    for (const f of filesChanged) {
      lines.push(`- \`${f}\``);
    }
    lines.push("");
  }

  // ── Problems & Resolutions ────────────────────────────────────────────────
  if (failedPhases.length > 0 || devRetries > 0) {
    lines.push("## Problems & Resolutions");
    lines.push("");

    for (const phase of failedPhases) {
      lines.push(`### ${phase.name} phase failed`);
      lines.push("");
      lines.push(`**Error:** ${phase.error ?? "unknown error"}`);
      lines.push("");
    }

    if (devRetries > 0) {
      lines.push("### Developer retries");
      lines.push("");
      lines.push(
        `The developer phase was retried ${devRetries} time(s) due to QA or review feedback.`,
      );
      lines.push("");
    }
  }

  // End with a trailing newline per POSIX convention so tools that expect
  // text files to end with \n (linters, diff, wc -l, etc.) are satisfied.
  return lines.join("\n") + "\n";
}

// ── File I/O ──────────────────────────────────────────────────────────────

/**
 * Write a session log to the SessionLogs/ directory.
 *
 * Called just before finalize() in runPipeline() so that `git add -A` picks
 * up the file and includes it in the seed's commit — replacing what the
 * human-only /ensemble:sessionlog skill would otherwise produce.
 *
 * @param basePath  Base directory where SessionLogs/ is created (typically
 *                  the worktree path so the file gets committed to the branch)
 * @param data      Pipeline data accumulated during the run
 * @param date      Timestamp for the filename (defaults to now)
 * @returns         Absolute path to the written session log file
 */
export async function writeSessionLog(
  basePath: string,
  data: SessionLogData,
  date: Date = new Date(),
): Promise<string> {
  const sessionLogsDir = join(basePath, "SessionLogs");
  await mkdir(sessionLogsDir, { recursive: true });

  const filename = formatSessionLogFilename(date);
  const filepath = join(sessionLogsDir, filename);
  const content = generateSessionLogContent(data, date);

  await writeFile(filepath, content, "utf-8");
  return filepath;
}
