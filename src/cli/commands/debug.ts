/**
 * `foreman debug <bead-id>` — AI-powered execution analysis.
 *
 * Gathers all artifacts for a bead's pipeline execution (logs, mail messages,
 * reports, run progress) and passes them to Opus in plan mode for deep-dive
 * analysis. Read-only — no file modifications.
 */

import { Command } from "commander";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import chalk from "chalk";
import { ForemanStore } from "../../lib/store.js";
import type { Run, Message } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import { runWithPiSdk } from "../../orchestrator/pi-sdk-runner.js";
import { loadAndInterpolate } from "../../orchestrator/template-loader.js";
import { getHighspeedModel } from "../../lib/config.js";

// ── Artifact collection ─────────────────────────────────────────────────────

const REPORT_FILES = [
  "EXPLORER_REPORT.md",
  "DEVELOPER_REPORT.md",
  "QA_REPORT.md",
  "REVIEW.md",
  "FINALIZE_REPORT.md",
  "SESSION_LOG.md",
  "TASK.md",
  "BLOCKED.md",
  "RUN_LOG.md",
];

function readFileOrNull(path: string): string | null {
  try { return readFileSync(path, "utf-8"); } catch { return null; }
}

function findLogFile(runId: string): string | null {
  const logsDir = join(process.env.HOME ?? "~", ".foreman", "logs");
  if (!existsSync(logsDir)) return null;
  // Try direct match
  const logPath = join(logsDir, `${runId}.log`);
  if (existsSync(logPath)) return readFileOrNull(logPath);
  // Try .err
  const errPath = join(logsDir, `${runId}.err`);
  if (existsSync(errPath)) return readFileOrNull(errPath);
  return null;
}

function formatMessages(messages: Message[]): string {
  if (messages.length === 0) return "(no messages)";
  return messages.map((m) => {
    const ts = m.created_at;
    return `[${ts}] ${m.sender_agent_type} → ${m.recipient_agent_type} | ${m.subject}\n  ${m.body.slice(0, 500)}`;
  }).join("\n\n");
}

function formatRunSummary(run: Run, progress: Record<string, unknown> | null): string {
  const lines = [
    `Run ID: ${run.id}`,
    `Seed: ${run.seed_id}`,
    `Status: ${run.status}`,
    `Agent Type: ${run.agent_type}`,
    `Started: ${run.started_at ?? "unknown"}`,
    `Completed: ${run.completed_at ?? "still running"}`,
    `Worktree: ${run.worktree_path ?? "unknown"}`,
  ];
  if (progress) {
    lines.push(`Progress: ${JSON.stringify(progress, null, 2)}`);
  }
  return lines.join("\n");
}

// ── Diagnostic prompt ───────────────────────────────────────────────────────

function buildDiagnosticPrompt(
  seedId: string,
  runSummary: string,
  messages: string,
  reports: Record<string, string>,
  logContent: string | null,
): string {
  const reportSections = Object.entries(reports)
    .map(([name, content]) => `### ${name}\n\`\`\`\n${content.slice(0, 5000)}\n\`\`\``)
    .join("\n\n");

  const logSection = logContent
    ? `## Agent Worker Log (last 200 lines)\n\`\`\`\n${logContent.split("\n").slice(-200).join("\n")}\n\`\`\``
    : "## Agent Worker Log\n(not found)";

  return loadAndInterpolate("debug.md", {
    seedId,
    runSummary,
    messages,
    reportSections: reportSections ? `## Pipeline Reports\n${reportSections}` : "## Pipeline Reports\n(none found)",
    logSection,
  });
}

// ── Command ─────────────────────────────────────────────────────────────────

