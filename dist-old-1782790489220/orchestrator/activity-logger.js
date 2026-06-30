/**
 * Activity logger — Generates ACTIVITY_LOG.json for self-documenting commits.
 *
 * Tracks phase execution data throughout a pipeline run and produces a
 * machine-readable activity log that is committed alongside code changes.
 *
 * This enables operators to understand what happened in a pipeline run
 * by inspecting the commit (via `git show HEAD:ACTIVITY_LOG.json`) without
 * needing to query the Postgres events table.
 *
 * @module src/orchestrator/activity-logger
 */
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { getForemanHomePath } from "../lib/foreman-paths.js";
// ── Helper functions ──────────────────────────────────────────────────────
/**
 * Compute the deduplicated union of all files changed across phases.
 */
export function computeFilesChangedTotal(phases) {
    const fileSet = new Set();
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
export function countRetries(phases) {
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
export function detectWarnings(phases) {
    const warnings = [];
    // Check for retry loops
    const devRetries = countRetries(phases);
    if (devRetries > 0) {
        warnings.push(`Developer phase retried ${devRetries} time(s) due to feedback`);
    }
    // Check for phase failures
    const failedPhases = phases.filter((p) => !p.skipped && p.success === false);
    if (failedPhases.length > 0) {
        warnings.push(`Failed phases: ${failedPhases.map((p) => p.name).join(", ")}`);
    }
    const commandContractFailures = failedPhases.filter((p) => p.phaseType === "command" && p.error?.includes("Command phase contract violated:"));
    if (commandContractFailures.length > 0) {
        warnings.push(`Command phase contract failures: ${commandContractFailures.map((p) => p.name).join(", ")}`);
    }
    const missingArtifacts = phases.filter((p) => !p.skipped && p.success === true && p.artifactExpected && p.artifactPresent === false);
    if (missingArtifacts.length > 0) {
        warnings.push(`Missing phase artifacts: ${missingArtifacts.map((p) => `${p.name} -> ${p.artifactExpected}`).join(", ")}`);
    }
    const commandIntentWarnings = phases.filter((p) => p.phaseType === "command" && p.commandHonored === false);
    if (commandIntentWarnings.length > 0) {
        warnings.push(`Command phases without strong execution evidence: ${commandIntentWarnings.map((p) => p.name).join(", ")}`);
    }
    for (const phase of phases) {
        for (const phaseWarning of phase.phaseWarnings ?? []) {
            warnings.push(`${phase.name}: ${phaseWarning}`);
        }
    }
    // Check for long-running phases (potential inefficiency)
    const longPhases = phases.filter((p) => !p.skipped &&
        p.durationSeconds !== undefined &&
        p.durationSeconds > 600);
    if (longPhases.length > 0) {
        warnings.push(`Long-running phases (>10min): ${longPhases.map((p) => `${p.name} (${Math.round(p.durationSeconds / 60)}min)`).join(", ")}`);
    }
    return warnings;
}
/**
 * Get commit information from the worktree.
 *
 * Returns commits made on the current branch since it diverged from target.
 */
async function getCommitHistory(vcs, worktreePath, targetBranch) {
    const commits = [];
    try {
        // Get the base commit (where target was when we branched)
        const baseRef = `origin/${targetBranch}`;
        // Try to get commits between origin/target and HEAD
        const diffOutput = await vcs.diff(worktreePath, baseRef, "HEAD");
        const lines = diffOutput.split("\n");
        // Parse git log output for commit info
        // Format: "commit <hash>" or "Author: <name>" or "Date: <date>"
        let currentCommit = {};
        for (const line of lines) {
            if (line.startsWith("commit ")) {
                if (currentCommit.hash) {
                    commits.push(currentCommit);
                }
                currentCommit = { hash: line.slice(7, 15) }; // Short hash
            }
            else if (line.startsWith("Author:")) {
                currentCommit.author = line.slice(8).trim();
            }
            else if (line.startsWith("Date:")) {
                currentCommit.timestamp = line.slice(5).trim();
            }
            else if (line.startsWith("    ") && !line.startsWith("    Author")) {
                // Commit message line (indented)
                currentCommit.message = (currentCommit.message ?? "") + line.trim() + " ";
            }
        }
        if (currentCommit.hash) {
            commits.push(currentCommit);
        }
    }
    catch {
        // Best effort — return empty array if git operations fail
    }
    return commits;
}
/**
 * Get git diff stat output for the activity log.
 */
async function getGitDiffStat(vcs, worktreePath, targetBranch) {
    try {
        const diffOutput = await vcs.diff(worktreePath, `origin/${targetBranch}`, "HEAD");
        // Extract the stat line from diff output
        // Git diff --stat format: "  file1.ts |  10 +++--  ... \n  file2.py |   5 +++ ..."
        const statLines = [];
        for (const line of diffOutput.split("\n")) {
            if (line.match(/^\s+.+\|/) || line.match(/^\s*\d+ file/)) {
                statLines.push(line);
            }
        }
        return statLines.join("\n");
    }
    catch {
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
export async function generateActivityLog(opts) {
    const { worktreePath, runId, seedId, phases, vcs, targetBranch, includeGitDiffStat = false, } = opts;
    // Compute aggregates
    const totalCostUsd = phases.reduce((sum, p) => sum + (p.costUsd ?? 0), 0);
    const totalTurns = phases.reduce((sum, p) => sum + (p.turns ?? 0), 0);
    const totalToolCalls = phases.reduce((sum, p) => sum + (p.toolCalls ?? 0), 0);
    const totalDurationSeconds = phases.reduce((sum, p) => sum + (p.durationSeconds ?? 0), 0);
    const filesChangedTotal = computeFilesChangedTotal(phases);
    const warnings = detectWarnings(phases);
    const retryLoops = countRetries(phases);
    // Get commit history
    const commits = await getCommitHistory(vcs, worktreePath, targetBranch);
    // Get git diff stat if requested
    let gitDiffStat;
    if (includeGitDiffStat) {
        gitDiffStat = await getGitDiffStat(vcs, worktreePath, targetBranch);
    }
    // Build activity log
    const activityLog = {
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
            workflowName: p.workflowName,
            workflowPath: p.workflowPath,
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
    // Write to Foreman's report store, not the agent worktree.
    const reportsDir = getForemanHomePath("reports", "runs", runId, seedId);
    await mkdir(reportsDir, { recursive: true });
    const filePath = join(reportsDir, "ACTIVITY_LOG.json");
    const content = JSON.stringify(activityLog, null, 2);
    await writeFile(filePath, content, "utf-8");
}
// ── Phase record helpers ──────────────────────────────────────────────────
/**
 * Create an initial PhaseRecord for a new phase.
 * Call this at phase start, then update with results at phase end.
 */
export function createPhaseRecord(name, model, extra) {
    return {
        name,
        skipped: false,
        startedAt: new Date().toISOString(),
        model,
        phaseType: extra?.phaseType,
        commandsRun: extra?.commandsRun,
        artifactExpected: extra?.artifactExpected,
        workflowName: extra?.workflowName,
        workflowPath: extra?.workflowPath,
    };
}
/**
 * Finalize a PhaseRecord with completion data.
 * Call this at phase end with the phase result.
 */
export function finalizePhaseRecord(record, result) {
    const completedAt = new Date().toISOString();
    const startedAt = record.startedAt ? new Date(record.startedAt) : new Date();
    const durationSeconds = (new Date(completedAt).getTime() - startedAt.getTime()) / 1000;
    // Determine verdict
    let verdict = "unknown";
    if (record.skipped) {
        verdict = "skipped";
    }
    else if (result.success) {
        verdict = "pass";
    }
    else {
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
        workflowName: result.workflowName ?? record.workflowName,
        workflowPath: result.workflowPath ?? record.workflowPath,
        verdict,
    };
}
/**
 * Write an incremental pipeline report after each phase completes.
 * Commits phase results as they finish so traceability is available in real-time.
 */
export async function writeIncrementalPipelineReport(opts) {
    const { worktreePath, seedId, runId, completedPhases, targetBranch, vcsBranchName } = opts;
    const reportsDir = getForemanHomePath("reports", "runs", runId, seedId);
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
        "**Workflow:** `" + (currentPhase?.workflowName ?? "—") + "`",
        "**Workflow Path:** `" + (currentPhase?.workflowPath ?? "—") + "`",
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
        ...completedPhases.flatMap((phase) => phase.commandsRun && phase.commandsRun.length > 0
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
            : []),
        ...warningSection,
        "## Files Changed",
        "",
        filesSection,
    ].join("\n");
    const reportPath = join(reportsDir, "PIPELINE_REPORT.md");
    await writeFile(reportPath, report, "utf-8");
}
//# sourceMappingURL=activity-logger.js.map