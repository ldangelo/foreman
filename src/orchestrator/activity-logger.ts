/**
 * Activity logger — Generates ACTIVITY_LOG.json for self-documenting commits.
 *
 * Tracks phase execution data throughout a pipeline run and produces a
 * machine-readable activity log that is committed alongside code changes.
 *
 * This enables operators to understand what happened in a pipeline run
 * by inspecting the commit (via `git show HEAD:ACTIVITY_LOG.json`) without
 * needing to query the SQLite events table.
 *
 * @module src/orchestrator/activity-logger
 */

import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { VcsBackend } from "../lib/vcs/index.js";
import { inferProjectPathFromWorkspacePath } from "../lib/workspace-paths.js";

// ── Types ─────────────────────────────────────────────────────────────────

/**
 * Record of a single pipeline phase execution.
 * Extended from session-log.ts PhaseRecord to include observability fields.
 */
export interface PhaseRecord {
  /** Phase name (e.g., "explorer", "developer", "qa") */
  name: string;
  /** Execution surface used for this phase. */
  phaseType?: "prompt" | "command" | "bash" | "builtin";
  /** True if this phase was skipped */
  skipped: boolean;
  /** Whether the phase succeeded */
  success?: boolean;
  /** Cost in USD */
  costUsd?: number;
  /** Number of SDK turns */
  turns?: number;
  /** Error message if phase failed */
  error?: string;
  /** ISO 8601 timestamp when phase started */
  startedAt?: string;
  /** ISO 8601 timestamp when phase completed */
  completedAt?: string;
  /** Duration in seconds */
  durationSeconds?: number;
  /** Number of tool calls */
  toolCalls?: number;
  /** Tool call breakdown by tool name */
  toolBreakdown?: Record<string, number>;
  /** Files changed during this phase */
  filesChanged?: string[];
  /** Edit counts per file */
  editsByFile?: Record<string, number>;
  /** Commands run (for bash phases) */
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
  /** Verdict: pass, fail, skipped, unknown */
  verdict?: "pass" | "fail" | "skipped" | "unknown";
  /** Model used for this phase */
  model?: string;
}

/**
 * Commit information for activity log.
 */
export interface CommitInfo {
  /** Commit hash (short form for display) */
  hash: string;
  /** Commit message */
  message: string;
  /** ISO 8601 timestamp */
  timestamp: string;
  /** Author name */
  author?: string;
}

/**
 * Machine-readable activity log structure.
 * Written to ACTIVITY_LOG.json and committed with every branch.
 */
export interface ActivityLog {
  /** Seed/bead ID (e.g., "bd-ytzv") */
  seedId: string;
  /** Run ID (e.g., UUID) */
  runId: string;
  /** Phase execution records in order */
  phases: PhaseRecord[];
  /** Total cost in USD across all phases */
  totalCostUsd: number;
  /** Total SDK turns across all phases */
  totalTurns: number;
  /** Total tool calls across all phases */
  totalToolCalls: number;
  /** Deduplicated union of all files changed across phases */
  filesChangedTotal: string[];
  /** Commits made during this run */
  commits: CommitInfo[];
  /** Warnings detected during the run */
  warnings: string[];
  /** Number of developer retries (QA or review feedback loops) */
  retryLoops: number;
  /** ISO 8601 timestamp when this log was generated */
  generatedAt: string;
  /** Git diff stat output (when includeGitDiffStat is true) */
  gitDiffStat?: string;
  /** Total duration in seconds across all phases */
  totalDurationSeconds?: number;
}

/**
 * Options for generating an activity log.
 */
export interface GenerateActivityLogOptions {
  /** Absolute path to the worktree */
  worktreePath: string;
  /** Run ID */
  runId: string;
  /** Seed/bead ID */
  seedId: string;
  /** Phase records accumulated during pipeline execution */
  phases: PhaseRecord[];
  /** VCS backend for computing git diff and commit info */
  vcs: VcsBackend;
  /** Target branch for diff computation (e.g., "main", "dev") */
  targetBranch: string;
  /** Whether to include git diff stat output */
  includeGitDiffStat?: boolean;
}

