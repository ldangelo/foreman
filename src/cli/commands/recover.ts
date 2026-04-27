/**
 * `foreman recover <bead-id>` — Autonomous recovery agent for pipeline failures.
 *
 * Gathers all artifacts for a bead's pipeline execution (logs, mail messages,
 * reports, run progress, test output, blocked beads, git log) and invokes an
 * Opus agent to diagnose and autonomously fix common failure modes:
 *
 *   test-failed   — post-merge npm test failures (stale cache, bad expectations, bugs)
 *   stuck         — agent pipeline that stopped responding
 *   stale-blocked — beads blocked by already-closed dependencies
 *
 * Unlike `foreman debug`, this command is NOT read-only — the agent has write
 * access and will make fixes, commit, and push when appropriate.
 */

import { Command } from "commander";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
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

interface DaemonRecoverContext {
  client: ReturnType<typeof createTrpcClient>;
  projectId: string;
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

async function resolveDaemonRecoverContext(projectPath: string): Promise<DaemonRecoverContext | null> {
  try {
    const projects = await listRegisteredProjects();
    const project = projects.find((record) => record.path === projectPath);
    if (!project) return null;
    return { client: createTrpcClient(), projectId: project.id };
  } catch {
    return null;
  }
}

// ── Types ────────────────────────────────────────────────────────────────────

type RecoveryReason = "test-failed" | "stuck" | "stale-blocked";

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
  const logPath = join(logsDir, `${runId}.log`);
  if (existsSync(logPath)) return readFileOrNull(logPath);
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

function runCommandSafe(args: string[], cwd: string): string {
  try {
    return execFileSync(args[0], args.slice(1), {
      encoding: "utf-8",
      cwd,
      timeout: 60_000,
    });
  } catch (err) {
    if (err instanceof Error && "stdout" in err) {
      return (err as NodeJS.ErrnoException & { stdout: string }).stdout ?? "(no output)";
    }
    return `(command failed: ${err instanceof Error ? err.message : String(err)})`;
  }
}

// ── Prompt builder ──────────────────────────────────────────────────────────

function buildRecoveryPrompt(opts: {
  beadId: string;
  reason: RecoveryReason;
  branchName: string;
  runId: string;
  projectRoot: string;
  runSummary: string;
  testOutput: string;
  blockedBeads: string;
  recentGitLog: string;
  reports: Record<string, string>;
  logContent: string | null;
}): string {
  const reportSections = Object.entries(opts.reports)
    .map(([name, content]) => `### ${name}\n\`\`\`\n${content.slice(0, 5000)}\n\`\`\``)
    .join("\n\n");

  const logSection = opts.logContent
    ? `## Agent Worker Log (last 200 lines)\n\`\`\`\n${opts.logContent.split("\n").slice(-200).join("\n")}\n\`\`\``
    : "## Agent Worker Log\n(not found)";

  return loadAndInterpolate("recover.md", {
    beadId: opts.beadId,
    reason: opts.reason,
    branchName: opts.branchName,
    runId: opts.runId,
    projectRoot: opts.projectRoot,
    runSummary: opts.runSummary,
    testOutput: opts.testOutput || "(not captured)",
    blockedBeads: opts.blockedBeads || "(none)",
    recentGitLog: opts.recentGitLog || "(not available)",
    reportSections: reportSections
      ? `## Pipeline Reports\n${reportSections}`
      : "## Pipeline Reports\n(none found)",
    logSection,
  });
}

// ── Command ─────────────────────────────────────────────────────────────────

export const recoverCommand = new Command("recover")
  .description("Autonomous recovery agent for pipeline failures")
  .argument("<bead-id>", "The bead/seed ID that needs recovery")
  .option(
    "--reason <reason>",
    "Failure reason: test-failed | stuck | stale-blocked",
    "test-failed",
  )
  .option("--run-id <id>", "Specific run ID (default: latest run for this seed)")
  .option("--output <text>", "Pre-captured test output to include in context")
  .option("--model <model>", "Model to use for recovery")
  .option("--raw", "Print collected context without invoking AI")
  .action(async (beadId: string, opts: {
    reason?: string;
    runId?: string;
    output?: string;
    model?: string;
    raw?: boolean;
  }) => {
    const reason = (opts.reason ?? "test-failed") as RecoveryReason;
    const validReasons: RecoveryReason[] = ["test-failed", "stuck", "stale-blocked"];
    if (!validReasons.includes(reason)) {
      console.error(chalk.red(`Invalid reason "${reason}". Must be one of: ${validReasons.join(", ")}`));
      process.exit(1);
    }

    const projectPath = await resolveRepoRootProjectPath({});
    const daemon = await resolveDaemonRecoverContext(projectPath);
    const store = ForemanStore.forProject(projectPath);

    // Find runs for this seed
    const runs = daemon
      ? ((await daemon.client.runs.list({ projectId: daemon.projectId, beadId, limit: 50 }) as DaemonRunRow[]).map(adaptDaemonRun))
      : store.getRunsForSeed(beadId);
    if (runs.length === 0) {
      console.error(chalk.red(`No runs found for seed ${beadId}`));
      process.exit(1);
    }

    // Select the target run
    const run = opts.runId
      ? runs.find((r) => r.id === opts.runId || r.id.startsWith(opts.runId!))
      : runs[0]; // latest

    if (!run) {
      console.error(chalk.red(`Run ${opts.runId} not found for seed ${beadId}`));
      console.error(`Available runs: ${runs.map((r) => `${r.id.slice(0, 8)} (${r.status})`).join(", ")}`);
      process.exit(1);
    }

    console.log(chalk.bold(`\nRecovery: ${beadId} — reason: ${reason} — run ${run.id.slice(0, 8)} (${run.status})\n`));

    // 1. Run summary + progress
    const progress = daemon && run.progress
      ? JSON.parse(run.progress) as Record<string, unknown>
      : store.getRunProgress(run.id);
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

    // 4. Bead info from br
    try {
      const beadInfo = execFileSync("br", ["show", beadId], {
        encoding: "utf-8",
        cwd: projectPath,
      });
      if (beadInfo) reports["BEAD_INFO"] = beadInfo;
    } catch { /* non-fatal */ }

    // 5. Agent worker log
    const logContent = findLogFile(run.id);

    // 6. Branch name (from bead id convention: foreman/<beadId>)
    const branchName = `foreman/${beadId}`;

    // 7. Fresh test output (run it now unless pre-captured or raw mode)
    let testOutput = opts.output ?? "";
    if (!testOutput && !opts.raw && reason === "test-failed") {
      console.log(chalk.dim("  Running npm test to capture fresh output..."));
      testOutput = runCommandSafe(["npm", "test"], projectPath);
    }

    // 8. Blocked beads
    const blockedBeads = runCommandSafe(
      ["br", "list", "--status=blocked", "--limit", "0"],
      projectPath,
    );

    // 9. Recent git log (last 20 commits on dev/main)
    const recentGitLog = runCommandSafe(
      ["git", "log", "--oneline", "-20", "dev"],
      projectPath,
    ).trim() || runCommandSafe(
      ["git", "log", "--oneline", "-20", "main"],
      projectPath,
    );

    store.close();

    // Print artifact summary
    console.log(chalk.dim(`  Messages:    ${allMessages.length}`));
    console.log(chalk.dim(`  Reports:     ${Object.keys(reports).join(", ") || "(none)"}`));
    console.log(chalk.dim(`  Log:         ${logContent ? "found" : "not found"}`));
    console.log(chalk.dim(`  Test output: ${testOutput ? `${testOutput.split("\n").length} lines` : "(none)"}`));
    console.log(chalk.dim(`  Blocked:     ${blockedBeads.split("\n").filter(Boolean).length} beads`));
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
      if (testOutput) {
        console.log(chalk.bold("\n─── Test Output (last 100 lines) ───"));
        console.log(testOutput.split("\n").slice(-100).join("\n"));
      }
      console.log(chalk.bold("\n─── Blocked Beads ───"));
      console.log(blockedBeads || "(none)");
      console.log(chalk.bold("\n─── Recent Git Log ───"));
      console.log(recentGitLog || "(none)");
      return;
    }

    // Build the recovery prompt and send to AI
    const prompt = buildRecoveryPrompt({
      beadId,
      reason,
      branchName,
      runId: run.id,
      projectRoot: projectPath,
      runSummary,
      testOutput,
      blockedBeads,
      recentGitLog,
      reports,
      logContent,
    });

    const model = opts.model ?? getHighspeedModel();
    console.log(chalk.yellow(`Sending to ${model} for autonomous recovery...\n`));

    const result = await runWithPiSdk({
      prompt,
      systemPrompt: [
        "You are an autonomous recovery agent for Foreman, an AI pipeline orchestrator.",
        "You have full write access and should diagnose and fix the reported failure.",
        "Make code fixes, run tests, commit, and push when appropriate.",
        "Be decisive — when you identify a fix, apply it. Do not just describe what to do.",
        "Use markdown formatting for your final summary.",
      ].join(" "),
      cwd: projectPath,
      model,
      allowedTools: ["Read", "Write", "Edit", "Bash", "Grep", "Find", "LS"],
      onText: (text) => process.stdout.write(text),
    });

    if (!result.success) {
      console.error(chalk.red(`\nRecovery agent failed: ${result.errorMessage}`));
      process.exit(1);
    }

    // Print result if not already streamed
    if (result.outputText && !result.outputText.includes("\n")) {
      console.log(result.outputText);
    }

    console.log(chalk.green(`\n\nRecovery complete ($${result.costUsd.toFixed(4)})\n`));
  });
