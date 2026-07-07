/**
 * `foreman recover <task-id>` — Autonomous recovery agent for pipeline failures.
 *
 * Gathers all artifacts for a task's pipeline execution (logs, mail messages,
 * reports, run progress, test output, blocked tasks, git log) and invokes an
 * Opus agent to diagnose and autonomously fix common failure modes:
 *
 *   test-failed   — post-merge npm test failures (stale cache, bad expectations, bugs)
 *   stuck         — agent pipeline that stopped responding
 *   stale-blocked — tasks blocked by already-closed dependencies
 *
 * Unlike `foreman debug`, this command is NOT read-only — the agent has write
 * access and will make fixes, commit, and push when appropriate.
 *
 * Note: `<task-id>` is the primary identifier. `--task` is accepted as a
 * backward-compatible alias.
 */

import { Command } from "commander";
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { execFileSync } from "node:child_process";
import chalk from "chalk";
import { ForemanStore } from "../../lib/store.js";
import type { Run, Message } from "../../lib/store.js";
import { createTrpcClient } from "../../lib/trpc-client.js";
import { foremanBackendMode } from "../../lib/backend-mode.js";
import { ElixirServerClient, type ElixirInboxMessage, type ElixirRun } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { runWithPiSdk } from "../../orchestrator/pi-sdk-runner.js";
import { loadAndInterpolate } from "../../orchestrator/template-loader.js";
import { getHighspeedModel } from "../../lib/config.js";
import { listRegisteredProjects, resolveRepoRootProjectPath } from "./project-task-support.js";

