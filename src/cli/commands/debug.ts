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
import { createTrpcClient } from "../../lib/trpc-client.js";
import { runWithPiSdk } from "../../orchestrator/pi-sdk-runner.js";
import { loadAndInterpolate } from "../../orchestrator/template-loader.js";
import { getHighspeedModel } from "../../lib/config.js";
import { listRegisteredProjects, resolveRepoRootProjectPath } from "./project-task-support.js";

interface DaemonRunRow {
  id: string;
  project_id: string;
  bead_id: string;
  status: string;
  branch: string;
  agent_type: string | null;
  session_key: string | null;
  worktree_path: string | null;
  progress: string | null;
  base_branch: string | null;
  merge_strategy: string | null;
  queued_at: string;
  started_at: string | null;
  finished_at: string | null;
  created_at: string;
}

interface DaemonMailMessage {
  id: string;
  run_id: string;
  sender_agent_type: string;
  recipient_agent_type: string;
  subject: string;
  body: string;
  read: number;
  created_at: string;
  deleted_at: string | null;
}

interface DaemonDebugContext {
  client: ReturnType<typeof createTrpcClient>;
  projectId: string;
  projectPath: string;
}

function adaptDaemonRun(row: DaemonRunRow): Run {
  const statusMap: Record<string, Run["status"]> = {
    pending: "pending",
    running: "running",
    success: "completed",
    failure: "failed",
    cancelled: "reset",
    skipped: "reset",
  };
  return {
    id: row.id,
    project_id: row.project_id,
    seed_id: row.bead_id,
    agent_type: row.agent_type ?? "daemon",
    session_key: row.session_key,
    worktree_path: row.worktree_path,
    status: statusMap[row.status] ?? "failed",
    started_at: row.started_at,
    completed_at: row.finished_at,
    created_at: row.created_at,
    progress: row.progress,
    base_branch: row.base_branch,
    merge_strategy: (row.merge_strategy as Run["merge_strategy"]) ?? null,
  };
}

function adaptDaemonMessage(row: DaemonMailMessage): Message {
  return {
    id: row.id,
    run_id: row.run_id,
    sender_agent_type: row.sender_agent_type,
    recipient_agent_type: row.recipient_agent_type,
    subject: row.subject,
    body: row.body,
    read: row.read,
    created_at: row.created_at,
    deleted_at: row.deleted_at,
  };
}

async function resolveDaemonDebugContext(projectPath: string): Promise<DaemonDebugContext | null> {
  try {
    const projects = await listRegisteredProjects();
    const project = projects.find((record) => record.path === projectPath);
    if (!project) return null;
    return { client: createTrpcClient(), projectId: project.id, projectPath };
  } catch {
    return null;
  }
}

async function resolveDaemonRuns(context: DaemonDebugContext, beadId: string): Promise<Run[]> {
  const rows = await context.client.runs.list({ projectId: context.projectId, beadId, limit: 50 }) as DaemonRunRow[];
  return rows.map(adaptDaemonRun);
}

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

  // Truncate log to last 30 lines AND cap total size to ~100KB
  const LOG_LINES = 30;
  const LOG_MAX_CHARS = 100_000;
  const logSection = logContent
    ? `## Agent Worker Log (last ${LOG_LINES} lines)\n\`\`\`\n${logContent.split("\n").slice(-LOG_LINES).join("\n").slice(-LOG_MAX_CHARS)}\n\`\`\``
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
    const projectPath = await resolveRepoRootProjectPath({});
    const daemon = await resolveDaemonDebugContext(projectPath);
    const store = ForemanStore.forProject(projectPath);

    // Find runs for this seed
    const runs = daemon ? await resolveDaemonRuns(daemon, beadId) : store.getRunsForSeed(beadId);
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
    const progress = daemon ? null : store.getRunProgress(run.id);
    const runSummary = formatRunSummary(run, progress as Record<string, unknown> | null);

    // 2. Mail messages
    const allMessages = daemon
      ? (await daemon.client.mail.list({ projectId: daemon.projectId, runId: run.id }) as DaemonMailMessage[]).map(adaptDaemonMessage)
      : store.getAllMessages(run.id);
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