// ── Helper functions ──────────────────────────────────────────────────────

/**
 * Compute the deduplicated union of all files changed across phases.
 */
export function computeFilesChangedTotal(phases: PhaseRecord[]): string[] {
  const fileSet = new Set<string>();
  for (const phase of phases) {
    if (phase.filesChanged) {
      for (const file of phase.filesChanged) {
        fileSet.add(file);
      }
    }
  }
  return Array.from(fileSet);
}

/**
 * Count the number of developer retries (developer phase reruns due to
 * QA or reviewer feedback).
 */
export function countRetries(phases: PhaseRecord[]): number {
  return phases.filter((p) => p.name.includes("retry")).length;
}

/**
 * Detect warnings from phase records.
 *
 * Warnings include:
 * - Guardrail vetoes
 * - Retry loops (multiple developer retries)
 * - Stale worktree events
 * - Phase failures
 */
export function detectWarnings(phases: PhaseRecord[]): string[] {
  const warnings: string[] = [];

  // Check for retry loops
  const devRetries = countRetries(phases);
  if (devRetries > 0) {
    warnings.push(`Developer phase retried ${devRetries} time(s) due to feedback`);
  }

  // Check for phase failures
  const failedPhases = phases.filter((p) => !p.skipped && p.success === false);
  if (failedPhases.length > 0) {
    warnings.push(
      `Failed phases: ${failedPhases.map((p) => p.name).join(", ")}`,
    );
  }

  const missingArtifacts = phases.filter(
    (p) => !p.skipped && p.success === true && p.artifactExpected && p.artifactPresent === false,
  );
  if (missingArtifacts.length > 0) {
    warnings.push(
      `Missing phase artifacts: ${missingArtifacts.map((p) => `${p.name} -> ${p.artifactExpected}`).join(", ")}`,
    );
  }

  const commandIntentWarnings = phases.filter(
    (p) => p.phaseType === "command" && p.commandHonored === false,
  );
  if (commandIntentWarnings.length > 0) {
    warnings.push(
      `Command phases without strong execution evidence: ${commandIntentWarnings.map((p) => p.name).join(", ")}`,
    );
  }

  for (const phase of phases) {
    for (const phaseWarning of phase.phaseWarnings ?? []) {
      warnings.push(`${phase.name}: ${phaseWarning}`);
    }
  }

  // Check for long-running phases (potential inefficiency)
  const longPhases = phases.filter(
    (p) =>
      !p.skipped &&
      p.durationSeconds !== undefined &&
      p.durationSeconds > 600, // > 10 minutes
  );
  if (longPhases.length > 0) {
    warnings.push(
      `Long-running phases (>10min): ${longPhases.map((p) => `${p.name} (${Math.round(p.durationSeconds! / 60)}min)`).join(", ")}`,
    );
  }

  return warnings;
}

/**
 * Get commit information from the worktree.
 *
 * Returns commits made on the current branch since it diverged from target.
 */