interface DaemonRunRow {
  id: string;
  project_id: string;
  task_id: string;
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

interface ElixirRecoverContext {
  client: ElixirServerClient;
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
    task_id: row.task_id,
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

async function resolveElixirRecoverContext(projectPath: string): Promise<ElixirRecoverContext | null> {
  const projects = await listRegisteredProjects();
  const project = projects.find((record) => record.path === projectPath);
  if (!project) return null;
  const manager = new ElixirServerManager();
  const status = await manager.ensureRunning();
  return {
    client: new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN),
    projectId: project.id,
  };
}

function adaptElixirRun(row: ElixirRun): Run {
  const runId = String(row.run_id ?? row.id ?? "");
  const statusMap: Record<string, Run["status"]> = {
    pending: "pending",
    in_progress: "running",
    running: "running",
    completed: "completed",
    failed: "failed",
    blocked: "conflict",
    reset: "reset",
    merged: "merged",
    "pr-created": "pr-created",
    conflict: "conflict",
    "test-failed": "test-failed",
  };
  return {
    id: runId,
    project_id: String(row.project_id ?? ""),
    task_id: String(row.task_id ?? ""),
    agent_type: "elixir",
    session_key: null,
    worktree_path: typeof row.worktree_path === "string" ? row.worktree_path : null,
    status: statusMap[String(row.status ?? "failed")] ?? "failed",
    started_at: typeof row.started_at === "string" ? row.started_at : null,
    completed_at: typeof row.completed_at === "string" ? row.completed_at : null,
    created_at: typeof row.created_at === "string" ? row.created_at : new Date(0).toISOString(),
    progress: null,
    base_branch: typeof row.base_branch === "string" ? row.base_branch : null,
    merge_strategy: null,
  };
}

function adaptElixirMessage(row: ElixirInboxMessage): Message {
  return {
    id: String(row.message_id ?? row.id ?? row.run_id ?? "message"),
    run_id: String(row.run_id ?? ""),
    sender_agent_type: typeof row.sender_agent_type === "string" ? row.sender_agent_type : "foreman",
    recipient_agent_type: typeof row.recipient_agent_type === "string" ? row.recipient_agent_type : "operator",
    subject: typeof row.subject === "string" ? row.subject : String(row.type ?? row.event_type ?? "message"),
    body: typeof row.body === "string" ? row.body : JSON.stringify(row),
    read: row.unread === false ? 1 : 0,
    created_at: typeof row.created_at === "string" ? row.created_at : new Date(0).toISOString(),
    deleted_at: null,
  };
}

// ── Types ────────────────────────────────────────────────────────────────────

type RecoveryReason = "test-failed" | "stuck" | "stale-blocked" | "finalize-conflict";
type RecommendedRecovery = "clean-replay-from-main";

interface CleanReplayWorkspace {
  taskId: string;
  branchName: string;
  workspacePath: string;
  baseBranch: string;
}

interface CleanReplayApplyResult {
  copiedFiles: string[];
  skippedFiles: string[];
}

interface CleanReplayValidationStep {
  name: string;
  success: boolean;
  output: string;
}

interface CleanReplayValidationResult {
  success: boolean;
  steps: CleanReplayValidationStep[];
}

interface CleanReplayCommitResult {
  success: boolean;
  message: string;
}

interface CleanReplayPushResult {
  success: boolean;
  branchName: string;
}

function resolveRecoveryReason(requestedReason: RecoveryReason, recommendedRecovery: RecommendedRecovery | null, reasonWasExplicit: boolean): RecoveryReason {
  if (!reasonWasExplicit && requestedReason === "test-failed" && recommendedRecovery === "clean-replay-from-main") {
    return "finalize-conflict";
  }
  return requestedReason;
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
    `Task: ${run.task_id}`,
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

function runValidationStep(name: string, args: string[], cwd: string): CleanReplayValidationStep {
  try {
    const output = execFileSync(args[0], args.slice(1), {
      encoding: "utf-8",
      cwd,
      timeout: 120_000,
    });
    return { name, success: true, output: output || "(no output)" };
  } catch (err) {
    const output = err instanceof Error && "stdout" in err
      ? ((err as NodeJS.ErrnoException & { stdout: string }).stdout ?? "(no output)")
      : `(command failed: ${err instanceof Error ? err.message : String(err)})`;
    return { name, success: false, output };
  }
}

export function extractRecommendedRecovery(reports: Record<string, string>): RecommendedRecovery | null {
  const finalizeReport = reports["FINALIZE_REPORT.md"];
  if (!finalizeReport) return null;
  if (/Recommended recovery:\s*clean replay from current main/i.test(finalizeReport)) {
    return "clean-replay-from-main";
  }
  return null;
}

function formatRecoveryRecommendation(recommendedRecovery: RecommendedRecovery | null): string {
  if (recommendedRecovery === "clean-replay-from-main") {
    return [
      "Recommended recovery: clean-replay-from-main",
      "- Meaning: rebuild the branch from current main and replay only the intended source changes",
      "- Use when finalize failed due to deterministic rebase/diverged-history conflicts",
    ].join("\n");
  }
  return "(none)";
}

const CLEAN_REPLAY_EXCLUDED_PATHS = [
  /^TEST_RESULTS\.md$/,
  /^ACTIVITY_LOG\.json$/,
  /^SESSION_LOG\.md$/,
  /^RUN_LOG\.md$/,
  /^FINALIZE_REPORT\.md$/,
  /^EXPLORER_REPORT\.md$/,
  /^DEVELOPER_REPORT\.md$/,
  /^QA_REPORT\.md$/,
  /^REVIEW\.md$/,
  /^BLOCKED\.md$/,
  /^TASK\.md$/,
  /^\.tasks\//,
  /^docs\/reports\//,
];

function normalizeReplayPath(filePath: string): string {
  return filePath.replaceAll("\\", "/").replace(/^\.\//, "");
}

function isExcludedFromCleanReplay(filePath: string): boolean {
  const normalized = normalizeReplayPath(filePath);
  return CLEAN_REPLAY_EXCLUDED_PATHS.some((pattern) => pattern.test(normalized));
}

export function parseChangedFiles(statusOutput: string): string[] {
  return statusOutput
    .split("\n")
    .map((line) => line.trimEnd())
    .filter(Boolean)
    .map((line) => {
      const payload = line.slice(3).trim();
      if (payload.includes(" -> ")) {
        return payload.split(" -> ").at(-1) ?? payload;
      }
      return payload;
    })
    .map(normalizeReplayPath)
    .filter(Boolean);
}

export function applyCleanReplayChanges(sourceWorktreePath: string, destinationWorkspacePath: string, statusOutput: string): CleanReplayApplyResult {
  const copiedFiles: string[] = [];
  const skippedFiles: string[] = [];

  for (const relativePath of parseChangedFiles(statusOutput)) {
    if (isExcludedFromCleanReplay(relativePath)) {
      skippedFiles.push(relativePath);
      continue;
    }

    const sourcePath = join(sourceWorktreePath, relativePath);
    const destinationPath = join(destinationWorkspacePath, relativePath);
    if (!existsSync(sourcePath)) {
      skippedFiles.push(relativePath);
      continue;
    }

    mkdirSync(dirname(destinationPath), { recursive: true });
    copyFileSync(sourcePath, destinationPath);
    copiedFiles.push(relativePath);
  }

  return { copiedFiles, skippedFiles };
}

export function validateCleanReplayWorkspace(workspacePath: string): CleanReplayValidationResult {
  const steps = [
    runValidationStep("tsc", ["npx", "tsc", "--noEmit"], workspacePath),
    runValidationStep("build", ["npm", "run", "build"], workspacePath),
  ];
  return {
    success: steps.every((step) => step.success),
    steps,
  };
}

async function commitCleanReplayWorkspace(projectPath: string, workspace: CleanReplayWorkspace, taskId: string): Promise<CleanReplayCommitResult> {
  const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
  const message = `fix: replay ${taskId} cleanly from current ${workspace.baseBranch}`;
  await vcs.stageAll(workspace.workspacePath);
  await vcs.commit(workspace.workspacePath, message);
  return { success: true, message };
}

async function pushCleanReplayWorkspace(projectPath: string, workspace: CleanReplayWorkspace): Promise<CleanReplayPushResult> {
  const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
  await vcs.push(workspace.workspacePath, workspace.branchName);
  return { success: true, branchName: workspace.branchName };
}

async function prepareCleanReplayWorkspace(projectPath: string, taskId: string): Promise<CleanReplayWorkspace> {
  const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
  const baseBranch = await vcs.detectDefaultBranch(projectPath);
  const replayTaskId = `${taskId}-clean-replay`;
  const { workspacePath, branchName } = await vcs.createWorkspace(projectPath, replayTaskId, baseBranch);
  return {
    taskId: replayTaskId,
    branchName,
    workspacePath,
    baseBranch,
  };
}

// ── Prompt builder ──────────────────────────────────────────────────────────

function buildRecoveryPrompt(opts: {
  taskId: string;
  reason: RecoveryReason;
  branchName: string;
  runId: string;
  projectRoot: string;
  runSummary: string;
  testOutput: string;
  blockedTasks: string;
  recentGitLog: string;
  reports: Record<string, string>;
  logContent: string | null;
  recoveryRecommendation: string;
}): string {
  const reportSections = Object.entries(opts.reports)
    .map(([name, content]) => `### ${name}\n\`\`\`\n${content.slice(0, 5000)}\n\`\`\``)
    .join("\n\n");

  const logSection = opts.logContent
    ? `## Agent Worker Log (last 200 lines)\n\`\`\`\n${opts.logContent.split("\n").slice(-200).join("\n")}\n\`\`\``
    : "## Agent Worker Log\n(not found)";

  return loadAndInterpolate("recover.md", {
    taskId: opts.taskId,
    reason: opts.reason,
    branchName: opts.branchName,
    runId: opts.runId,
    projectRoot: opts.projectRoot,
    runSummary: opts.runSummary,
    recoveryRecommendation: opts.recoveryRecommendation,
    testOutput: opts.testOutput || "(not captured)",
    blockedTasks: opts.blockedTasks || "(none)",
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
  .argument("<task-id>", "The task ID that needs recovery (alias: task-id for backward compatibility)")
  .option(
    "--reason <reason>",
    "Failure reason: test-failed | stuck | stale-blocked | finalize-conflict",
  )
  .option("--run-id <id>", "Specific run ID (default: latest run for this task)")
  .option("--output <text>", "Pre-captured test output to include in context")
  .option("--model <model>", "Model to use for recovery")
  .option("--raw", "Print collected context without invoking AI")
  .option("--prepare-clean-replay", "Create a fresh clean-replay workspace from the detected default branch")
  .option("--apply-clean-replay", "Copy intended changed files from the failed worktree into the clean replay workspace")
  .option("--validate-clean-replay", "Run typecheck and build in the clean replay workspace")
  .option("--commit-clean-replay", "Stage and commit the clean replay workspace after successful validation")
  .option("--push-clean-replay", "Push the validated clean replay branch after commit")
  .option("--execute-clean-replay", "Run the full clean replay flow: apply, validate, commit, and push")
  .action(async (taskId: string, opts: {
    reason?: string;
    runId?: string;
    output?: string;
    model?: string;
    raw?: boolean;
    prepareCleanReplay?: boolean;
    applyCleanReplay?: boolean;
    validateCleanReplay?: boolean;
    commitCleanReplay?: boolean;
    pushCleanReplay?: boolean;
    executeCleanReplay?: boolean;
  }) => {
    const requestedReason = (opts.reason ?? "test-failed") as RecoveryReason;
    const validReasons: RecoveryReason[] = ["test-failed", "stuck", "stale-blocked", "finalize-conflict"];
    const executeCleanReplay = opts.executeCleanReplay ?? false;
    const prepareCleanReplay = executeCleanReplay || (opts.prepareCleanReplay ?? false);
    const applyCleanReplay = executeCleanReplay || (opts.applyCleanReplay ?? false);
    const validateCleanReplay = executeCleanReplay || (opts.validateCleanReplay ?? false);
    const commitCleanReplay = executeCleanReplay || (opts.commitCleanReplay ?? false);
    const pushCleanReplay = executeCleanReplay || (opts.pushCleanReplay ?? false);
    if (!validReasons.includes(requestedReason)) {
      console.error(chalk.red(`Invalid reason "${requestedReason}". Must be one of: ${validReasons.join(", ")}`));
      process.exit(1);
    }

    const projectPath = await resolveRepoRootProjectPath({});
    const isElixir = foremanBackendMode() === "elixir";
    const elixir = isElixir ? await resolveElixirRecoverContext(projectPath) : null;
    if (isElixir && !elixir) {
      throw new Error(`Project at '${projectPath}' is not registered in Elixir projections.`);
    }
    const daemon = isElixir ? null : await resolveDaemonRecoverContext(projectPath);
    const store = ForemanStore.forProject(projectPath);

    // Find runs for this task
    const runs = elixir
      ? ((await elixir.client.listRuns({ projectId: elixir.projectId })).filter((row) => row.task_id === taskId).map(adaptElixirRun))
      : daemon
        ? ((await daemon.client.runs.list({ projectId: daemon.projectId, taskId, limit: 50 }) as DaemonRunRow[]).map(adaptDaemonRun))
        : store.getRunsForTask(taskId);
    if (runs.length === 0) {
      console.error(chalk.red(`No runs found for task ${taskId}`));
      process.exit(1);
    }

    // Select the target run
    const run = opts.runId
      ? runs.find((r) => r.id === opts.runId || r.id.startsWith(opts.runId!))
      : runs[0]; // latest

    if (!run) {
      console.error(chalk.red(`Run ${opts.runId} not found for task ${taskId}`));
      console.error(`Available runs: ${runs.map((r) => `${r.id.slice(0, 8)} (${r.status})`).join(", ")}`);
      process.exit(1);
    }

    // 1. Run summary + progress
    const progress = daemon && run.progress
      ? JSON.parse(run.progress) as Record<string, unknown>
      : elixir
        ? null
        : store.getRunProgress(run.id);
    const runSummary = formatRunSummary(run, progress as Record<string, unknown> | null);

    // 2. Mail messages
    const allMessages = elixir
      ? (await elixir.client.listInbox({ projectId: elixir.projectId, runId: run.id, limit: 100 })).map(adaptElixirMessage)
      : daemon
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

    const recommendedRecovery = extractRecommendedRecovery(reports);
    const recoveryRecommendation = formatRecoveryRecommendation(recommendedRecovery);
    const reasonWasExplicit = opts.reason !== undefined;
    const reason = resolveRecoveryReason(requestedReason, recommendedRecovery, reasonWasExplicit);

    if (reason !== requestedReason) {
      console.log(chalk.dim(`  Auto-selected recovery reason: ${reason} (from finalize recommendation)`));
    }
    console.log(chalk.bold(`\nRecovery: ${taskId} — reason: ${reason} — run ${run.id.slice(0, 8)} (${run.status})\n`));

    // 4. Task info from native task store
    try {
      const taskInfo = execFileSync("native task store", ["show", taskId], {
        encoding: "utf-8",
        cwd: projectPath,
      });
      if (taskInfo) reports["TASK_INFO"] = taskInfo;
    } catch { /* non-fatal */ }

    // 5. Agent worker log
    const logContent = findLogFile(run.id);

    // 6. Branch name (from task id convention: foreman/<taskId>)
    const branchName = `foreman/${taskId}`;

    // 7. Fresh test output (run it now unless pre-captured or raw mode)
    let testOutput = opts.output ?? "";
    if (!testOutput && !opts.raw && reason === "test-failed") {
      console.log(chalk.dim("  Running npm test to capture fresh output..."));
      testOutput = runCommandSafe(["npm", "test"], projectPath);
    }

    // 8. Blocked tasks
    const blockedTasks = runCommandSafe(
      ["native task store", "list", "--status=blocked", "--limit", "0"],
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

    let cleanReplayWorkspace: CleanReplayWorkspace | null = null;
    let cleanReplayApplyResult: CleanReplayApplyResult | null = null;
    let cleanReplayValidationResult: CleanReplayValidationResult | null = null;
    let cleanReplayCommitResult: CleanReplayCommitResult | null = null;
    let cleanReplayPushResult: CleanReplayPushResult | null = null;
    if (prepareCleanReplay || applyCleanReplay || validateCleanReplay || commitCleanReplay || pushCleanReplay) {
      if (reason !== "finalize-conflict") {
        store.close();
        console.error(chalk.red("--prepare-clean-replay/--apply-clean-replay requires finalize-conflict recovery context"));
        process.exit(1);
      }
      cleanReplayWorkspace = await prepareCleanReplayWorkspace(projectPath, taskId);
      if (applyCleanReplay) {
        if (!worktreePath) {
          store.close();
          console.error(chalk.red("Cannot apply clean replay without a source worktree path"));
          process.exit(1);
        }
        const statusOutput = runCommandSafe(["git", "status", "--short"], worktreePath);
        cleanReplayApplyResult = applyCleanReplayChanges(worktreePath, cleanReplayWorkspace.workspacePath, statusOutput);
      }
      if (validateCleanReplay || commitCleanReplay || pushCleanReplay) {
        cleanReplayValidationResult = validateCleanReplayWorkspace(cleanReplayWorkspace.workspacePath);
      }
      if (commitCleanReplay || pushCleanReplay) {
        if (!cleanReplayValidationResult?.success) {
          store.close();
          console.error(chalk.red("--commit-clean-replay/--push-clean-replay requires successful clean replay validation"));
          process.exit(1);
        }
        cleanReplayCommitResult = await commitCleanReplayWorkspace(projectPath, cleanReplayWorkspace, taskId);
      }
      if (pushCleanReplay) {
        cleanReplayPushResult = await pushCleanReplayWorkspace(projectPath, cleanReplayWorkspace);
      }
    }

    store.close();

    // Print artifact summary
    console.log(chalk.dim(`  Messages:    ${allMessages.length}`));
    console.log(chalk.dim(`  Reports:     ${Object.keys(reports).join(", ") || "(none)"}`));
    console.log(chalk.dim(`  Log:         ${logContent ? "found" : "not found"}`));
    console.log(chalk.dim(`  Test output: ${testOutput ? `${testOutput.split("\n").length} lines` : "(none)"}`));
    console.log(chalk.dim(`  Blocked:     ${blockedTasks.split("\n").filter(Boolean).length} tasks`));
    if (cleanReplayWorkspace) {
      console.log(chalk.dim(`  Clean replay: ${cleanReplayWorkspace.branchName} @ ${cleanReplayWorkspace.workspacePath}`));
    }
    if (cleanReplayApplyResult) {
      console.log(chalk.dim(`  Clean replay copied: ${cleanReplayApplyResult.copiedFiles.length} file(s)`));
    }
    if (cleanReplayValidationResult) {
      console.log(chalk.dim(`  Clean replay validation: ${cleanReplayValidationResult.success ? "passed" : "failed"}`));
    }
    if (cleanReplayCommitResult) {
      console.log(chalk.dim(`  Clean replay commit: ${cleanReplayCommitResult.message}`));
    }
    if (cleanReplayPushResult) {
      console.log(chalk.dim(`  Clean replay push: ${cleanReplayPushResult.branchName}`));
    }
    console.log();

    if (opts.raw) {
      console.log(chalk.bold("─── Run Summary ───"));
      console.log(runSummary);
      console.log(chalk.bold("\n─── Recommended Recovery ───"));
      console.log(recoveryRecommendation);
      if (cleanReplayWorkspace) {
        console.log(chalk.bold("\n─── Clean Replay Workspace ───"));
        console.log(`Task: ${cleanReplayWorkspace.taskId}`);
        console.log(`Base: ${cleanReplayWorkspace.baseBranch}`);
        console.log(`Branch: ${cleanReplayWorkspace.branchName}`);
        console.log(`Path: ${cleanReplayWorkspace.workspacePath}`);
      }
      if (cleanReplayApplyResult) {
        console.log(chalk.bold("\n─── Clean Replay Applied Files ───"));
        console.log(cleanReplayApplyResult.copiedFiles.join("\n") || "(none)");
        console.log(chalk.bold("\n─── Clean Replay Skipped Files ───"));
        console.log(cleanReplayApplyResult.skippedFiles.join("\n") || "(none)");
      }
      if (cleanReplayValidationResult) {
        console.log(chalk.bold("\n─── Clean Replay Validation ───"));
        console.log(`Overall: ${cleanReplayValidationResult.success ? "PASS" : "FAIL"}`);
        for (const step of cleanReplayValidationResult.steps) {
          console.log(`- ${step.name}: ${step.success ? "PASS" : "FAIL"}`);
        }
      }
      if (cleanReplayCommitResult) {
        console.log(chalk.bold("\n─── Clean Replay Commit ───"));
        console.log(`Status: PASS`);
        console.log(`Message: ${cleanReplayCommitResult.message}`);
      }
      if (cleanReplayPushResult) {
        console.log(chalk.bold("\n─── Clean Replay Push ───"));
        console.log(`Status: PASS`);
        console.log(`Branch: ${cleanReplayPushResult.branchName}`);
      }
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
      console.log(chalk.bold("\n─── Blocked Tasks ───"));
      console.log(blockedTasks || "(none)");
      console.log(chalk.bold("\n─── Recent Git Log ───"));
      console.log(recentGitLog || "(none)");
      return;
    }

    // Build the recovery prompt and send to AI
    const prompt = buildRecoveryPrompt({
      taskId,
      reason,
      branchName,
      runId: run.id,
      projectRoot: projectPath,
      runSummary,
      testOutput,
      blockedTasks,
      recentGitLog,
      reports,
      logContent,
      recoveryRecommendation,
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