export const debugCommand = new Command("debug")
  .description("AI-powered analysis of a bead's pipeline execution")
  .argument("<bead-id>", "The bead/seed ID to analyze")
  .option("--run <id>", "Specific run ID (default: latest run for this seed)")
  .option("--model <model>", "Model to use for analysis")
  .option("--raw", "Print collected artifacts without AI analysis")
  .action(async (beadId: string, opts: { run?: string; model?: string; raw?: boolean }) => {
    const projectPath = await getRepoRoot(process.cwd());
    const store = ForemanStore.forProject(projectPath);

    // Find runs for this seed
    const runs = store.getRunsForSeed(beadId);
    if (runs.length === 0) {
      console.error(chalk.red(`No runs found for seed ${beadId}`));
      process.exit(1);
    }

    // Select the target run
    const run = opts.run
      ? runs.find((r) => r.id === opts.run || r.id.startsWith(opts.run!))
      : runs[0]; // latest

    if (!run) {
      console.error(chalk.red(`Run ${opts.run} not found for seed ${beadId}`));
      console.error(`Available runs: ${runs.map((r) => `${r.id.slice(0, 8)} (${r.status})`).join(", ")}`);
      process.exit(1);
    }

    console.log(chalk.bold(`\nAnalyzing ${beadId} — run ${run.id.slice(0, 8)} (${run.status})\n`));

    // 1. Run summary + progress
    const progress = store.getRunProgress(run.id);
    const runSummary = formatRunSummary(run, progress as Record<string, unknown> | null);

    // 2. Mail messages
    const allMessages = store.getAllMessages(run.id);
    const messagesText = formatMessages(allMessages);

    // 3. Reports from worktree
    const reports: Record<string, string> = {};
    const worktreePath = run.worktree_path;
    if (worktreePath && existsSync(worktreePath)) {
      for (const file of REPORT_FILES) {
        const content = readFileOrNull(join(worktreePath, file));
        if (content) reports[file] = content;
      }
    }

    // 4. Agent worker log
    const logContent = findLogFile(run.id);

    // 5. Bead info from br
    let beadInfo: string | null = null;
    try {
      const { execFileSync } = await import("node:child_process");
      beadInfo = execFileSync("br", ["show", beadId], { encoding: "utf-8", cwd: projectPath });
    } catch { /* non-fatal */ }
    if (beadInfo) reports["BEAD_INFO"] = beadInfo;

    store.close();

    // Print artifact summary
    console.log(chalk.dim(`  Messages: ${allMessages.length}`));
    console.log(chalk.dim(`  Reports:  ${Object.keys(reports).join(", ") || "(none)"}`));
    console.log(chalk.dim(`  Log:      ${logContent ? "found" : "not found"}`));
    console.log();

    if (opts.raw) {
      console.log(chalk.bold("─── Run Summary ───"));
      console.log(runSummary);
      console.log(chalk.bold("\n─── Messages ───"));
      console.log(messagesText);
      for (const [name, content] of Object.entries(reports)) {
        console.log(chalk.bold(`\n─── ${name} ───`));
        console.log(content.slice(0, 3000));
      }
      if (logContent) {
        console.log(chalk.bold("\n─── Log (last 100 lines) ───"));
        console.log(logContent.split("\n").slice(-100).join("\n"));
      }
      return;
    }

    // Build the diagnostic prompt and send to AI
    const prompt = buildDiagnosticPrompt(beadId, runSummary, messagesText, reports, logContent);

    const model = opts.model ?? getHighspeedModel();
    console.log(chalk.yellow(`Sending to ${model} for analysis...\n`));

    const result = await runWithPiSdk({
      prompt,
      systemPrompt: "You are a senior engineering lead performing a post-mortem analysis of an AI agent pipeline execution. Be thorough, specific, and actionable. Use markdown formatting.",
      cwd: projectPath,
      model,
      allowedTools: [], // Read-only — no tools needed, just analysis
      onText: (text) => process.stdout.write(text), // Stream output live
    });

    if (!result.success) {
      console.error(chalk.red(`\nAnalysis failed: ${result.errorMessage}`));
      process.exit(1);
    }

    // Print result if not already streamed
    if (result.outputText && !result.outputText.includes("\n")) {
      console.log(result.outputText);
    }

    console.log(chalk.green(`\n\nAnalysis complete ($${result.costUsd.toFixed(4)})\n`));
  });