async function getCommitHistory(
  vcs: VcsBackend,
  worktreePath: string,
  targetBranch: string,
): Promise<CommitInfo[]> {
  const commits: CommitInfo[] = [];

  try {
    // Get the base commit (where target was when we branched)
    const baseRef = `origin/${targetBranch}`;

    // Try to get commits between origin/target and HEAD
    const diffOutput = await vcs.diff(worktreePath, baseRef, "HEAD");
    const lines = diffOutput.split("\n");

    // Parse git log output for commit info
    // Format: "commit <hash>" or "Author: <name>" or "Date: <date>"
    let currentCommit: Partial<CommitInfo> = {};
    for (const line of lines) {
      if (line.startsWith("commit ")) {
        if (currentCommit.hash) {
          commits.push(currentCommit as CommitInfo);
        }
        currentCommit = { hash: line.slice(7, 15) }; // Short hash
      } else if (line.startsWith("Author:")) {
        currentCommit.author = line.slice(8).trim();
      } else if (line.startsWith("Date:")) {
        currentCommit.timestamp = line.slice(5).trim();
      } else if (line.startsWith("    ") && !line.startsWith("    Author")) {
        // Commit message line (indented)
        currentCommit.message = (currentCommit.message ?? "") + line.trim() + " ";
      }
    }
    if (currentCommit.hash) {
      commits.push(currentCommit as CommitInfo);
    }
  } catch {
    // Best effort — return empty array if git operations fail
  }

  return commits;
}

/**
 * Get git diff stat output for the activity log.
 */
async function getGitDiffStat(
  vcs: VcsBackend,
  worktreePath: string,
  targetBranch: string,
): Promise<string> {
  try {
    const diffOutput = await vcs.diff(worktreePath, `origin/${targetBranch}`, "HEAD");
    // Extract the stat line from diff output
    // Git diff --stat format: "  file1.ts |  10 +++--  ... \n  file2.py |   5 +++ ..."
    const statLines: string[] = [];
    for (const line of diffOutput.split("\n")) {
      if (line.match(/^\s+.+\|/) || line.match(/^\s*\d+ file/)) {
        statLines.push(line);
      }
    }
    return statLines.join("\n");
  } catch {
    return "";
  }
}

// ── Main generator ────────────────────────────────────────────────────────

/**
 * Generate an ACTIVITY_LOG.json file in the worktree.
 *
 * Reads phase records accumulated during pipeline execution, computes
 * totals and warnings, and writes a machine-readable JSON file that
 * is committed with every branch.
 *
 * @param opts - Generation options
 */
export async function generateActivityLog(
  opts: GenerateActivityLogOptions,
): Promise<void> {
  const {
    worktreePath,
    runId,
    seedId,
    phases,
    vcs,
    targetBranch,
    includeGitDiffStat = false,
  } = opts;

  // Compute aggregates
  const totalCostUsd = phases.reduce(
    (sum, p) => sum + (p.costUsd ?? 0),
    0,
  );
  const totalTurns = phases.reduce((sum, p) => sum + (p.turns ?? 0), 0);
  const totalToolCalls = phases.reduce(
    (sum, p) => sum + (p.toolCalls ?? 0),
    0,
  );
  const totalDurationSeconds = phases.reduce(
    (sum, p) => sum + (p.durationSeconds ?? 0),
    0,
  );
  const filesChangedTotal = computeFilesChangedTotal(phases);
  const warnings = detectWarnings(phases);
  const retryLoops = countRetries(phases);

  // Get commit history
  const commits = await getCommitHistory(vcs, worktreePath, targetBranch);

  // Get git diff stat if requested
  let gitDiffStat: string | undefined;
  if (includeGitDiffStat) {
    gitDiffStat = await getGitDiffStat(vcs, worktreePath, targetBranch);
  }

  // Build activity log
  const activityLog: ActivityLog = {
    seedId,
    runId,
    phases: phases.map((p) => ({
      name: p.name,
      skipped: p.skipped,
      success: p.success,
      costUsd: p.costUsd,
      turns: p.turns,
      error: p.error,
      startedAt: p.startedAt,
      completedAt: p.completedAt,
      durationSeconds: p.durationSeconds,
      toolCalls: p.toolCalls,
      toolBreakdown: p.toolBreakdown,
      filesChanged: p.filesChanged,
      editsByFile: p.editsByFile,
      commandsRun: p.commandsRun,
      artifactExpected: p.artifactExpected,
      artifactPresent: p.artifactPresent,
      traceFile: p.traceFile,
      traceMarkdownFile: p.traceMarkdownFile,
      phaseWarnings: p.phaseWarnings,
      commandHonored: p.commandHonored,
      verdict: p.verdict,
      model: p.model,
    })),
    totalCostUsd,
    totalTurns,
    totalToolCalls,
    filesChangedTotal,
    commits,
    warnings,
    retryLoops,
    generatedAt: new Date().toISOString(),
    gitDiffStat,
    totalDurationSeconds,
  };

  // Write to file
  const filePath = join(worktreePath, "ACTIVITY_LOG.json");
  const content = JSON.stringify(activityLog, null, 2);
  await writeFile(filePath, content, "utf-8");
}

// ── Phase record helpers ──────────────────────────────────────────────────

/**
 * Create an initial PhaseRecord for a new phase.
 * Call this at phase start, then update with results at phase end.
 */
export function createPhaseRecord(
  name: string,
  model?: string,
  extra?: Pick<PhaseRecord, "phaseType" | "commandsRun" | "artifactExpected">,
): PhaseRecord {
  return {
    name,
    skipped: false,
    startedAt: new Date().toISOString(),
    model,
    phaseType: extra?.phaseType,
    commandsRun: extra?.commandsRun,
    artifactExpected: extra?.artifactExpected,
  };
}

/**
 * Finalize a PhaseRecord with completion data.
 * Call this at phase end with the phase result.
 */
export function finalizePhaseRecord(
  record: PhaseRecord,
  result: {
    success: boolean;
    costUsd: number;
    turns: number;
    tokensIn?: number;
    tokensOut?: number;
    error?: string;
    outputText?: string;
    toolCalls?: number;
    toolBreakdown?: Record<string, number>;
    filesChanged?: string[];
    editsByFile?: Record<string, number>;
    traceFile?: string;
    traceMarkdownFile?: string;
    traceWarnings?: string[];
    commandHonored?: boolean;
  },
): PhaseRecord {
  const completedAt = new Date().toISOString();
  const startedAt = record.startedAt ? new Date(record.startedAt) : new Date();
  const durationSeconds = (new Date(completedAt).getTime() - startedAt.getTime()) / 1000;

  // Determine verdict
  let verdict: "pass" | "fail" | "skipped" | "unknown" = "unknown";
  if (record.skipped) {
    verdict = "skipped";
  } else if (result.success) {
    verdict = "pass";
  } else {
    verdict = "fail";
  }

  return {
    ...record,
    completedAt,
    durationSeconds,
    success: result.success,
    costUsd: result.costUsd,
    turns: result.turns,
    error: result.error,
    toolCalls: result.toolCalls,
    toolBreakdown: result.toolBreakdown,
    filesChanged: result.filesChanged,
    editsByFile: result.editsByFile,
    artifactPresent: record.artifactExpected ? record.artifactPresent : undefined,
    traceFile: result.traceFile ?? record.traceFile,
    traceMarkdownFile: result.traceMarkdownFile ?? record.traceMarkdownFile,
    phaseWarnings: result.traceWarnings ?? record.phaseWarnings,
    commandHonored: result.commandHonored ?? record.commandHonored,
    verdict,
  };
}

/**
 * Write an incremental pipeline report after each phase completes.
 * Commits phase results as they finish so traceability is available in real-time.
 */
export async function writeIncrementalPipelineReport(opts: {
  worktreePath: string;
  seedId: string;
  runId: string;
  completedPhases: PhaseRecord[];
  targetBranch?: string;
  vcsBranchName?: string;
}): Promise<void> {
  const { worktreePath, seedId, runId, completedPhases, targetBranch, vcsBranchName } = opts;
  const reportsDir = join(worktreePath, "docs", "reports", seedId);

  await mkdir(reportsDir, { recursive: true });

  const totalCostUsd = completedPhases.reduce((sum, p) => sum + (p.costUsd ?? 0), 0);
  const totalTurns = completedPhases.reduce((sum, p) => sum + (p.turns ?? 0), 0);
  const totalToolCalls = completedPhases.reduce((sum, p) => sum + (p.toolCalls ?? 0), 0);
  const totalDuration = completedPhases.reduce((sum, p) => sum + (p.durationSeconds ?? 0), 0);

  const phaseRows = completedPhases.map((p) => {
    const duration = p.durationSeconds ? `${p.durationSeconds.toFixed(1)}s` : "-";
    const cost = p.costUsd ? `$${p.costUsd.toFixed(4)}` : "-";
    const verdict = p.skipped ? "skipped" : p.success ? "pass" : "FAIL";
    const error = p.error ? " " + p.error.slice(0, 80) : "";
    const phaseType = p.phaseType ?? "prompt";
    const artifact = p.artifactExpected
      ? `${p.artifactExpected} (${p.artifactPresent === false ? "missing" : "present"})`
      : "—";
    const trace = p.traceFile ? `\`${p.traceFile}\`` : "—";
    return `| \`${p.name}\` | ${phaseType} | ${verdict} | ${duration} | ${cost} | ${p.turns ?? 0} turns | ${artifact} | ${trace} |${error} |`;
  }).join("\n");

  const currentPhase = completedPhases[completedPhases.length - 1];
  const pipelineStatus = currentPhase?.verdict === "fail" ? "FAILED"
    : currentPhase?.skipped ? "RUNNING"
    : "IN_PROGRESS";

  const uniqueFiles = [...new Set(completedPhases.flatMap(p => p.filesChanged ?? []))];
  const filesSection = uniqueFiles.length > 0
    ? uniqueFiles.map(f => `- \`${f}\``).join("\n")
    : "_No files changed yet_";
  const warnings = detectWarnings(completedPhases);
  const warningSection = warnings.length > 0
    ? ["## Warnings", "", ...warnings.map((warning) => `- ${warning}`), ""]
    : [];

  const report = [
    "# Pipeline Report — " + seedId,
    "",
    "**Run ID:** `" + runId + "`",
    "**Target Branch:** `" + (targetBranch ?? "—") + "`",
    "**VCS Branch:** `" + (vcsBranchName ?? "—") + "`",
    "**Generated:** " + new Date().toISOString(),
    "**Status:** " + pipelineStatus,
    "",
    "## Summary",
    "",
    "| Metric | Value |",
    "|--------|-------|",
    "| Phases completed | " + completedPhases.length + " |",
    "| Total cost | $" + totalCostUsd.toFixed(4) + " |",
    "| Total turns | " + totalTurns + " |",
    "| Total tool calls | " + totalToolCalls + " |",
    "| Total duration | " + totalDuration.toFixed(1) + "s |",
    "",
    "## Phase Results",
    "",
    "| Phase | Type | Status | Duration | Cost | Turns | Artifact | Trace | Error |",
    "|-------|------|--------|----------|------|-------|----------|-------|--------|",
    phaseRows,
    "",
    "## Phase Inputs",
    "",
    ...completedPhases.flatMap((phase) =>
      phase.commandsRun && phase.commandsRun.length > 0
        ? [
          `### ${phase.name}`,
          "",
          `- Type: ${phase.phaseType ?? "prompt"}`,
          ...phase.commandsRun.map((command) => `- Input: \`${command}\``),
          ...(phase.traceFile ? [`- Trace: \`${phase.traceFile}\``] : []),
          ...(phase.commandHonored !== undefined ? [`- Command honored: ${phase.commandHonored ? "yes" : "no"}`] : []),
          ...((phase.phaseWarnings ?? []).map((warning) => `- Warning: ${warning}`)),
          "",
        ]
        : [],
    ),
    ...warningSection,
    "## Files Changed",
    "",
    filesSection,
  ].join("\n");

  const reportPath = join(reportsDir, "PIPELINE_REPORT.md");
  await writeFile(reportPath, report, "utf-8");
}
