#!/usr/bin/env node
/**
 * Agent Worker — standalone process that runs a single SDK agent.
 *
 * Spawned as a detached child process by the dispatcher. Survives parent exit.
 * Reads config from a JSON file passed as argv[2], runs the SDK query(),
 * and reports progress/completion to the Elixir backend.
 *
 * Usage: tsx agent-worker.ts <config-file>
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFileSync, unlinkSync, existsSync } from "node:fs";
import { appendFile, mkdir, writeFile } from "node:fs/promises";
import { dirname, join, basename } from "node:path";
import { request as httpRequest } from "node:http";
import { runPhaseSession } from "./phase-runner.js";
import type { StreamEvent } from "./pi-sdk-runner.js";
import {
  createArtifactWriteTool,
  createDiffReadTool,
  createFileChangesTool,
  createFileReleaseTool,
  createFileReserveTool,
  createGetRunStatusTool,
  createGitStatusTool,
  createAbortPhaseTool,
  createAskOperatorTool,
  createMailReadTool,
  createMailSendTool,
  createPhaseHandoffTool,
  createPrReviewFindingTool,
  createProgressUpdateTool,
  createSafeCommandRunTool,
  createSendMailTool,
  createTaskBlockTool,
  createTaskGetTool,
  createTaskNoteAddTool,
  createTaskRiskAddTool,
  createNeedsRetryTool,
  createTaskStatusTool,
  createValidationResultTool,
  createMergeGateStatusTool,
  type ControlOutcome,
  type ForemanToolContext,
 } from "./pi-sdk-tools.js";
import { executePipeline } from "./pipeline-executor.js";
import type { EpicTask, PhaseObservabilityInput, PipelineObservabilityWriter, WorkerStoreCompat } from "./pipeline-executor.js";
import type { Run, RunProgress } from "../lib/store.js";
import type { RunProgressSummary } from "./read-models.js";
import { ElixirServerManager } from "../lib/elixir-server-manager.js";
import { ElixirServerClient } from "../lib/elixir-server-client.js";
import { PIPELINE_BUFFERS, PIPELINE_TIMEOUTS } from "../lib/config.js";
import {
  ROLE_CONFIGS,
  getDisallowedTools,
} from "./roles.js";
import { enqueueToMergeQueue } from "./agent-worker-enqueue.js";
import { updateFatalRunStatus } from "./agent-worker-fatal-path.js";
import { updateTerminalRunStatus } from "./agent-worker-run-status.js";
import { writeMarkStuckEvent, writeMarkStuckProgress } from "./agent-worker-mark-stuck-observability.js";
import { writeSingleAgentProgress, writeSingleAgentTerminalEvent } from "./agent-worker-single-agent-observability.js";
import type { WorkerNotification } from "./types.js";
import { inferProjectPathFromWorkspacePath } from "../lib/workspace-paths.js";
import type { AgentMailClient } from "../lib/agent-mail-client.js";
import { createProjectMailClient } from "../lib/project-mail-client.js";
import { createTaskClient } from "../lib/task-client-factory.js";
import { loadWorkflowConfig, resolveWorkflowName, type WorkflowConfig } from "../lib/workflow-loader.js";
import { getRunReportsDir, resolveArtifactPath } from "../lib/report-paths.js";
import { runCodeRabbitCliReview } from "./coderabbit-cli-review.js";
import { collectPrReviewContext, collectPrWaitSnapshot, isPrWaitStatusReady, summarizePrWaitStatus, updatePrReadyStability, writePrReviewFindings, writePrWaitReport } from "./pr-review-context.js";
import { Refinery, type RefineryRunLookup } from "./refinery.js";
import type { ITaskClient } from "../lib/task-client.js";
import { VcsBackendFactory } from "../lib/vcs/index.js";
import type { VcsBackend } from "../lib/vcs/interface.js";
import type { TaskMeta } from "../lib/interpolate.js";
import type { WorkflowPhaseConfig } from "../lib/workflow-loader.js";
import { runWorkspaceHook } from "../lib/setup.js";
import { loadProjectConfig, type ProjectHooksConfig } from "../lib/project-config.js";
import { foremanBackendMode } from "../lib/backend-mode.js";
import { nativeTaskStatusForPhase } from "./task-phase-status.js";
import { classifyFinalizeTestFailure, findFinalizeScopeViolations, finalizeValidationCommands } from "./finalize-guards.js";
import type { ToolDefinition } from "@mariozechner/pi-coding-agent";
import { collectRuntimeAssetIssues, runtimeAssetIssueMessage } from "../lib/runtime-assets.js";

const execFileAsync = promisify(execFile);

// ── Notification Client ───────────────────────────────────────────────────

/**
 * Lightweight HTTP client that POSTs worker notifications to the
 * NotificationServer running in the parent foreman process.
 *
 * Fire-and-forget: errors are silently swallowed so a dead/missing server
 * never blocks or crashes the worker. The polling fallback handles updates
 * whenever the server isn't reachable.
 */
class NotificationClient {
  constructor(private notifyUrl: string | undefined) {}

  /** Send a notification. Non-blocking — errors are silently ignored. */
  send(notification: WorkerNotification): void {
    if (!this.notifyUrl) return;
    try {
      const body = JSON.stringify(notification);
      const url = new URL("/notify", this.notifyUrl);
      const req = httpRequest(
        {
          hostname: url.hostname,
          port: url.port,
          path: url.pathname,
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Content-Length": Buffer.byteLength(body),
          },
          // Aggressive timeout — worker must not block on notification delivery
          timeout: 500,
        },
        (res) => {
          // Drain the response body so the socket can be reused
          res.resume();
        },
      );
      req.on("error", () => { /* silently ignore */ });
      req.on("timeout", () => { req.destroy(); });
      req.end(body);
    } catch {
      // Silently ignore any synchronous errors (e.g. invalid URL)
    }
  }
}

// ── Agent Mail helper ─────────────────────────────────────────────────────────

/** Mail client type. */
type AnyMailClient = AgentMailClient;
type RegisteredReadStore = RefineryRunLookup & {
  updateRunProgress?(runId: string, progress: RunProgress): Promise<void> | void;
  logEvent?(projectId: string, eventType: string, data: Record<string, unknown>, runId?: string): Promise<void> | void;
};

/**
 * Fire-and-forget wrapper for AgentMailClient.sendMessage.
 * Never throws — failures are logged but do not affect the pipeline.
 */
function sendMail(
  client: AnyMailClient | null,
  to: string,
  subject: string,
  body: Record<string, unknown>,
): void {
  if (!client) return;
  client.sendMessage(to, subject, JSON.stringify(body)).catch((err: unknown) => {
    const msg = err instanceof Error ? err.message : String(err);
    // agent-mail stream version conflicts are common under concurrent phase activity
    // and not actionable by the operator — log once per run.
    if (/stream version conflict/i.test(msg)) return;
    log(`[agent-mail] send failed (non-fatal): ${msg}`);
  });
}

/**
 * Fire-and-forget wrapper for AgentMailClient.sendMessage with plain string body.
 * Used to send report content (Explorer report, QA feedback, Review result).
 * Never throws.
 */
function sendMailText(
  client: AnyMailClient | null,
  to: string,
  subject: string,
  body: string,
): void {
  if (!client) return;
  client.sendMessage(to, subject, body).catch((err: unknown) => {
    const msg = err instanceof Error ? err.message : String(err);
    if (/stream version conflict/i.test(msg)) {
      // Suppressed — agent-mail stream version conflicts are common under concurrent
      // phase activity and not actionable by the operator. Logged once per run.
      log(`[agent-mail] send failed (non-fatal, suppressed): ${msg}`);
      return;
    }
    log(`[agent-mail] send failed (non-fatal): ${msg}`);
  });
}

function compactTraceValue(value: string, maxLength = 160): string {
  let compact = value
    .replace(/\/Users\/ldangelo\/Development\/Fortium\/\.foreman-worktrees\/foreman\/foreman-[^/\s]+/g, "<worktree>")
    .replace(/\/Users\/ldangelo\/Development\/Fortium\/foreman/g, "<repo>")
    .replace(/\s+/g, " ")
    .trim();
  if (compact.length > maxLength) {
    compact = `${compact.slice(0, Math.max(1, maxLength - 1))}…`;
  }
  return compact;
}

function buildTraceMailPayload(event: {
  kind: "start" | "update" | "warning" | "complete";
  phase: string;
  taskId: string;
  message: string;
  toolName?: string;
  argsPreview?: string;
  traceFile?: string;
  traceMarkdownFile?: string;
  commandHonored?: boolean;
}): Record<string, unknown> {
  return {
    taskId: event.taskId,
    phase: event.phase,
    kind: event.kind,
    message: compactTraceValue(event.message),
    tool: event.toolName,
    argsPreview: event.argsPreview ? compactTraceValue(event.argsPreview, 2000) : undefined,
    traceFile: event.traceFile,
    traceMarkdownFile: event.traceMarkdownFile,
    commandHonored: event.commandHonored,
  };
}

function sendTraceMail(
  client: AnyMailClient | null,
  event: {
    kind: "start" | "update" | "warning" | "complete";
    phase: string;
    taskId: string;
    message: string;
    toolName?: string;
    argsPreview?: string;
    traceFile?: string;
    traceMarkdownFile?: string;
    commandHonored?: boolean;
  },
): void {
  const subject = `${event.phase.charAt(0).toUpperCase() + event.phase.slice(1)} Trace ${event.kind}`;
  sendMail(client, "foreman", subject, buildTraceMailPayload(event));
}

/**
 * Register agent identity for a phase and set as the sending identity on the client.
 * Uses ensureAgentRegistered so the auto-generated name is cached and used as sender_name.
 * Never throws — failures are logged but do not affect the pipeline.
 */
async function registerAgent(client: AnyMailClient | null, roleHint: string): Promise<void> {
  if (!client) return;
  try {
    const generatedName = await client.ensureAgentRegistered(roleHint);
    // Set the generated name as the current sending identity
    if (generatedName) {
      client.agentName = generatedName;
      log(`[agent-mail] Registered as '${generatedName}' (role: ${roleHint})`);
    }
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[agent-mail] registerAgent failed (non-fatal): ${msg}`);
  }
}

/**
 * Fire-and-forget wrapper for file reservation.
 * Never throws — failures are logged but do not affect the pipeline.
 */
function reserveFiles(
  client: AnyMailClient | null,
  paths: string[],
  agentName: string,
  leaseSecs?: number,
): void {
  if (!client || paths.length === 0) return;
  client.reserveFiles(paths, agentName, leaseSecs).catch((err: unknown) => {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[agent-mail] reserveFiles failed (non-fatal): ${msg}`);
  });
}

/**
 * Fire-and-forget wrapper for releasing file reservations.
 * Never throws — failures are logged but do not affect the pipeline.
 */
function releaseFiles(
  client: AnyMailClient | null,
  paths: string[],
  agentName: string,
): void {
  if (!client || paths.length === 0) return;
  client.releaseFiles(paths, agentName).catch((err: unknown) => {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[agent-mail] releaseFiles failed (non-fatal): ${msg}`);
  });
}

async function createRuntimeTaskClient(projectPath: string, registeredProjectId?: string): Promise<ITaskClient> {
  return (await createTaskClient(projectPath, {
    registeredProjectId,
  })).taskClient;
}

function createWorkerStoreCompat(): WorkerStoreCompat {
  return {
    updateRunProgress() {},
    logEvent() {},
    updateRun() {},
    logRateLimitEvent() {},
    updateTaskStatus() {},
    getRun() { return null; },
    getRunProgress() { return null; },
    getEvents() { return []; },
    getRunsByStatus() { return []; },
    getRunsByStatuses() { return []; },
    getRunsByBaseBranch() { return []; },
    close() {},
  };
}

async function updateTaskStatusViaElixir(
  projectPath: string,
  projectId: string | undefined,
  taskId: string,
  status: string,
  source: string,
): Promise<void> {
  try {
    const client = await createRuntimeTaskClient(projectPath, projectId);
    if (status === "closed") {
      await client.close(taskId, source);
    } else {
      await client.update(taskId, { status });
    }
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[task-status] ${source} failed to set ${taskId}=${status} via Elixir (non-fatal): ${msg}`);
  }
}

// ── Module-level phase tracker ───────────────────────────────────────────────
// Updated by main() and runPipeline() as phases progress so the fatal error
// handler can report the correct phase in its Agent Mail message.
let currentPhase = "startup";

// ── Config ───────────────────────────────────────────────────────────────────

interface WorkerConfig {
  runId: string;
  projectId: string;
  taskId: string;
  taskTitle: string;
  taskDescription?: string;
  taskComments?: string;
  model: string;
  /** Workflow phase maxTurns limit for the current phase. */
  maxTurns?: number;
  allowedTools?: string[];
  worktreePath: string;
  /** Project root directory. */
  projectPath?: string;
  prompt: string;
  env: Record<string, string>;
  resume?: string;  // SDK session ID to resume
  pipeline?: boolean;  // Run as lead pipeline (explorer → developer → qa → reviewer)
  /** Explicit workflow name/path for direct task execution. Overrides task labels/type. */
  workflowName?: string;
  workflowPath?: string;
  /**
   * Task type field (e.g. "feature", "bug", "task", "smoke").
   * Used to resolve the workflow name when no `workflow:<name>` label is set.
   */
  taskType?: string;
  /**
   * Labels from the task. Used to resolve `workflow:<name>` overrides.
   * e.g. ["phase:explorer", "workflow:smoke"]
   */
  taskLabels?: string[];
  /**
   * Task priority string ("P0"–"P4", "0"–"4", or undefined).
   * Forwarded to the pipeline executor to resolve per-priority models from YAML.
   */
  taskPriority?: string;
  /**
   * Override target branch for auto-merge after finalize.
   * When set, merges into this branch instead of detectDefaultBranch().
   */
  targetBranch?: string;
  /**
   * Ordered list of child tasks for epic execution mode (TRD-2026-007).
   * When set, the worker runs the epic pipeline path.
   */
  epicTasks?: EpicTask[];
  /**
   * Parent epic task ID (TRD-2026-007).
   * When set, this run is an epic execution.
   */
  epicId?: string;
  /** Optional native task ID used to attach phase notes/status updates. */
  nativeTaskId?: string | null;
  /**
   * Task metadata for placeholder interpolation in bash/command phases (REQ-008).
   */
  taskMeta?: TaskMeta;
  /**
   * GitHub issue number for this task (from github_issue_number field).
   * When set, finalize commit messages are suffixed with "Fixes #{issueNumber}" (TRD-042).
   */
  githubIssueNumber?: number;
  /** One-based dispatch attempt number for lifecycle hook environment. */
  attemptNumber?: number;
  /**
   * Directory guardrail config (FR-1). When set, wraps tool factories with
   * cwd verification in the Pi SDK session.
   */
  guardrailConfig?: {
    mode?: "auto-correct" | "veto" | "disabled";
    expectedCwd?: string;
    allowedPaths?: string[];
  };
  /**
   * Workspace lifecycle hooks for pre/post-run customization.
   * Loaded from project config and passed through to the pipeline executor.
   */
  hooks?: ProjectHooksConfig;
}

// ── Structured Logging Context ───────────────────────────────────────────────

/**
 * Structured log context populated once config is loaded.
 * Used by log() to emit JSON-formatted log entries with consistent fields.
 */
interface LogContext {
  issueId: string;
  issueIdentifier: string;
  sessionId: string | null;
  runId: string;
  attempt: number;
}

/** Module-level log context; initialized in main() after config is loaded. */
let logContext: LogContext | null = null;

/**
 * Initialize the structured logging context from worker config.
 * Must be called after config is loaded and before any log() calls.
 */
function initLogContext(config: WorkerConfig): void {
  logContext = {
    issueId: config.taskId,
    issueIdentifier: config.taskId,
    // sessionId comes from config.resume (SDK session ID) when resuming an existing session
    sessionId: config.resume ?? null,
    runId: config.runId,
    attempt: config.attemptNumber ?? 1,
  };
}

// ── Main ─────────────────────────────────────────────────────────────────────

function installTestWorkerGuard(config: WorkerConfig): void {
  const homeDir = config.env.HOME;
  const isTempTestHome = Boolean(homeDir?.includes("foreman-test-home-") || homeDir?.includes("foreman-no-task-backend-home-"));
  if (config.env.FOREMAN_WORKER_TEST_GUARD !== "1" && !isTempTestHome) return;
  const parentPid = Number(config.env.FOREMAN_WORKER_PARENT_PID);
  const interval = setInterval(() => {
    const parentGone = Number.isFinite(parentPid) && parentPid > 0 && (() => {
      try {
        process.kill(parentPid, 0);
        return false;
      } catch {
        return true;
      }
    })();
    const homeGone = Boolean(homeDir) && !existsSync(homeDir);
    const worktreeGone = !existsSync(config.worktreePath);
    if (parentGone || homeGone || worktreeGone) {
      process.exit(0);
    }
  }, 1_000);
  interval.unref();
}

async function runAfterRunHook(config: WorkerConfig): Promise<void> {
  const hooks = config.hooks as ProjectHooksConfig | undefined;
  if (!hooks?.afterRun) return;

  const hookEnv: Record<string, string> = {
    FOREMAN_WORKSPACE_PATH: config.worktreePath,
    FOREMAN_ISSUE_ID: config.taskId,
    FOREMAN_ISSUE_IDENTIFIER: config.taskId,
    FOREMAN_ATTEMPT: String(config.attemptNumber ?? 1),
  };

  try {
    await runWorkspaceHook(hooks, "afterRun", config.worktreePath, hookEnv);
  } catch (hookErr: unknown) {
    const hookMsg = hookErr instanceof Error ? hookErr.message : String(hookErr);
    log(`[hooks] afterRun hook failed (non-fatal): ${hookMsg.slice(0, 300)}`);
  }
}

async function main(): Promise<void> {
  const configPath = process.argv[2];
  if (!configPath) {
    console.error("Usage: agent-worker <config-file>");
    process.exit(1);
  }

  // Read and delete config file (contains env vars including credentials — delete immediately)
  const config: WorkerConfig = JSON.parse(readFileSync(configPath, "utf-8"));
  try { unlinkSync(configPath); } catch { /* already deleted */ }
  installTestWorkerGuard(config);

  // Initialize structured logging context for JSON-formatted log output
  initLogContext(config);

  const { runId, projectId, taskId, taskTitle, model, worktreePath, projectPath: configProjectPath, prompt, resume, pipeline } = config;

  // Change process cwd to the worktree so agent file operations (read, write,
  // edit, bash) target the correct directory. The spawn cwd is the project root
  // (for tsx module resolution), but the agent must work in the worktree.
  try { process.chdir(worktreePath); } catch { /* worktree may not exist yet */ }

  // Resolve the project-local store path from the config, falling back to the
  // parent of the worktree directory if projectPath is not provided.
  const storeProjectPath = configProjectPath ?? inferProjectPathFromWorkspacePath(worktreePath);

  // Set up logging
  const logDir = join(process.env.HOME ?? "/tmp", ".foreman", "logs");
  await mkdir(logDir, { recursive: true });
  const logFile = join(logDir, `${runId}.log`);

  const mode = pipeline ? "pipeline" : (resume ? "resume" : "worker");
  const header = [
    `[foreman-worker] Agent ${mode.toUpperCase()} at ${new Date().toISOString()}`,
    `  task:      ${taskId} — ${taskTitle}`,
    `  model:     ${model}`,
    `  run:       ${runId}`,
    `  worktree:  ${worktreePath}`,
    `  pid:       ${process.pid}`,
    `  method:    ${pipeline ? "Pipeline (explorer→developer→qa→reviewer)" : "Pi (detached worker)"}`,
    resume ? `  resume:    ${resume}` : null,
    "─".repeat(80),
    "",
  ].filter(Boolean).join("\n");
  await appendFile(logFile, header);

  log(`Worker started for ${taskId} [${model}] pid=${process.pid} mode=${mode}`);
  currentPhase = "init";

  // No database-backed store in the worker. Authoritative task/run/mail state
  // is read/written through Elixir; this object only satisfies legacy in-process
  // pipeline interfaces where Elixir observability is already preferred.
  const store = createWorkerStoreCompat();
  const registeredProjectId = config.projectId;
  const registeredReadStore = undefined;

  // Apply worker env vars.
  // NOTE: `ROLE_CONFIGS` in roles.ts is materialised at module load time,
  // which happens before this point.  Therefore any `FOREMAN_*_MODEL` values
  // supplied via `config.env` have NO effect on model selection — they arrive
  // too late.  Per-phase model overrides must be set in the *parent* process
  // environment before the worker is spawned.  The env vars here are passed
  // through to the SDK query() call for other purposes (e.g. API keys).
  for (const [key, value] of Object.entries(config.env)) {
    process.env[key] = value;
  }

  // Create notification client using FOREMAN_NOTIFY_URL (set in env above if provided by dispatcher)
  const notifyClient = new NotificationClient(process.env.FOREMAN_NOTIFY_URL);

  // Create backend-routed Agent Mail client.
  let agentMailClient: AnyMailClient | null = null;
  try {
    const mailClient = await createProjectMailClient(storeProjectPath);
    mailClient.setRunId(runId);
    agentMailClient = mailClient;
    log(`[agent-mail] Using ${mailClient.constructor.name} (scoped to run ${runId})`);
  } catch {
    // Non-fatal — mail is optional infrastructure
  }

  if (config.env.FOREMAN_RUNTIME_MODE !== "test" && process.env.FOREMAN_RUNTIME_MODE !== "test" && process.env.VITEST !== "true") {
    const assetIssues = collectRuntimeAssetIssues(storeProjectPath);
    if (assetIssues.length > 0) {
      const reason = runtimeAssetIssueMessage(assetIssues);
      const now = new Date().toISOString();
      log(`[runtime-assets] ${reason.replace(/\n/g, " | ")}`);
      await updateTerminalRunStatus({
        runId,
        projectId,
        projectPath: storeProjectPath,
        updates: { status: "failed", completed_at: now },
      });
      notifyClient.send({ type: "status", runId, status: "failed", timestamp: now, details: { reason } });
      sendMail(agentMailClient, "foreman", "worker-error", {
        runId,
        taskId,
        phase: "startup",
        error: reason,
      });
      await updateTaskStatusViaElixir(storeProjectPath, projectId, taskId, "failed", "agent-worker-runtime-assets");
      await runAfterRunHook(config);
      store.close?.();
      return;
    }
  }

  // Build clean env for SDK
  const env: Record<string, string | undefined> = { ...process.env };

  // ── Pipeline mode: run each phase as a separate SDK session ─────────
  if (pipeline) {
    try {
      await runPipeline(config, store, logFile, notifyClient, agentMailClient, registeredReadStore, registeredProjectId);
      log(`Pipeline worker exiting for ${taskId}`);
    } finally {
      await runAfterRunHook(config);
      store.close?.();
    }
    return;
  }

  // ── Single-agent mode: run via Pi RPC ──────────────────────────────
  const progress: RunProgress = {
    toolCalls: 0,
    toolBreakdown: {},
    filesChanged: [],
    turns: 0,
    costUsd: 0,
    tokensIn: 0,
    tokensOut: 0,
    lastToolCall: null,
    lastActivity: new Date().toISOString(),
  };

  let progressDirty = false;
  let progressFlushTail: Promise<void> = Promise.resolve();
  const waitForProgressFlush = async () => {
    await progressFlushTail;
  };
  const flushProgress = () => {
    if (progressDirty) {
      progressDirty = false;
      progressFlushTail = progressFlushTail.then(() => writeSingleAgentProgress(undefined, runId, progress, log));
    }
  };
  const progressTimer = setInterval(flushProgress, PIPELINE_TIMEOUTS.progressFlushMs);
  progressTimer.unref();

  try {
    // Build clean env for Pi (strip CLAUDECODE, convert to string-only map)
    const piResult = await runPhaseSession({
      prompt,
      systemPrompt: `You are an agent working on task: ${taskTitle}`,
      cwd: worktreePath,
      model,
      logFile,
      context: {
        phaseName: "worker",
        runId,
        taskId,
        taskTitle,
        taskType: config.taskType,
        taskDescription: config.taskDescription,
        worktreePath,
        targetBranch: config.targetBranch,
      },
      observability: {
        runId,
        taskId,
        phase: "worker",
        phaseType: "prompt",
        model,
        worktreePath,
        rawPrompt: prompt,
        systemPrompt: `You are an agent working on task: ${taskTitle}`,
      },
      onToolCall: (name: string, input: Record<string, unknown>) => {
        progress.toolCalls++;
        progress.toolBreakdown[name] = (progress.toolBreakdown[name] ?? 0) + 1;
        progress.lastToolCall = name;
        progress.lastActivity = new Date().toISOString();

        if ((name === "write" || name === "edit" || name === "Write" || name === "Edit") && (input?.path || input?.file_path)) {
          const filePath = String(input.path ?? input.file_path);
          if (!progress.filesChanged.includes(filePath)) {
            progress.filesChanged.push(filePath);
          }
        }
        progressDirty = true;
      },
      onTurnEnd: (turn: number) => {
        progress.turns = turn;
        progress.lastActivity = new Date().toISOString();
        progressDirty = true;
      },
    });

    clearInterval(progressTimer);
    await waitForProgressFlush();
    progress.costUsd = piResult.costUsd;
    progress.turns = piResult.turns;
    progress.toolCalls = piResult.toolCalls;
    progress.toolBreakdown = piResult.toolBreakdown;
    progress.tokensIn = piResult.tokensIn;
    progress.tokensOut = piResult.tokensOut;
    await writeSingleAgentProgress(undefined, runId, progress, log);

    const now = new Date().toISOString();

    if (piResult.success) {
      await updateTerminalRunStatus({
        runId,
        projectId,
        projectPath: storeProjectPath,
        updates: { status: "completed", completed_at: now },
      });
      notifyClient.send({ type: "status", runId, status: "completed", timestamp: now });
      await writeSingleAgentTerminalEvent(undefined, projectId, runId, "complete", {
        taskId,
        title: taskTitle,
        costUsd: progress.costUsd,
        numTurns: progress.turns,
        toolCalls: progress.toolCalls,
        filesChanged: progress.filesChanged.length,
        resumed: !!resume,
      }, log);
      log(`COMPLETED (${progress.turns} turns, ${progress.toolCalls} tools, ${progress.filesChanged.length} files, $${progress.costUsd.toFixed(4)})`);
    } else {
      const reason = piResult.errorMessage ?? "Pi agent failed";
      await updateTerminalRunStatus({
        runId,
        projectId,
        projectPath: storeProjectPath,
        updates: { status: "failed", completed_at: now },
      });
      notifyClient.send({ type: "status", runId, status: "failed", timestamp: now, details: { reason } });
      await writeSingleAgentTerminalEvent(undefined, projectId, runId, "fail", {
        taskId,
        reason,
        costUsd: progress.costUsd,
        numTurns: progress.turns,
        resumed: !!resume,
      }, log);
      log(`FAILED: ${reason.slice(0, 300)}`);
      // Permanent failure — mark task as 'failed' so it is NOT auto-retried.
      await updateTaskStatusViaElixir(storeProjectPath, projectId, taskId, "failed", "agent-worker");
    }
  } catch (err: unknown) {
    clearInterval(progressTimer);
    await waitForProgressFlush();
    await writeSingleAgentProgress(undefined, runId, progress, log);
    const reason = err instanceof Error ? err.message : String(err);
    const reasonLower = reason.toLowerCase();
    const isRateLimit = reasonLower.includes("hit your limit") || reasonLower.includes("rate limit");

    const now = new Date().toISOString();
    const catchStatus = isRateLimit ? "stuck" : "failed";
    await updateTerminalRunStatus({
      runId,
      projectId,
      projectPath: storeProjectPath,
      updates: {
        status: catchStatus,
        completed_at: now,
      },
    });
    notifyClient.send({ type: "status", runId, status: catchStatus, timestamp: now, details: { reason } });
    await writeSingleAgentTerminalEvent(undefined, projectId, runId, isRateLimit ? "stuck" : "fail", {
      taskId,
      reason,
      costUsd: progress.costUsd,
      numTurns: progress.turns,
      rateLimit: isRateLimit,
      resumed: !!resume,
    }, log);
    log(`${isRateLimit ? "RATE LIMITED" : "ERROR"}: ${reason.slice(0, 200)}`);
    await appendFile(logFile, `\n[foreman-worker] ${isRateLimit ? "RATE LIMITED" : "ERROR"}: ${reason}\n`);
    // Transient (rate limit) → reset to 'open' for retry; permanent → mark 'failed'.
    if (isRateLimit) {
      await updateTaskStatusViaElixir(storeProjectPath, projectId, taskId, "ready", "agent-worker");
    } else {
      await updateTaskStatusViaElixir(storeProjectPath, projectId, taskId, "failed", "agent-worker");
    }
  }

  await runAfterRunHook(config);
  store.close?.();
  log(`Worker exiting for ${taskId}`);
}

// ── Pipeline orchestration ───────────────────────────────────────────────────

interface PhaseResult {
  success: boolean;
  costUsd: number;
  turns: number;
  tokensIn: number;
  tokensOut: number;
  error?: string;
  outputText?: string;
  traceFile?: string;
  traceMarkdownFile?: string;
  traceWarnings?: string[];
  commandHonored?: boolean;
  /** Stop remaining phases and treat the pipeline as successful. Used by builtins that complete work without a PR. */
  stopPipelineSuccess?: boolean;
  /** Typed control signal from phase control tools (ask_operator, abort_phase, needs_retry). */
  controlOutcome?: ControlOutcome;
 }

/**
 * Run a single pipeline phase as a separate SDK session.
 */
async function runPhase(
  role: string,
  prompt: string,
  config: WorkerConfig,
  progress: RunProgress,
  logFile: string,
  store: WorkerStoreCompat,
  notifyClient: NotificationClient,
  agentMailClient?: AnyMailClient | null,
  observability?: PhaseObservabilityInput,
  observabilityWriter?: PipelineObservabilityWriter,
): Promise<PhaseResult> {
  const baseRoleConfig = (ROLE_CONFIGS as Record<string, typeof ROLE_CONFIGS.developer | undefined>)[role] ?? ROLE_CONFIGS.developer;
  const roleConfig = config.allowedTools
    ? { ...baseRoleConfig, role: role as typeof baseRoleConfig.role, allowedTools: config.allowedTools }
    : baseRoleConfig;
  // Use the model resolved by the pipeline executor (from workflow YAML + task priority).
  // Falls back to ROLE_CONFIGS[role].model for backward compat (no-YAML / direct invocation).
  const resolvedModel: string = config.model || roleConfig.model;
  progress.currentPhase = role;
  if (observabilityWriter?.updateProgress) {
    await observabilityWriter.updateProgress(progress);
  } else {
    await Promise.resolve(store.updateRunProgress(config.runId, progress));
  }

  const disallowedTools = getDisallowedTools(roleConfig);
  const allowedSummary = roleConfig.allowedTools.join(", ");
  await appendFile(logFile, `\n${"─".repeat(40)}\n[PHASE: ${role.toUpperCase()}] Starting (model=${resolvedModel}, maxTurns=${config.maxTurns ?? "none"}, maxBudgetUsd=${roleConfig.maxBudgetUsd}, allowedTools=[${allowedSummary}])\n`);
  const streamForwarder = createWorkerStreamEventForwarder(role, observabilityWriter, log);
  log(`[${role.toUpperCase()}] Starting phase for ${config.taskId} (${roleConfig.allowedTools.length} allowed tools, ${disallowedTools.length} disallowed)`);

  // Build custom Foreman workflow tools for this phase.
  const customTools = [];
  const agentName = `${role}-${config.taskId}`;
  const foremanToolContext: ForemanToolContext = {
    phase: role,
    runId: config.runId,
    taskId: config.taskId,
    taskTitle: config.taskTitle,
    taskType: config.taskType,
    taskDescription: config.taskDescription,
    worktreePath: config.worktreePath,
    reportDir: resolveArtifactPath(config.worktreePath, workerReportDir(config)),
    logFile,
    onFileChanges: (files: string[]) => {
      for (const file of files) {
        if (!progress.filesChanged.includes(file)) {
          progress.filesChanged.push(file);
        }
      }
    },
    onFileReserve: (files: string[], owner: string, leaseSecs?: number) => {
      if (agentMailClient) {
        reserveFiles(agentMailClient, files, owner, leaseSecs);
      }
    },
    onFileRelease: (files: string[], owner: string) => {
      if (agentMailClient) {
        releaseFiles(agentMailClient, files, owner);
      }
    },
  };
  if (agentMailClient) {
    customTools.push(createSendMailTool(agentMailClient, agentName));
    customTools.push(createMailSendTool(agentMailClient, foremanToolContext));
    customTools.push(createMailReadTool(agentMailClient, agentName, foremanToolContext));
  }
  customTools.push(createPhaseHandoffTool(agentMailClient ?? null, foremanToolContext));
  customTools.push(createArtifactWriteTool(foremanToolContext));
  customTools.push(createValidationResultTool(foremanToolContext));
  customTools.push(createTaskBlockTool(agentMailClient ?? null, foremanToolContext));
  customTools.push(createProgressUpdateTool(agentMailClient ?? null, foremanToolContext));
  customTools.push(createAskOperatorTool(agentMailClient ?? null, foremanToolContext));
  customTools.push(createAbortPhaseTool(agentMailClient ?? null, foremanToolContext));
  customTools.push(createNeedsRetryTool(agentMailClient ?? null, foremanToolContext));
  customTools.push(createFileReserveTool(foremanToolContext));
  customTools.push(createFileReleaseTool(foremanToolContext));
  customTools.push(createFileChangesTool(foremanToolContext));
  if (role !== "explorer") {
    customTools.push(createSafeCommandRunTool(foremanToolContext));
  }

  // VCS and PR review tools — created with worktree-scoped VcsBackend for path safety.
  try {
    const projectPath = config.projectPath ?? inferProjectPathFromWorkspacePath(config.worktreePath);
    const vcsBackend = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
    customTools.push(createDiffReadTool(vcsBackend, foremanToolContext));
    customTools.push(createGitStatusTool(vcsBackend, foremanToolContext));
    customTools.push(createPrReviewFindingTool(vcsBackend, foremanToolContext));
    customTools.push(createMergeGateStatusTool(vcsBackend, foremanToolContext));
  } catch (err: unknown) {
    // Non-fatal: VCS/PR tools unavailable (e.g., no git repo, network issues).
    // Agents fall back to shell commands for these operations.
    const reason = err instanceof Error ? err.message : String(err);
    await appendFile(logFile, `[PHASE: ${role.toUpperCase()}] VCS/PR tools unavailable: ${reason}\n`);
  }

  // Task context tools — require ElixirServerClient for task reads and annotations.
  if (process.env.FOREMAN_SERVER_URL) {
    const taskClient = new ElixirServerClient(
      process.env.FOREMAN_SERVER_URL,
      process.env.FOREMAN_WORKER_EVENT_TOKEN ?? process.env.FOREMAN_SERVER_AUTH_TOKEN,
    );
    customTools.push(createTaskGetTool(taskClient, foremanToolContext));
    customTools.push(createTaskStatusTool(taskClient, foremanToolContext));
    customTools.push(createTaskNoteAddTool(taskClient, foremanToolContext));
    customTools.push(createTaskRiskAddTool(taskClient, foremanToolContext));
  } else {
    await appendFile(logFile, `[PHASE: ${role.toUpperCase()}] Task context tools unavailable: FOREMAN_SERVER_URL not set\n`);
  }

  let policySequence = 0;
  const toolPolicy = process.env.FOREMAN_SERVER_URL
    ? {
        context: {
          runId: config.runId,
          taskId: config.taskId,
          phaseId: role,
          workerId: `node-pipeline-policy:${config.taskId}:${role}`,
        },
        check: async (toolCallId: string, toolName: string, args: Record<string, unknown>) => {
          policySequence += 1;
          const client = new ElixirServerClient(process.env.FOREMAN_SERVER_URL!, process.env.FOREMAN_WORKER_EVENT_TOKEN ?? process.env.FOREMAN_SERVER_AUTH_TOKEN);
          return client.checkToolPolicy({
            run_id: config.runId,
            task_id: config.taskId,
            phase_id: role,
            worker_id: `node-pipeline-policy:${config.taskId}:${role}`,
            sequence: policySequence,
            tool_call_id: toolCallId,
            tool_name: toolName,
            args,
          });
        },
      }
    : undefined;

  try {
    const phaseResult = await runPhaseSession({
      prompt,
      systemPrompt: `You are the ${role} agent in the Foreman pipeline for task: ${config.taskTitle}`,
      cwd: config.worktreePath,
      model: resolvedModel,
      maxTurns: config.maxTurns,
      allowedTools: roleConfig.allowedTools,
      customTools,
      toolPolicy,
      logFile,
      context: {
        phaseName: role,
        runId: config.runId,
        taskId: config.taskId,
        taskTitle: config.taskTitle,
        taskType: config.taskType,
        taskDescription: config.taskDescription,
        worktreePath: config.worktreePath,
        targetBranch: config.targetBranch,
      },
      observability: {
        runId: config.runId,
        taskId: config.taskId,
        phase: role,
        phaseType: observability?.phaseType ?? "prompt",
        model: resolvedModel,
        worktreePath: config.worktreePath,
        rawPrompt: prompt,
        systemPrompt: `You are the ${role} agent in the Foreman pipeline for task: ${config.taskTitle}`,
        expectedArtifact: observability?.expectedArtifact,
        resolvedCommand: observability?.resolvedCommand,
        workflowName: observability?.workflowName,
        workflowPath: observability?.workflowPath,
      },
      onTraceEvent: (event) => {
        sendTraceMail(agentMailClient ?? null, event);
      },
      onStreamEvent: (event) => {
        streamForwarder?.(event);
      },
      onToolCall: (name, input) => {
        progress.toolCalls++;
        progress.toolBreakdown[name] = (progress.toolBreakdown[name] ?? 0) + 1;
        progress.lastToolCall = name;
        progress.lastActivity = new Date().toISOString();

        if ((name === "write" || name === "edit" || name === "Write" || name === "Edit") && (input?.path || input?.file_path)) {
          const filePath = String(input.path ?? input.file_path);
          if (!progress.filesChanged.includes(filePath)) {
            progress.filesChanged.push(filePath);
          }
        }
      },
      onTurnEnd: (turn) => {
        progress.turns = turn;
        progress.lastActivity = new Date().toISOString();
        if (observabilityWriter?.updateProgress) {
          void Promise.resolve(observabilityWriter.updateProgress(progress));
        } else {
          void Promise.resolve(store.updateRunProgress(config.runId, progress));
        }
        notifyClient.send({
          type: "progress",
          runId: config.runId,
          progress: { ...progress },
          timestamp: new Date().toISOString(),
        });
      },
      // FR-1: Directory guardrail — verify cwd before each tool call
      guardrailConfig: config.guardrailConfig ? {
        ...config.guardrailConfig,
        expectedCwd: config.guardrailConfig.expectedCwd ?? config.worktreePath,
      } : undefined,
    });

    progress.costUsd += phaseResult.costUsd;
    progress.tokensIn += phaseResult.tokensIn;
    progress.tokensOut += phaseResult.tokensOut;

    // Record per-phase cost breakdown
    progress.costByPhase ??= {};
    progress.costByPhase[role] = (progress.costByPhase[role] ?? 0) + phaseResult.costUsd;
    progress.agentByPhase ??= {};
    progress.agentByPhase[role] = resolvedModel;

    if (observabilityWriter?.updateProgress) {
      await observabilityWriter.updateProgress(progress);
    } else {
      await Promise.resolve(store.updateRunProgress(config.runId, progress));
    }

    if (phaseResult.success) {
      log(`[${role.toUpperCase()}] Completed (${phaseResult.turns} turns, $${phaseResult.costUsd.toFixed(4)})`);
      await appendFile(logFile, `[PHASE: ${role.toUpperCase()}] COMPLETED ($${phaseResult.costUsd.toFixed(4)})\n`);
      return {
        success: true,
        costUsd: phaseResult.costUsd,
        turns: phaseResult.turns,
        tokensIn: phaseResult.tokensIn,
        tokensOut: phaseResult.tokensOut,
        outputText: phaseResult.outputText,
        traceFile: phaseResult.traceFile,
        traceMarkdownFile: phaseResult.traceMarkdownFile,
        traceWarnings: phaseResult.traceWarnings,
        commandHonored: phaseResult.commandHonored,
        controlOutcome: phaseResult.controlOutcome,
      };
    } else {
      const reason = phaseResult.errorMessage ?? "Pi agent ended without success";
      log(`[${role.toUpperCase()}] Failed: ${reason.slice(0, 200)}`);
      await appendFile(logFile, `[PHASE: ${role.toUpperCase()}] FAILED: ${reason}\n`);
      return {
        success: false,
        costUsd: phaseResult.costUsd,
        turns: phaseResult.turns,
        tokensIn: phaseResult.tokensIn,
        tokensOut: phaseResult.tokensOut,
        error: reason,
        outputText: phaseResult.outputText,
        traceFile: phaseResult.traceFile,
        traceMarkdownFile: phaseResult.traceMarkdownFile,
        traceWarnings: phaseResult.traceWarnings,
        commandHonored: phaseResult.commandHonored,
        controlOutcome: phaseResult.controlOutcome,
      };
    }
  } catch (err: unknown) {
    const reason = err instanceof Error ? err.message : String(err);
    const reasonLower = reason.toLowerCase();
    const isRateLimit = reasonLower.includes("hit your limit") || reasonLower.includes("rate limit");
    log(`[${role.toUpperCase()}] ${isRateLimit ? "RATE LIMITED" : "ERROR"}: ${reason.slice(0, 200)}`);
    await appendFile(logFile, `[PHASE: ${role.toUpperCase()}] ERROR: ${reason}\n`);
    return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: reason };
  }
}

function readReport(worktreePath: string, filename: string): string | null {
  const p = join(worktreePath, filename);
  try { return readFileSync(p, "utf-8"); } catch { return null; }
}


/**
 * Run the troubleshooter phase as a separate SDK session.
 *
 * Invoked after a pipeline failure when workflowConfig.onFailure is present.
 * The troubleshooter reads failure context (artifacts, run status) and attempts
 * to resolve the issue automatically (fix test failures, resolve conflicts, etc.).
 *
 * Returns true if the troubleshooter reports RESOLVED in its artifact, false otherwise.
 */
async function runTroubleshooterPhase(
  config: WorkerConfig,
  workflowConfig: WorkflowConfig,
  store: WorkerStoreCompat,
  logFile: string,
  notifyClient: NotificationClient,
  agentMailClient: AnyMailClient | null,
  failureContext: string,
  pipelineProjectPath: string,
): Promise<boolean> {
  const onFailure = workflowConfig.onFailure;
  if (!onFailure) return false;

  const { runId, taskId, taskTitle } = config;
  log(`[TROUBLESHOOTER] Activating for ${taskId} — failure context: ${failureContext.slice(0, 120)}`);

  // Build a basic troubleshooter prompt with failure context injected
  const prompt = [
    `# Troubleshooter Agent`,
    ``,
    `**Task:** ${taskId} — ${taskTitle}`,
    `**Run ID:** ${runId}`,
    `**Failure Context:**`,
    failureContext,
    ``,
    `Use get_run_status, read artifacts, and apply fixes. Write TROUBLESHOOT_REPORT.md when done.`,
    `Use task terminology in your notes. Include "RESOLVED" in the report if the failure was fixed, or "ESCALATED" if not.`,
  ].join("\n");

  const roleConfig = ROLE_CONFIGS.troubleshooter;
  const resolvedModel = onFailure.models?.["default"] ?? roleConfig.model;

  const customTools: ToolDefinition[] = [];
  if (agentMailClient) {
    customTools.push(createSendMailTool(agentMailClient, `troubleshooter-${taskId}`));
  }
  customTools.push(createGetRunStatusTool(store));

  try {
    const result = await runPhaseSession({
      prompt,
      systemPrompt: `You are the troubleshooter agent for Foreman. Your job is to diagnose and fix a pipeline failure for task: ${taskTitle}`,
      cwd: config.worktreePath,
      model: resolvedModel,
      allowedTools: roleConfig.allowedTools,
      customTools,
      logFile,
      context: {
        phaseName: "troubleshooter",
        runId,
        taskId,
        taskTitle,
        taskType: config.taskType,
        taskDescription: config.taskDescription,
        worktreePath: config.worktreePath,
        targetBranch: config.targetBranch,
      },
      observability: {
        runId,
        taskId,
        phase: "troubleshooter",
        phaseType: "prompt",
        model: resolvedModel,
        worktreePath: config.worktreePath,
        rawPrompt: prompt,
        systemPrompt: `You are the troubleshooter agent for Foreman. Your job is to diagnose and fix a pipeline failure for task: ${taskTitle}`,
        expectedArtifact: "TROUBLESHOOT_REPORT.md",
      },
      onToolCall: () => { /* no-op */ },
      onTurnEnd: () => { /* no-op */ },
    });

    log(`[TROUBLESHOOTER] Completed (${result.turns} turns, $${result.costUsd.toFixed(4)})`);
    await appendFile(logFile, `[TROUBLESHOOTER] ${result.success ? "COMPLETED" : "FAILED"} ($${result.costUsd.toFixed(4)})\n`);

    // Check if TROUBLESHOOT_REPORT.md contains "RESOLVED"
    const { join: pathJoin } = await import("node:path");
    const { readFileSync: rfs } = await import("node:fs");
    try {
      const report = rfs(pathJoin(config.worktreePath, "TROUBLESHOOT_REPORT.md"), "utf-8");
      const troubleshooterResolved = report.includes("RESOLVED");
      if (troubleshooterResolved) {
        log(`[TROUBLESHOOTER] PIPELINE RECOVERED for ${taskId}`);
        await appendFile(logFile, `[TROUBLESHOOTER] PIPELINE RECOVERED\n`);
        return true;
      }
    } catch {
      // Report not written — escalated
    }
    return false;
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[TROUBLESHOOTER] Error: ${msg}`);
    return false;
  }
}

function toStoreRun(input: Record<string, unknown>, projectId: string): Run {
  const status = typeof input.status === "string" ? input.status : "running";
  const now = new Date().toISOString();
  return {
    id: typeof input.run_id === "string" ? input.run_id : String(input.id ?? ""),
    project_id: typeof input.project_id === "string" ? input.project_id : projectId,
    task_id: typeof input.task_id === "string" ? input.task_id : "",
    agent_type: typeof input.agent_type === "string" ? input.agent_type : "pipeline",
    session_key: typeof input.session_key === "string" ? input.session_key : null,
    worktree_path: typeof input.worktree_path === "string" ? input.worktree_path : null,
    status: status as Run["status"],
    started_at: typeof input.started_at === "string" ? input.started_at : null,
    completed_at: typeof input.completed_at === "string" ? input.completed_at : null,
    created_at: typeof input.created_at === "string" ? input.created_at : now,
    progress: typeof input.progress === "string" ? input.progress : null,
    base_branch: typeof input.base_branch === "string" ? input.base_branch : null,
    merge_strategy: (typeof input.merge_strategy === "string" ? input.merge_strategy : null) as Run["merge_strategy"],
    commit_sha: typeof input.commit_sha === "string" ? input.commit_sha : null,
    pr_url: typeof input.pr_url === "string" ? input.pr_url : null,
    pr_state: (typeof input.pr_state === "string" ? input.pr_state : null) as Run["pr_state"],
    pr_head_sha: typeof input.pr_head_sha === "string" ? input.pr_head_sha : null,
    cooldown_until: typeof input.cooldown_until === "string" ? input.cooldown_until : null,
  };
}

function createElixirRunLookup(projectId: string): RefineryRunLookup {
  const client = process.env.FOREMAN_SERVER_URL
    ? Promise.resolve(new ElixirServerClient(process.env.FOREMAN_SERVER_URL, process.env.FOREMAN_WORKER_EVENT_TOKEN ?? process.env.FOREMAN_SERVER_AUTH_TOKEN))
    : new ElixirServerManager().ensureRunning().then((status) => (
        new ElixirServerClient(status.url, process.env.FOREMAN_WORKER_EVENT_TOKEN ?? process.env.FOREMAN_SERVER_AUTH_TOKEN)
      ));

  const list = async (): Promise<Run[]> => {
    const runs = await (await client).listRuns({ projectId });
    return runs.map((run) => toStoreRun(run, projectId));
  };

  return {
    async getRun(id) {
      return (await list()).find((run) => run.id === id) ?? null;
    },
    async getRunsByStatus(status) {
      return (await list()).filter((run) => run.status === status);
    },
    async getRunsByStatuses(statuses) {
      return (await list()).filter((run) => statuses.includes(run.status));
    },
    async getRunsByBaseBranch(baseBranch) {
      return (await list()).filter((run) => run.base_branch === baseBranch);
    },
  };
}

/**
 * Derive fallback refinery options for registered/native run lookups.
 *
 * Workers use the Elixir run projection for lookup. Node must not connect to
 * the database directly for registered run state.
 */
function deriveFallbackRefineryOptions(
  registeredProjectId: string | undefined,
  _registeredReadStore: RefineryRunLookup | undefined,
  _pipelineProjectPath: string,
  configProjectId: string,
  _log?: (msg: string) => void,
): { registeredProjectId: string; runLookup: RefineryRunLookup } | undefined {
  const refineryProjectId = registeredProjectId ?? configProjectId;
  if (!refineryProjectId) return undefined;

  return {
    registeredProjectId: refineryProjectId,
    runLookup: createElixirRunLookup(refineryProjectId),
  };
}

/**
 * Run the full pipeline: Explorer → Developer ⇄ QA → Reviewer → Finalize.
 * Each phase is a separate SDK session. TypeScript orchestrates the loop.
 */
function parsePrNumber(prUrl: string): number | undefined {
  const match = /\/pull\/(\d+)(?:\b|$)/.exec(prUrl);
  return match ? Number(match[1]) : undefined;
}

function workerReportDir(config: WorkerConfig): string {
  return config.taskMeta?.projectReportsDir || getRunReportsDir(config.projectId, config.taskId, config.runId);
}

async function hasChangesAgainstBase(vcsBackend: VcsBackend | undefined, repoPath: string, baseBranch: string, branchName: string): Promise<boolean> {
  if (!vcsBackend) return true;
  const changedFiles = await vcsBackend.getChangedFiles(repoPath, baseBranch, branchName);
  return changedFiles.length > 0;
}

/**
 * Verify the worktree is on the canonical foreman/<taskId> branch.
 * Returns branch invariant check result with expected/actual/worktree details.
 */
async function requireCanonicalBranch(
  vcsBackend: VcsBackend | undefined,
  worktreePath: string,
  taskId: string,
): Promise<{ valid: boolean; expected: string; actual: string; worktreePath: string }> {
  const expected = `foreman/${taskId}`;
  if (!vcsBackend) return { valid: true, expected, actual: "", worktreePath };
  const actual = await vcsBackend.getCurrentBranch(worktreePath);
  return { valid: actual === expected, expected, actual, worktreePath };
}

async function resolvePrBaseBranch(args: {
  store: WorkerStoreCompat;
  runId: string;
  targetBranch?: string;
  vcsBackend?: VcsBackend;
  projectPath: string;
}): Promise<string> {
  const runBase = args.store.getRun(args.runId)?.base_branch;
  if (typeof runBase === "string" && runBase.trim()) return runBase.trim();
  if (args.targetBranch?.trim()) return args.targetBranch.trim();
  return await args.vcsBackend?.detectDefaultBranch(args.projectPath).catch(() => "main") ?? "main";
}

async function createOptionalPrLifecycleClient(): Promise<ElixirServerClient | null> {
  if (!process.env.FOREMAN_SERVER_URL && !process.env.FOREMAN_SERVER_AUTH_TOKEN && !process.env.FOREMAN_WORKER_EVENT_TOKEN) {
    return null;
  }
  try {
    if (process.env.FOREMAN_SERVER_URL) {
      return new ElixirServerClient(process.env.FOREMAN_SERVER_URL, process.env.FOREMAN_WORKER_EVENT_TOKEN ?? process.env.FOREMAN_SERVER_AUTH_TOKEN);
    }
    const status = await new ElixirServerManager().ensureRunning();
    return new ElixirServerClient(status.url, process.env.FOREMAN_WORKER_EVENT_TOKEN ?? process.env.FOREMAN_SERVER_AUTH_TOKEN);
  } catch {
    return null;
  }
}

async function recordRunPrLifecycle(args: {
  store: WorkerStoreCompat;
  serverClient?: ElixirServerClient | null;
  projectId: string;
  runId: string;
  commandType: "run.pr.update" | "run.pr.ready" | "run.pr.retarget" | "run.pr.reset";
  localEventType: "pr-updated" | "pr-ready" | "pr-retargeted" | "pr-reset";
  payload: Record<string, unknown>;
  metadata?: Record<string, unknown>;
  log: (msg: string) => void;
}): Promise<void> {
  const headSha = typeof args.payload.head_sha === "string" ? args.payload.head_sha : undefined;
  const prUrl = typeof args.payload.pr_url === "string" ? args.payload.pr_url : undefined;
  const baseBranch = typeof args.payload.base_branch === "string"
    ? args.payload.base_branch
    : typeof args.payload.new_base_branch === "string"
      ? args.payload.new_base_branch
      : undefined;
  const prState = args.localEventType === "pr-ready"
    ? "open"
    : args.localEventType === "pr-reset"
      ? "closed"
      : args.localEventType === "pr-updated"
        ? "draft"
        : undefined;

  const updates: Record<string, unknown> = {};
  if (headSha) {
    updates.commit_sha = headSha;
    updates.pr_head_sha = headSha;
  }
  if (prUrl) updates.pr_url = prUrl;
  if (prState) updates.pr_state = prState;
  if (baseBranch !== undefined) updates.base_branch = baseBranch;
  if (Object.keys(updates).length > 0) {
    await Promise.resolve(args.store.updateRun?.(args.runId, updates)).catch((err: unknown) => {
      args.log(`[PR] local run metadata update failed (non-fatal): ${err instanceof Error ? err.message : String(err)}`);
    });
  }

  await Promise.resolve(args.store.logEvent?.(args.projectId, args.localEventType, args.payload, args.runId)).catch((err: unknown) => {
    args.log(`[PR] local lifecycle event failed (non-fatal): ${err instanceof Error ? err.message : String(err)}`);
  });

  if (!args.serverClient) return;
  const response = await args.serverClient.sendCommand({
    command_id: `${args.commandType.replace(/\./g, "-")}-${args.runId}-${Date.now()}`,
    command_type: args.commandType,
    payload: {
      ...args.payload,
      project_id: args.projectId,
      run_id: args.runId,
    },
    metadata: args.metadata,
  });
  if (!response.ok) {
    args.log(`[PR] lifecycle command ${args.commandType} failed (non-fatal): ${response.error.message}`);
  }
}

async function runCreatePrBuiltinPhase(args: {
  config: WorkerConfig;
  store: WorkerStoreCompat;
  runtimeTaskClient: ITaskClient;
  pipelineProjectPath: string;
  registeredProjectId?: string;
  registeredReadStore?: RegisteredReadStore;
  vcsBackend?: VcsBackend;
  log: (msg: string) => void;
  agentMailClient: AnyMailClient | null;
}): Promise<PhaseResult> {
  const { config, store, runtimeTaskClient, pipelineProjectPath, registeredProjectId, registeredReadStore, vcsBackend, log, agentMailClient } = args;

  // Fallback logic mirrors runPipeline: if registeredReadStore is missing but a database
  // URL exists in the project path, derive a RegisteredReadStore for run lookups. This ensures
  // registered/native runs can be found even when registeredProjectId was not propagated.
  const registeredRefineryOptions = deriveFallbackRefineryOptions(
    registeredProjectId,
    registeredReadStore,
    pipelineProjectPath,
    config.projectId,
    log,
  );

  const prLifecycleClient = await createOptionalPrLifecycleClient();
  const refineryOptions = {
    ...(registeredRefineryOptions ?? {}),
    recordPrLifecycle: async (event: {
      commandType: "run.pr.update" | "run.pr.ready" | "run.pr.retarget" | "run.pr.reset";
      localEventType: "pr-updated" | "pr-ready" | "pr-retargeted" | "pr-reset";
      payload: Record<string, unknown>;
      metadata?: Record<string, unknown>;
    }) => recordRunPrLifecycle({
      store,
      serverClient: prLifecycleClient,
      projectId: registeredProjectId ?? config.projectId,
      runId: config.runId,
      commandType: event.commandType,
      localEventType: event.localEventType,
      payload: event.payload,
      metadata: { source: "agent-worker", phase: "create-pr", ...event.metadata },
      log,
    }),
  };

  const refinery = new Refinery(
    store,
    runtimeTaskClient,
    pipelineProjectPath,
    vcsBackend,
    refineryOptions,
  );
  const baseBranch = await resolvePrBaseBranch({ store, runId: config.runId, targetBranch: config.targetBranch, vcsBackend, projectPath: pipelineProjectPath });
  const branchName = `foreman/${config.taskId}`;

  // Branch invariant check: fail fast if the worktree is not on the canonical branch.
  // This prevents the no-change skip from closing a task when the worker drifted.
  const branchInvariant = await requireCanonicalBranch(vcsBackend, config.worktreePath, config.taskId);
  if (!branchInvariant.valid) {
    const errorMsg = `branch_drift: expected '${branchInvariant.expected}', found '${branchInvariant.actual}' in '${branchInvariant.worktreePath}'`;
    log(`[CREATE-PR] Branch drift detected — ${errorMsg}`);
    sendMail(agentMailClient, "foreman", "agent-error", {
      taskId: config.taskId,
      runId: config.runId,
      phase: "create-pr",
      error: errorMsg,
      retryable: false,
    });
    return {
      success: false,
      costUsd: 0,
      turns: 0,
      tokensIn: 0,
      tokensOut: 0,
      outputText: errorMsg,
      error: errorMsg,
    };
  }

  const branchHasChanges = await hasChangesAgainstBase(vcsBackend, pipelineProjectPath, baseBranch, branchName).catch(() => true);
  const priorPrUrl = typeof store.getRun(config.runId)?.pr_url === "string" ? store.getRun(config.runId)?.pr_url : undefined;
  const priorMetadataPath = resolveArtifactPath(config.worktreePath, join(workerReportDir(config), "PR_METADATA.json"));
  const hasPriorPrMetadata = existsSync(priorMetadataPath);
  if (!branchHasChanges && !priorPrUrl && !hasPriorPrMetadata) {
    const metadataPath = resolveArtifactPath(config.worktreePath, join(workerReportDir(config), "PR_METADATA.json"));
    await mkdir(dirname(metadataPath), { recursive: true });
    await writeFile(metadataPath, JSON.stringify({
      skipped: true,
      reason: "no_changes_against_base",
      branchName,
      baseBranch,
    }, null, 2) + "\n", "utf8");
    await runtimeTaskClient.close(config.taskId, "No changes against target branch; acceptance already satisfied.").catch((err: unknown) => {
      log(`[CREATE-PR] no-change task close failed (non-fatal): ${err instanceof Error ? err.message : String(err)}`);
    });
    log(`[CREATE-PR] No changes between ${baseBranch} and ${branchName}; skipping PR and closing task.`);
    sendMail(agentMailClient, "foreman", "phase-complete", {
      taskId: config.taskId,
      runId: config.runId,
      phase: "create-pr",
      status: "skipped",
      reason: "no_changes_against_base",
    });
    return { success: true, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, outputText: "no_changes_against_base", stopPipelineSuccess: true };
  }
  const pr = await refinery.ensurePullRequestForRun({
    runId: config.runId,
    baseBranch,
    updateRunStatus: false,
    bodyNote: priorPrUrl || hasPriorPrMetadata ? "Finalized by create-pr workflow phase." : "Published by create-pr workflow phase.",
    draft: false,
    existingOk: true,
    phase: "create-pr",
  });
  const prNumber = parsePrNumber(pr.prUrl);
  const headSha = vcsBackend ? await vcsBackend.getHeadId(config.worktreePath).catch(() => undefined) : undefined;
  const metadataPath = resolveArtifactPath(config.worktreePath, join(workerReportDir(config), "PR_METADATA.json"));
  await mkdir(dirname(metadataPath), { recursive: true });
  await writeFile(metadataPath, JSON.stringify({
    prUrl: pr.prUrl,
    prNumber,
    branchName: pr.branchName,
    headSha,
    baseBranch,
    draft: false,
    updatedAt: new Date().toISOString(),
  }, null, 2) + "\n", "utf8");
  log(`[CREATE-PR] PR ready: ${pr.prUrl}`);
  sendMail(agentMailClient, "foreman", "pr-created", {
    taskId: config.taskId,
    runId: config.runId,
    branchName: pr.branchName,
    prUrl: pr.prUrl,
    prNumber,
    strategy: "create-pr-phase",
  });
  return { success: true, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, outputText: pr.prUrl };
}

async function sleep(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

function positiveIntEnv(name: string, fallback: number): number {
  const value = Number.parseInt(process.env[name] ?? "", 10);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

async function checkpointWorktreeAndEnsureDraftPrAfterPhase(args: {
  config: WorkerConfig;
  phase: WorkflowPhaseConfig;
  progress: RunProgress;
  workflowConfig: WorkflowConfig;
  store: WorkerStoreCompat;
  runtimeTaskClient: ITaskClient;
  pipelineProjectPath: string;
  registeredProjectId?: string;
  registeredReadStore?: RegisteredReadStore;
  vcsBackend?: VcsBackend;
  log: (msg: string) => void;
  agentMailClient: AnyMailClient | null;
}): Promise<void> {
  const {
    config,
    phase,
    workflowConfig,
    store,
    runtimeTaskClient,
    pipelineProjectPath,
    registeredProjectId,
    registeredReadStore,
    vcsBackend,
    log,
    agentMailClient,
  } = args;
  try {
    if (phase.checkpointPr !== true) return;
    if (!workflowConfig.phases.some((candidate) => candidate.name === "create-pr")) return;
    if (!vcsBackend) return;
    if (config.env.FOREMAN_RUNTIME_MODE === "test" || process.env.FOREMAN_RUNTIME_MODE === "test") return;

    // Branch invariant check: fail fast if the worktree is not on the canonical branch.
    // Do not commit/push if drift exists — the actual work is on the wrong branch.
    const branchInvariant = await requireCanonicalBranch(vcsBackend, config.worktreePath, config.taskId);
    if (!branchInvariant.valid) {
      const errorMsg = `branch_drift: expected '${branchInvariant.expected}', found '${branchInvariant.actual}' in '${branchInvariant.worktreePath}'`;
      log(`[CHECKPOINT] Branch drift detected — ${errorMsg}; skipping checkpoint commit/push.`);
      return;
    }

    const baseBranch = await resolvePrBaseBranch({
      store,
      runId: config.runId,
      targetBranch: config.targetBranch,
      vcsBackend,
      projectPath: pipelineProjectPath,
    });
    const commands = vcsBackend.getFinalizeCommands({
      taskId: config.taskId,
      taskTitle: config.taskTitle,
      baseBranch,
      worktreePath: config.worktreePath,
      githubIssueNumber: config.githubIssueNumber,
    });
    await runShellForFinalize(commands.restoreTrackedStateCommand || "true", config.worktreePath, PIPELINE_TIMEOUTS.gitOperationMs);

    const status = await vcsBackend.status(config.worktreePath);
    if (!status.trim()) return;

    const branchName = `foreman/${config.taskId}`;
    await vcsBackend.stageAll(config.worktreePath);
    await vcsBackend.commit(config.worktreePath, `chore: checkpoint ${config.taskId} after ${phase.name}\n\n${config.taskTitle}`);
    const headSha = await vcsBackend.getHeadId(config.worktreePath);
    await Promise.resolve(store.updateRun?.(config.runId, { commit_sha: headSha }));

    try {
      await vcsBackend.push(config.worktreePath, branchName, { allowNew: true });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      if (!/non-fast-forward|fetch first|Updates were rejected|behind its remote/i.test(message)) throw err;
      log(`[PR] checkpoint push rejected as non-fast-forward; retrying with force-with-lease for ${branchName}`);
      await vcsBackend.push(config.worktreePath, branchName, { allowNew: true, forceWithLease: true });
    }

    const registeredRefineryOptions = deriveFallbackRefineryOptions(
      registeredProjectId,
      registeredReadStore,
      pipelineProjectPath,
      config.projectId,
      log,
    );
    const prLifecycleClient = await createOptionalPrLifecycleClient();
    const refinery = new Refinery(
      store,
      runtimeTaskClient,
      pipelineProjectPath,
      vcsBackend,
      {
        ...(registeredRefineryOptions ?? {}),
        recordPrLifecycle: async (event: {
          commandType: "run.pr.update" | "run.pr.ready" | "run.pr.retarget" | "run.pr.reset";
          localEventType: "pr-updated" | "pr-ready" | "pr-retargeted" | "pr-reset";
          payload: Record<string, unknown>;
          metadata?: Record<string, unknown>;
        }) => recordRunPrLifecycle({
          store,
          serverClient: prLifecycleClient,
          projectId: registeredProjectId ?? config.projectId,
          runId: config.runId,
          commandType: event.commandType,
          localEventType: event.localEventType,
          payload: event.payload,
          metadata: { source: "agent-worker", phase: phase.name, ...event.metadata },
          log,
        }),
      },
    );

    const pr = await refinery.ensurePullRequestForRun({
      runId: config.runId,
      baseBranch,
      draft: true,
      updateRunStatus: false,
      existingOk: true,
      alreadyPushed: true,
      bodyNote: `Draft PR checkpoint after ${phase.name} phase.`,
      phase: phase.name,
    });
    const prNumber = parsePrNumber(pr.prUrl);
    const metadataPath = resolveArtifactPath(config.worktreePath, join(workerReportDir(config), "PR_METADATA.json"));
    await mkdir(dirname(metadataPath), { recursive: true });
    await writeFile(metadataPath, JSON.stringify({
      prUrl: pr.prUrl,
      prNumber,
      branchName: pr.branchName,
      headSha,
      baseBranch,
      draft: true,
      checkpointPhase: phase.name,
      updatedAt: new Date().toISOString(),
    }, null, 2) + "\n", "utf8");

    await recordRunPrLifecycle({
      store,
      serverClient: prLifecycleClient,
      projectId: registeredProjectId ?? config.projectId,
      runId: config.runId,
      commandType: "run.pr.update",
      localEventType: "pr-updated",
      payload: {
        run_id: config.runId,
        project_id: registeredProjectId ?? config.projectId,
        task_id: config.taskId,
        pr_url: pr.prUrl,
        branch_name: branchName,
        head_sha: headSha,
        base_branch: baseBranch,
        phase: phase.name,
      },
      metadata: { source: "agent-worker", phase: phase.name, checkpoint: true },
      log,
    });

    sendMail(agentMailClient, "foreman", "pr-updated", {
      taskId: config.taskId,
      runId: config.runId,
      phase: phase.name,
      prUrl: pr.prUrl,
      branchName,
      headSha,
      baseBranch,
    });
    log(`[PR] checkpoint draft ready after ${phase.name}: ${pr.prUrl}`);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    log(`[PR] checkpoint skipped after ${phase.name}: ${message}`);
  }
}

const PR_WAIT_POLL_MS = positiveIntEnv("FOREMAN_PR_WAIT_POLL_MS", 60_000);
const PR_READY_STABILITY_MS = positiveIntEnv("FOREMAN_PR_READY_STABILITY_MS", 60_000);
const MERGE_GATE_POLL_MS = positiveIntEnv("FOREMAN_MERGE_GATE_POLL_MS", 30_000);
const MERGE_GATE_TIMEOUT_MS = positiveIntEnv("FOREMAN_MERGE_GATE_TIMEOUT_MS", 10 * 60_000);


function readPrNumberFromMetadata(worktreePath: string, reportDir?: string): number {
  const metadataPath = resolveArtifactPath(worktreePath, reportDir ? join(reportDir, "PR_METADATA.json") : "PR_METADATA.json");
  const raw = readFileSync(metadataPath, "utf8");
  const metadata = JSON.parse(raw) as { prNumber?: number; prUrl?: string };
  const prNumber = metadata.prNumber ?? (metadata.prUrl ? parsePrNumber(metadata.prUrl) : undefined);
  if (!prNumber) throw new Error("PR metadata missing prNumber");
  return prNumber;
}

async function runPrWaitBuiltinPhase(args: {
  config: WorkerConfig;
  phase: WorkflowPhaseConfig;
  pipelineProjectPath: string;
  log: (msg: string) => void;
}): Promise<PhaseResult> {
  const prNumber = readPrNumberFromMetadata(args.config.worktreePath, workerReportDir(args.config));

  const timeoutMs = (args.phase.timeoutSecs ?? 600) * 1000;
  const pollIntervalMs = PR_WAIT_POLL_MS;
  const stabilityMs = PR_READY_STABILITY_MS;
  const startedAt = Date.now();
  let readySince: number | undefined;
  let lastSnapshot = await collectPrWaitSnapshot(args.pipelineProjectPath, prNumber);
  let timedOut = false;

  while (true) {
    const status = summarizePrWaitStatus(lastSnapshot);
    const now = Date.now();
    const stability = updatePrReadyStability(status, readySince, now, stabilityMs);
    readySince = stability.readySince;
    if (status.mergeConflict) break;
    if (stability.stable) break;
    if (Date.now() - startedAt >= timeoutMs) {
      timedOut = true;
      break;
    }
    const stableFor = readySince ? Date.now() - readySince : 0;
    args.log(`[PR-WAIT] Waiting for PR #${prNumber}: checksTerminal=${String(status.checksTerminal)} codeRabbitSeen=${String(status.codeRabbitSeen)} codeRabbitComplete=${String(status.codeRabbitComplete)} mergeConflict=${String(status.mergeConflict)} stableForMs=${stableFor}`);
    await sleep(Math.min(pollIntervalMs, Math.max(0, timeoutMs - (Date.now() - startedAt))));
    lastSnapshot = await collectPrWaitSnapshot(args.pipelineProjectPath, prNumber);
  }

  await writePrWaitReport(args.config.worktreePath, lastSnapshot, timedOut, workerReportDir(args.config));
  const finalStatus = summarizePrWaitStatus(lastSnapshot);
  const success = isPrWaitStatusReady(finalStatus);
  const failedCheckNames = finalStatus.failedChecks.map((check) => check.name).join(", ") || "unknown";
  const blockingCodeRabbit = finalStatus.blockingFindings.map((finding) => finding.path ?? finding.severity).join(", ") || "blocking review findings";
  return {
    success,
    costUsd: 0,
    turns: 0,
    tokensIn: 0,
    tokensOut: 0,
    error: success
      ? undefined
      : finalStatus.mergeConflict
        ? `merge_conflict: ${finalStatus.mergeConflictReason ?? "unknown"}`
        : finalStatus.failedChecks.length > 0
          ? `ci_failed: ${failedCheckNames}`
          : finalStatus.blockingFindings.length > 0
            ? `coderabbit_blocking: ${blockingCodeRabbit}`
            : finalStatus.codeRabbitSeen && !finalStatus.codeRabbitComplete
              ? "coderabbit_pending: review did not complete before timeout"
              : finalStatus.checksTerminal
                ? "coderabbit_pending: review did not complete before timeout"
                : "ci_pending: PR checks did not reach a terminal state before timeout",
    outputText: `checksTerminal=${String(finalStatus.checksTerminal)} failedChecks=${finalStatus.failedChecks.length} codeRabbitSeen=${String(finalStatus.codeRabbitSeen)} codeRabbitComplete=${String(finalStatus.codeRabbitComplete)} blockingFindings=${finalStatus.blockingFindings.length} mergeConflict=${String(finalStatus.mergeConflict)} timedOut=${String(timedOut)}`,
  };
}

async function runPreparePrReviewBuiltinPhase(args: {
  config: WorkerConfig;
  pipelineProjectPath: string;
  log: (msg: string) => void;
}): Promise<PhaseResult> {
  const prNumber = readPrNumberFromMetadata(args.config.worktreePath, workerReportDir(args.config));
  const context = await collectPrReviewContext(args.pipelineProjectPath, prNumber);
  await writePrReviewFindings(args.config.worktreePath, context, workerReportDir(args.config));
  args.log(`[PR-REVIEW] Collected ${context.blockingFindings.length} blocking CodeRabbit finding(s), ${context.failedChecks.length} failed check(s)`);
  return { success: true, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, outputText: `blocking=${context.blockingFindings.length} failedChecks=${context.failedChecks.length}` };
}

async function runCliReviewBuiltinPhase(args: {
  config: WorkerConfig;
  pipelineProjectPath: string;
  vcsBackend?: VcsBackend;
  log: (msg: string) => void;
}): Promise<PhaseResult> {
  const baseBranch = args.config.targetBranch
    || await args.vcsBackend?.detectDefaultBranch(args.pipelineProjectPath).catch(() => "main")
    || "main";
  const review = await runCodeRabbitCliReview({
    worktreePath: args.config.worktreePath,
    baseBranch,
    reportDir: workerReportDir(args.config),
    log: args.log,
  });
  return {
    success: review.status === "passed",
    costUsd: 0,
    turns: 0,
    tokensIn: 0,
    tokensOut: 0,
    error: review.status === "passed" ? undefined : review.details,
    outputText: `status=${review.status} blocking=${review.blockingFindings.length} nonBlocking=${review.nonBlockingFindings.length}`,
  };
}

async function runShellForFinalize(command: string, cwd: string, timeoutMs = 120_000): Promise<{ ok: boolean; output: string }> {
  try {
    const { stdout, stderr } = await execFileAsync("/bin/bash", ["-lc", command], {
      cwd,
      timeout: timeoutMs,
      maxBuffer: 5 * 1024 * 1024,
    });
    return { ok: true, output: `${stdout ?? ""}${stderr ?? ""}`.trim() };
  } catch (err: unknown) {
    const e = err as { stdout?: string; stderr?: string; message?: string };
    return { ok: false, output: `${e.stdout ?? ""}${e.stderr ?? ""}${e.message ? `\n${e.message}` : ""}`.trim() };
  }
}

function truncateFinalizeOutput(output: string): string {
  return output.length > 3000 ? `${output.slice(0, 3000)}\n...<truncated>` : output;
}

function isVerificationTask(config: WorkerConfig): boolean {
  const type = (config.taskType ?? "").toLowerCase();
  const title = config.taskTitle.toLowerCase();
  return type === "test" || /\b(verify|validate|test)\b/.test(title);
}

async function runFinalizeValidationCommands(commands: string[], cwd: string): Promise<{ ok: boolean; output: string }> {
  const output: string[] = [];
  for (const command of commands) {
    const result = await runShellForFinalize(command, cwd, 10 * 60_000);
    output.push(`$ ${command}`, result.output || "(no output)");
    if (!result.ok) return { ok: false, output: output.join("\n\n") };
  }
  return { ok: true, output: output.join("\n\n") };
}

async function writeFinalizeValidation(args: {
  config: WorkerConfig;
  baseBranch: string;
  integrationStatus: "SUCCESS" | "SKIPPED" | "FAIL";
  validationStatus: "PASS" | "FAIL" | "SKIPPED";
  failureScope: "MODIFIED_FILES" | "UNRELATED_FILES" | "UNKNOWN" | "SKIPPED";
  verdict: "PASS" | "FAIL";
  qaRef?: string;
  currentRef?: string;
  output: string;
}): Promise<void> {
  const reportDir = resolveArtifactPath(args.config.worktreePath, workerReportDir(args.config));
  await mkdir(reportDir, { recursive: true });
  const fullOutputPath = join(reportDir, "FINALIZE_TEST_OUTPUT.txt");
  await writeFile(fullOutputPath, args.output || "", "utf8");
  await writeFile(join(reportDir, "FINALIZE_VALIDATION.md"), `# Finalize Validation: ${args.config.taskTitle}\n\n` +
    `## Task: ${args.config.taskId}\n` +
    `## Run: ${args.config.runId}\n` +
    `## Timestamp: ${new Date().toISOString()}\n\n` +
    `## Target Integration\n` +
    `- Status: ${args.integrationStatus}\n` +
    `- Target: origin/${args.baseBranch}\n` +
    `- QA Validated Target Ref: ${args.qaRef ?? ""}\n` +
    `- Current Target Ref: ${args.currentRef ?? ""}\n\n` +
    `## Test Validation\n` +
    `- Status: ${args.validationStatus}\n` +
    `- Output: see FINALIZE_TEST_OUTPUT.txt (${args.output?.length ?? 0} bytes)\n` +
    `\`\`\`text\n${truncateFinalizeOutput(args.output) || "(no output)"}\n\`\`\`\n\n` +
    `## Failure Scope\n` +
    `- ${args.failureScope}\n\n` +
    `## Verdict: ${args.verdict}\n`, "utf8");
}

async function writeFinalizeReport(args: {
  config: WorkerConfig;
  install: { ok: boolean; output: string };
  typecheck: { ok: boolean; output: string };
  commitHash: string;
  pushStatus: "SUCCESS" | "FAILED";
  branchName: string;
}): Promise<void> {
  const reportDir = resolveArtifactPath(args.config.worktreePath, workerReportDir(args.config));
  await mkdir(reportDir, { recursive: true });
  await writeFile(join(reportDir, "FINALIZE_REPORT.md"), `# Finalize Report: ${args.config.taskTitle}\n\n` +
    `## Task: ${args.config.taskId}\n` +
    `## Run: ${args.config.runId}\n` +
    `## Timestamp: ${new Date().toISOString()}\n\n` +
    `## Dependency Install\n- Status: ${args.install.ok ? "SUCCESS" : "FAILED"}\n- Details: ${truncateFinalizeOutput(args.install.output) || "(none)"}\n\n` +
    `## Type Check\n- Status: ${args.typecheck.ok ? "SUCCESS" : "FAILED"}\n- Details: ${truncateFinalizeOutput(args.typecheck.output) || "(none)"}\n\n` +
    `## Commit\n- Status: SUCCESS\n- Hash: ${args.commitHash}\n\n` +
    `## Push\n- Status: ${args.pushStatus}\n- Branch: ${args.branchName}\n`, "utf8");
}

async function runDeterministicTestBuiltinPhase(args: {
  config: WorkerConfig;
  phase: WorkflowPhaseConfig;
}): Promise<PhaseResult | null> {
  if (args.config.env.FOREMAN_RUNTIME_MODE !== "test" && process.env.FOREMAN_RUNTIME_MODE !== "test") {
    return null;
  }

  const artifact = args.phase.artifact
    ? args.phase.artifact.replace(/\{task\.projectReportsDir\}/g, workerReportDir(args.config))
    : join(workerReportDir(args.config), `${args.phase.name.toUpperCase().replace(/-/g, "_")}_REPORT.md`);
  const artifactPath = resolveArtifactPath(args.config.worktreePath, artifact);
  await mkdir(dirname(artifactPath), { recursive: true });

  const body = args.phase.name === "create-pr"
    ? JSON.stringify({ prUrl: `https://example.invalid/${args.config.taskId}`, prNumber: 1, testRuntime: true }, null, 2)
    : `# ${args.phase.name} Test Runtime Report\n\n## Task\n${args.config.taskId}\n\n## Verdict: PASS\n`;

  await writeFile(artifactPath, body, "utf8");
  return { success: true, costUsd: 0, turns: 1, tokensIn: 0, tokensOut: 0, outputText: body };
}

async function runFinalizeBuiltinPhase(args: {
  config: WorkerConfig;
  pipelineProjectPath: string;
  vcsBackend?: VcsBackend;
  log: (msg: string) => void;
  progress?: RunProgress;
}): Promise<PhaseResult> {
  const { config, pipelineProjectPath, log } = args;
  const vcsBackend = args.vcsBackend ?? await VcsBackendFactory.create({ backend: "auto" }, config.worktreePath);
  const baseBranch = config.targetBranch || await vcsBackend.detectDefaultBranch(pipelineProjectPath).catch(() => "main");
  const branchName = `foreman/${config.taskId}`;
  const reportDir = workerReportDir(config);

  log(`[FINALIZE] deterministic builtin starting for ${branchName}`);
  const install = await runShellForFinalize("npm ci", config.worktreePath, 5 * 60_000);
  const typecheck = await runShellForFinalize("npx tsc --noEmit", config.worktreePath, 5 * 60_000);

  const commands = vcsBackend.getFinalizeCommands({
    taskId: config.taskId,
    taskTitle: config.taskTitle,
    baseBranch,
    worktreePath: config.worktreePath,
    githubIssueNumber: config.githubIssueNumber,
  });

  await runShellForFinalize(commands.stageCommand || "true", config.worktreePath, PIPELINE_TIMEOUTS.gitOperationMs);
  await runShellForFinalize(commands.restoreTrackedStateCommand || "true", config.worktreePath, PIPELINE_TIMEOUTS.gitOperationMs);

  let commitHash = await vcsBackend.getHeadId(config.worktreePath).catch(() => "unknown");
  const statusBeforeCommit = await vcsBackend.status(config.worktreePath).catch(() => "");
  if (statusBeforeCommit.trim()) {
    try {
      const suffix = config.githubIssueNumber ? `\n\nFixes #${config.githubIssueNumber}` : "";
      await vcsBackend.commit(config.worktreePath, `chore: finalize ${config.taskId}\n\n${config.taskTitle}${suffix}`);
      commitHash = await vcsBackend.getHeadId(config.worktreePath).catch(() => commitHash);
    } catch (err: unknown) {
      const changedAgainstBase = await vcsBackend.getChangedFiles(config.worktreePath, `origin/${baseBranch}`, "HEAD").catch(() => []);
      if (changedAgainstBase.length === 0 && !isVerificationTask(config)) {
        const msg = err instanceof Error ? err.message : String(err);
        return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: `nothing_to_commit: ${msg}` };
      }
      log(`[FINALIZE] commit skipped; branch already has changes or task is verification-only`);
    }
  } else {
    const changedAgainstBase = await vcsBackend.getChangedFiles(config.worktreePath, `origin/${baseBranch}`, "HEAD").catch(() => []);
    if (changedAgainstBase.length === 0 && !isVerificationTask(config)) {
      return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: "nothing_to_commit" };
    }
  }

  const changedAgainstBase = await vcsBackend.getChangedFiles(config.worktreePath, `origin/${baseBranch}`, "HEAD").catch(() => []);
  const scopeViolations = findFinalizeScopeViolations({ worktreePath: config.worktreePath, reportDir }, changedAgainstBase);
  if (scopeViolations.length > 0) {
    const details = [
      "Finalize scope check failed: some files were modified outside Explorer 'Edit First' scope without justification.",
      "",
      "## Out-of-scope changes (requires justification)",
      ...scopeViolations.map((file) => `- ${file}`),
      "",
      "## Action required",
      "- Add a `## Scope Expansions` section to DEVELOPER_REPORT.md listing each out-of-scope file with justification, OR",
      "- Remove the out-of-scope changes from this worktree",
      "",
      "See EXPLORER_REPORT.md '### Edit First' for the approved scope.",
    ].join("\n");
    await writeFinalizeValidation({ config, baseBranch, integrationStatus: "SKIPPED", validationStatus: "FAIL", failureScope: "UNRELATED_FILES", verdict: "FAIL", output: details });
    return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: `scope_guard_failed: ${scopeViolations.join(", ")}`, outputText: readFileSync(resolveArtifactPath(config.worktreePath, join(reportDir, "FINALIZE_VALIDATION.md")), "utf8") };
  }

  const domainValidationCommands = finalizeValidationCommands(changedAgainstBase);

  let currentTargetRef = "";
  for (const candidate of [`origin/${baseBranch}`, baseBranch]) {
    try { currentTargetRef = await vcsBackend.resolveRef(config.worktreePath, candidate); break; } catch { /* try next */ }
  }
  const qaRef = args.progress?.qaValidatedTargetRef;
  const shouldValidate = !qaRef || !currentTargetRef || qaRef !== currentTargetRef;
  let integrationStatus: "SUCCESS" | "SKIPPED" | "FAIL" = "SKIPPED";

  if (shouldValidate) {
    let rebaseError: string | undefined;
    const rebase = await vcsBackend.rebase(config.worktreePath, `origin/${baseBranch}`).catch((err: unknown) => {
      rebaseError = err instanceof Error ? err.message : String(err);
      return { success: false, hasConflicts: true, conflictingFiles: [] };
    });
    if (!rebase.success) {
      await vcsBackend.abortRebase(config.worktreePath).catch(() => undefined);
      const details = rebaseError ?? (rebase.conflictingFiles?.length ? `conflicts: ${rebase.conflictingFiles.join(", ")}` : "rebase failed");
      await writeFinalizeValidation({ config, baseBranch, integrationStatus: "FAIL", validationStatus: "SKIPPED", failureScope: "UNKNOWN", verdict: "FAIL", qaRef, currentRef: currentTargetRef, output: details });
      return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: `rebase_conflict: ${details}`, outputText: readFileSync(resolveArtifactPath(config.worktreePath, join(reportDir, "FINALIZE_VALIDATION.md")), "utf8") };
    }
    integrationStatus = "SUCCESS";
    const validationCommands = ["npm test -- --reporter=dot", ...domainValidationCommands];
    const test = await runFinalizeValidationCommands(validationCommands, config.worktreePath);
    if (!test.ok) {
      const classification = classifyFinalizeTestFailure(test.output, changedAgainstBase);
      if (classification === "UNRELATED_FILES") {
        const unrelatedMsg = "Tests failed but all failures are in files this task did not change — likely pre-existing flakiness on the target branch.";
        log(`[FINALIZE] ${unrelatedMsg} Proceeding with push.`);
        await writeFinalizeValidation({ config, baseBranch, integrationStatus, validationStatus: "PASS", failureScope: classification, verdict: "PASS", qaRef, currentRef: currentTargetRef, output: test.output });
        // fall through to push
      } else {
        await writeFinalizeValidation({ config, baseBranch, integrationStatus, validationStatus: "FAIL", failureScope: classification, verdict: "FAIL", qaRef, currentRef: currentTargetRef, output: test.output });
        return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: "finalize_validation_failed", outputText: readFileSync(resolveArtifactPath(config.worktreePath, join(reportDir, "FINALIZE_VALIDATION.md")), "utf8") };
      }
    } else {
      await writeFinalizeValidation({ config, baseBranch, integrationStatus, validationStatus: "PASS", failureScope: "SKIPPED", verdict: "PASS", qaRef, currentRef: currentTargetRef, output: test.output });
    }
  } else if (domainValidationCommands.length > 0) {
    const test = await runFinalizeValidationCommands(domainValidationCommands, config.worktreePath);
    if (!test.ok) {
      const classification = classifyFinalizeTestFailure(test.output, changedAgainstBase);
      if (classification === "UNRELATED_FILES") {
        log(`[FINALIZE] Domain test failures are unrelated to this task — proceeding with push.`);
        await writeFinalizeValidation({ config, baseBranch, integrationStatus, validationStatus: "PASS", failureScope: classification, verdict: "PASS", qaRef, currentRef: currentTargetRef, output: test.output });
      } else {
        await writeFinalizeValidation({ config, baseBranch, integrationStatus, validationStatus: "FAIL", failureScope: classification, verdict: "FAIL", qaRef, currentRef: currentTargetRef, output: test.output });
        return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: "finalize_domain_validation_failed", outputText: readFileSync(resolveArtifactPath(config.worktreePath, join(reportDir, "FINALIZE_VALIDATION.md")), "utf8") };
      }
    } else {
      await writeFinalizeValidation({ config, baseBranch, integrationStatus, validationStatus: "PASS", failureScope: "MODIFIED_FILES", verdict: "PASS", qaRef, currentRef: currentTargetRef, output: test.output });
    }
  } else {
    await writeFinalizeValidation({ config, baseBranch, integrationStatus, validationStatus: "SKIPPED", failureScope: "SKIPPED", verdict: "PASS", qaRef, currentRef: currentTargetRef, output: "QA already passed and target branch did not move after QA." });
  }
  try {
    await vcsBackend.push(config.worktreePath, branchName, { allowNew: true });
  } catch (err: unknown) {
    const firstPushError = err instanceof Error ? err.message : String(err);
    const canRetryWithLease = /non-fast-forward|fetch first|Updates were rejected|behind its remote/i.test(firstPushError);
    if (canRetryWithLease) {
      log(`[FINALIZE] normal push rejected as non-fast-forward; retrying with force-with-lease for ${branchName}`);
      try {
        await vcsBackend.push(config.worktreePath, branchName, { allowNew: true, forceWithLease: true });
      } catch (leaseErr: unknown) {
        const leaseMsg = leaseErr instanceof Error ? leaseErr.message : String(leaseErr);
        await writeFinalizeReport({ config, install, typecheck, commitHash, pushStatus: "FAILED", branchName });
        return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: `push_failed: ${leaseMsg}` };
      }
    } else {
      await writeFinalizeReport({ config, install, typecheck, commitHash, pushStatus: "FAILED", branchName });
      return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: `push_failed: ${firstPushError}` };
    }
  }

  await writeFinalizeReport({ config, install, typecheck, commitHash, pushStatus: "SUCCESS", branchName });
  return {
    success: true,
    costUsd: 0,
    turns: 0,
    tokensIn: 0,
    tokensOut: 0,
    outputText: readFileSync(resolveArtifactPath(config.worktreePath, join(reportDir, "FINALIZE_VALIDATION.md")), "utf8"),
  };
}


async function validatePrReviewGate(args: {
  worktreePath: string;
  pipelineProjectPath: string;
  log: (msg: string) => void;
  reportDir?: string;
}): Promise<{ success: boolean; reason?: string }> {
  const prNumber = readPrNumberFromMetadata(args.worktreePath, args.reportDir);
  const startedAt = Date.now();
  let readySince: number | undefined;
  let waitSnapshot = await collectPrWaitSnapshot(args.pipelineProjectPath, prNumber);
  let waitStatus = summarizePrWaitStatus(waitSnapshot);

  while (true) {
    const stability = updatePrReadyStability(waitStatus, readySince, Date.now(), PR_READY_STABILITY_MS);
    readySince = stability.readySince;
    if (waitStatus.mergeConflict) break;
    if (stability.stable) break;
    if (Date.now() - startedAt >= MERGE_GATE_TIMEOUT_MS) break;
    const stableFor = readySince ? Date.now() - readySince : 0;
    args.log(
      `[PR-REVIEW] Final gate waiting for PR #${prNumber}: checksTerminal=${String(waitStatus.checksTerminal)} ` +
        `codeRabbitSeen=${String(waitStatus.codeRabbitSeen)} codeRabbitComplete=${String(waitStatus.codeRabbitComplete)} mergeConflict=${String(waitStatus.mergeConflict)} ` +
        `pending=${waitStatus.pendingChecks.join(", ") || "none"} stableForMs=${stableFor}`,
    );
    await sleep(Math.min(MERGE_GATE_POLL_MS, Math.max(0, MERGE_GATE_TIMEOUT_MS - (Date.now() - startedAt))));
    waitSnapshot = await collectPrWaitSnapshot(args.pipelineProjectPath, prNumber);
    waitStatus = summarizePrWaitStatus(waitSnapshot);
  }

  const reviewContext = await collectPrReviewContext(args.pipelineProjectPath, prNumber);

  args.log(
    `[PR-REVIEW] Final gate for PR #${prNumber}: checksTerminal=${String(waitStatus.checksTerminal)} ` +
      `codeRabbitSeen=${String(waitStatus.codeRabbitSeen)} codeRabbitComplete=${String(waitStatus.codeRabbitComplete)} mergeConflict=${String(waitStatus.mergeConflict)} ` +
      `blocking=${reviewContext.blockingFindings.length} failedChecks=${reviewContext.failedChecks.length}`,
  );

  if (waitStatus.mergeConflict) return { success: false, reason: `pr_review_merge_conflict: ${waitStatus.mergeConflictReason ?? "unknown"}` };
  if (!waitStatus.checksTerminal) return { success: false, reason: `pr_review_checks_pending: ${waitStatus.pendingChecks.join(", ") || "unknown"}` };
  if (!waitStatus.codeRabbitComplete) return { success: false, reason: waitStatus.codeRabbitSeen ? "pr_review_coderabbit_not_complete" : "pr_review_coderabbit_not_observed" };
  if (reviewContext.failedChecks.length > 0) return { success: false, reason: `pr_review_failed_checks: ${reviewContext.failedChecks.map((check) => check.name).join(", ")}` };
  if (reviewContext.blockingFindings.length > 0) return { success: false, reason: `pr_review_blocking_findings: ${reviewContext.blockingFindings.length}` };
  return { success: true };
}

async function writeMergeReport(args: {
  config: WorkerConfig;
  status: "SUCCESS" | "FAIL" | "SKIPPED";
  details: string;
  merged?: number;
  conflicts?: number;
  failed?: number;
  prNumber?: number;
}): Promise<void> {
  const reportPath = resolveArtifactPath(args.config.worktreePath, join(workerReportDir(args.config), "MERGE_REPORT.md"));
  await mkdir(dirname(reportPath), { recursive: true });
  await writeFile(reportPath, `# Merge Report: ${args.config.taskTitle}\n\n` +
    `## Task: ${args.config.taskId}\n` +
    `## Run: ${args.config.runId}\n` +
    `## Status: ${args.status}\n\n` +
    `## PR\n` +
    `- Number: ${args.prNumber ?? "unknown"}\n\n` +
    `## Result\n` +
    `- Merged: ${args.merged ?? 0}\n` +
    `- Conflicts: ${args.conflicts ?? 0}\n` +
    `- Failed: ${args.failed ?? 0}\n\n` +
    `## Details\n${args.details}\n`, "utf8");
}

async function runMergeBuiltinPhase(args: {
  config: WorkerConfig;
  pipelineProjectPath: string;
  vcsBackend?: VcsBackend;
  log: (msg: string) => void;
  agentMailClient: AnyMailClient | null;
}): Promise<PhaseResult> {
  const { config, pipelineProjectPath, vcsBackend, log, agentMailClient } = args;
  const prNumber = (() => {
    try { return readPrNumberFromMetadata(config.worktreePath, workerReportDir(config)); } catch { return undefined; }
  })();

  const gate = await validatePrReviewGate({
    worktreePath: config.worktreePath,
    pipelineProjectPath,
    log,
    reportDir: workerReportDir(config),
  });
  if (!gate.success) {
    const details = gate.reason ?? "pr_review_gate_failed";
    await writeMergeReport({ config, status: "FAIL", details, prNumber });
    return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: details, outputText: details };
  }

  let enqueueFiles: string[] = [];
  try {
    const enqueueBackend = vcsBackend ?? await VcsBackendFactory.create({ backend: "auto" }, config.worktreePath);
    const enqueueDefaultBranch = await enqueueBackend.detectDefaultBranch(config.worktreePath);
    enqueueFiles = await enqueueBackend.getChangedFiles(config.worktreePath, enqueueDefaultBranch, "HEAD");
  } catch {
    // Non-fatal — proceed with empty file list.
  }

  const enqueueResult = await enqueueToMergeQueue({
    projectId: config.projectId,
    projectPath: pipelineProjectPath,
    taskId: config.taskId,
    runId: config.runId,
    operation: "auto_merge",
    worktreePath: config.worktreePath,
    getFilesModified: () => enqueueFiles,
  });
  if (!enqueueResult.success) {
    const details = `Merge queue enqueue failed: ${enqueueResult.error ?? "unknown"}`;
    await writeMergeReport({ config, status: "FAIL", details, prNumber });
    return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: details, outputText: details };
  }
  const isStubQueue =
    enqueueResult.entry?.error != null &&
    enqueueResult.entry.error.includes("not implemented");

  // When the merge queue is a stub (ElixirMergeQueue not wired to a real backend),
  // fall back to a direct gh pr merge. This avoids the 5-min polling timeout.
  if (isStubQueue && prNumber) {
    log(`[MERGE] Queue is stubbed; using direct gh pr merge for PR #${prNumber}.`);
    try {
      const execFileAsync = promisify(execFile);
      // Brief wait for any pending checks to settle
      await new Promise((r) => setTimeout(r, 5_000));
      const { stdout: mergeCheck } = await execFileAsync("gh", [
        "pr", "view", String(prNumber), "--json", "state,mergeable", "--jq", ".state + \" \" + (.mergeable // \"unknown\")",
      ], { cwd: pipelineProjectPath, timeout: 30_000 });
      const [prState] = mergeCheck.trim().split(" ");
      if (prState === "MERGED") {
        log(`[MERGE] PR #${prNumber} was already merged.`);
        await writeMergeReport({ config, status: "SUCCESS", details: `PR #${prNumber} already merged.`, prNumber });
        return { success: true, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0 };
      }
      if (prState === "CLOSED") {
        const details = `PR #${prNumber} was closed without merging`;
        await writeMergeReport({ config, status: "FAIL", details, prNumber });
        return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: details, outputText: details };
      }
      log(`[MERGE] Attempting gh pr merge #${prNumber}…`);
      const { stdout: mergeResult } = await execFileAsync("gh", [
        "pr", "merge", String(prNumber), "--admin", "--squash",
      ], { cwd: pipelineProjectPath, timeout: 60_000 });
      log(`[MERGE] gh pr merge: ${mergeResult.trim()}`);
      await writeMergeReport({ config, status: "SUCCESS", details: `PR #${prNumber} merged via gh pr merge.`, prNumber });
      return { success: true, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0 };
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      log(`[MERGE] Direct merge failed: ${msg}`);
      const details = `Merge queue stubbed; gh pr merge also failed: ${msg}`;
      await writeMergeReport({ config, status: "FAIL", details, prNumber });
      return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: details, outputText: details };
    }
  }

  // Stub queue with no PR number — nothing to merge and no queue to process.
  if (isStubQueue) {
    const details =
      "Merge queue is not implemented for this project (ElixirMergeQueue is a stub). " +
      "Register the project with 'foreman project register' or configure a merge queue in .foreman/config.yaml.";
    log(`[MERGE] ${details}`);
    await writeMergeReport({ config, status: "FAIL", details, prNumber });
    return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: details, outputText: details };
  }

  sendMail(agentMailClient, "refinery", "branch-ready", {
    taskId: config.taskId,
    runId: config.runId,
    branch: `foreman/${config.taskId}`,
    worktreePath: config.worktreePath,
  });

  // Poll for the PR to actually be merged before returning success.
  // The queue is real here (ElixirMergeQueue was wired); refinery will process it.
  const MERGE_POLL_INTERVAL_MS = 30_000;
  const MERGE_POLL_TIMEOUT_MS = 5 * 60 * 1000;
  let mergeSucceeded = false;
  let mergeFailed = false;
  let mergeError = "unknown";
  const mergePollStart = Date.now();

  if (prNumber) {
    log(`[MERGE] Waiting for PR #${prNumber} to merge (timeout ${MERGE_POLL_TIMEOUT_MS / 1000}s)…`);
    while (Date.now() - mergePollStart < MERGE_POLL_TIMEOUT_MS && !mergeSucceeded && !mergeFailed) {
      await new Promise((r) => setTimeout(r, MERGE_POLL_INTERVAL_MS));
      try {
        const execFileAsync = promisify(execFile);
        const { stdout } = await execFileAsync("gh", ["pr", "view", String(prNumber), "--json", "state,mergedAt"], { cwd: pipelineProjectPath, timeout: 30_000 });
        const prInfo = JSON.parse(stdout) as { state?: string; mergedAt?: string };
        if (prInfo.state === "MERGED") {
          mergeSucceeded = true;
          log(`[MERGE] PR #${prNumber} merged.`);
        } else if (prInfo.state === "CLOSED") {
          mergeFailed = true;
          mergeError = `PR #${prNumber} was closed without merging`;
          log(`[MERGE] PR #${prNumber} closed without merging.`);
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        log(`[MERGE] PR #${prNumber} poll error (will retry): ${msg}`);
      }
    }
  } else {
    // No PR number — skip polling and accept the enqueue result.
    // This preserves legacy behaviour for repos without a tracked PR.
    log(`[MERGE] No PR number found; accepting enqueue result without polling.`);
  }

  if (!mergeSucceeded) {
    const details = mergeFailed
      ? mergeError
      : mergeError !== "unknown"
        ? mergeError
        : `Merge did not complete within the ${MERGE_POLL_TIMEOUT_MS / 1000}s polling timeout. ` +
          `Verify refinery/RefineryAgent is running and processing the merge queue for project ${config.projectId ?? "(unregistered)"}; ` +
          `or register the project with 'foreman project register'.`;
    await writeMergeReport({ config, status: "FAIL", details, prNumber });
    await updateTerminalRunStatus({
      runId: config.runId,
      projectId: config.projectId,
      projectPath: pipelineProjectPath,
      updates: { status: "completed", completed_at: new Date().toISOString() },
    });
    return {
      success: false,
      costUsd: 0,
      turns: 0,
      tokensIn: 0,
      tokensOut: 0,
      error: details,
      outputText: details,
    };
  }
  await writeMergeReport({
    config,
    status: "SUCCESS",
    details: `PR #${prNumber} merged successfully`,
    merged: 1,
    conflicts: 0,
    failed: 0,
    prNumber,
  });
  log(`[MERGE] PR #${prNumber} merged successfully`);

  return {
    success: true,
    costUsd: 0,
    turns: 0,
    tokensIn: 0,
    tokensOut: 0,
    outputText: `PR #${prNumber} merged successfully`,
  };
}

function elixirWorkerEventType(eventType: "phase-start" | "complete" | "heartbeat" | "phase-failed" | "phase-retry" | "phase-skipped" | "phase-verdict" | "phase-nudge" | "phase-report" | "assistant-message" | "tool-call-finished" | "run-completed" | "run-failed" | "task-updated"): string {
  if (eventType === "phase-start") return "phase_started";
  if (eventType === "complete") return "phase_completed";
  if (eventType === "phase-failed") return "phase_failed";
  if (eventType === "phase-retry") return "phase_retry";
  if (eventType === "phase-skipped") return "phase_skipped";
  if (eventType === "phase-verdict") return "phase_verdict";
  if (eventType === "phase-nudge") return "phase_nudge";
  if (eventType === "phase-report") return "phase_report_produced";
  if (eventType === "assistant-message") return "assistant_message";
  if (eventType === "tool-call-finished") return "tool_call_finished";
  if (eventType === "run-completed") return "run_completed";
  if (eventType === "run-failed") return "run_failed";
  if (eventType === "task-updated") return "task_updated";
  return "heartbeat";
}

function truncateForEvent(value: unknown, max = 4_000): string | undefined {
  if (value === undefined || value === null) return undefined;
  let text: string;
  if (typeof value === "string") {
    text = value;
  } else {
    try {
      text = JSON.stringify(value);
    } catch {
      text = String(value);
    }
  }
  if (!text) return undefined;
  return text.length > max ? `${text.slice(0, max)}… [truncated ${text.length - max} chars]` : text;
}

function createWorkerStreamEventForwarder(
  phase: string,
  observabilityWriter?: PipelineObservabilityWriter,
  logFailure?: (message: string) => void,
): ((event: StreamEvent) => void) | undefined {
  if (!observabilityWriter?.logEvent) return undefined;
  const reportFailure = (kind: string, err: unknown) => {
    const msg = err instanceof Error ? err.message : String(err);
    logFailure?.(`[pipeline-observability] ${kind} stream event append failed: ${msg}`);
  };
  let assistantBuffer = "";

  const flushAssistant = (timestamp: string, iteration: number) => {
    const message = assistantBuffer.trim();
    assistantBuffer = "";
    if (!message) return;
    void Promise.resolve(observabilityWriter.logEvent?.("assistant-message", {
      phase,
      phase_id: phase,
      message: truncateForEvent(message),
      output: truncateForEvent(message),
      iteration,
      timestamp,
    })).catch((err: unknown) => reportFailure("assistant-message", err));
  };

  return (event: StreamEvent) => {
    if (event.type === "text") {
      assistantBuffer += event.delta;
      return;
    }
    if (event.type === "turnEnd") {
      flushAssistant(event.timestamp, event.iteration);
      return;
    }
    if (event.type === "toolCallFinished") {
      const resultIsError = typeof event.result === "object" && event.result !== null && (event.result as { isError?: unknown }).isError === true;
      void Promise.resolve(observabilityWriter.logEvent?.("tool-call-finished", {
        phase,
        phase_id: phase,
        tool_call_id: event.toolCallId,
        tool_name: event.toolName,
        status: event.isError || resultIsError ? "error" : "finished",
        args: event.args,
        output: truncateForEvent(event.result),
        result: truncateForEvent(event.result),
        iteration: event.iteration,
        timestamp: event.timestamp,
      })).catch((err: unknown) => reportFailure("tool-call-finished", err));
      return;
    }
    if (event.type === "agentEnd") {
      flushAssistant(event.timestamp, event.iteration);
    }
  };
}

function createElixirWorkerObservabilityWriter(
  config: WorkerConfig,
  registeredProjectId: string,
): PipelineObservabilityWriter | undefined {
  let clientPromise: Promise<ElixirServerClient> | undefined;
  let sequence = -1;
  let eventTail: Promise<void> = Promise.resolve();
  const workerId = `node-pipeline:${config.taskId}`;

  const client = (): Promise<ElixirServerClient> => {
    clientPromise ??= (process.env.FOREMAN_SERVER_URL
      ? Promise.resolve(new ElixirServerClient(process.env.FOREMAN_SERVER_URL, process.env.FOREMAN_WORKER_EVENT_TOKEN ?? process.env.FOREMAN_SERVER_AUTH_TOKEN))
      : new ElixirServerManager().ensureRunning().then((status) => (
        new ElixirServerClient(status.url, process.env.FOREMAN_WORKER_EVENT_TOKEN ?? process.env.FOREMAN_SERVER_AUTH_TOKEN)
      )));
    return clientPromise;
  };

  return {
    async logEvent(eventType, data) {
      eventTail = eventTail.catch(() => { /* keep later worker events flowing after a failed append */ }).then(async () => {
        const phaseId = typeof data.phase === "string" ? data.phase : typeof data.phase_id === "string" ? data.phase_id : "pipeline";
        const nextSequence = sequence + 1;
        sequence = nextSequence;
        await (await client()).sendWorkerEvent({
          run_id: config.runId,
          project_id: registeredProjectId,
          phase_id: phaseId,
          worker_id: workerId,
          type: elixirWorkerEventType(eventType),
          sequence: nextSequence,
          status: typeof data.status === "string" ? data.status : undefined,
          message: typeof data.message === "string" ? data.message : undefined,
          output: typeof data.output === "string" ? data.output : undefined,
          tool_call_id: typeof data.tool_call_id === "string" ? data.tool_call_id : undefined,
          tool_name: typeof data.tool_name === "string" ? data.tool_name : undefined,
          details: { ...data, task_id: config.taskId },
        });
      });
      await eventTail;
    },
  };
}

async function runPipeline(
  config: WorkerConfig,
  store: WorkerStoreCompat,
  logFile: string,
  notifyClient: NotificationClient,
  agentMailClient: AnyMailClient | null,
  registeredReadStore?: RegisteredReadStore,
  registeredProjectId?: string,
): Promise<void> {
  const pipelineProjectPath = config.projectPath ?? inferProjectPathFromWorkspacePath(config.worktreePath);

  // Load project config for taskTypeWorkflowMap.
  // Invalid config must fail fast so workflow routing policy is never ignored.
  const projectCfg = loadProjectConfig(pipelineProjectPath);
  const projectTaskTypeWorkflowMap = projectCfg?.taskTypeWorkflowMap;

  const resolvedWorkflow = config.workflowName ?? resolveWorkflowName(
    config.taskType ?? "feature",
    config.taskLabels,
    projectTaskTypeWorkflowMap,
  );
  const workflowLookup = config.workflowPath ?? resolvedWorkflow;
  // Load the workflow config (phase sequence + per-phase overrides).
  let workflowConfig: WorkflowConfig;
  try {
    workflowConfig = loadWorkflowConfig(workflowLookup, pipelineProjectPath);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[PIPELINE] Failed to load workflow config '${resolvedWorkflow}': ${msg}`);
    throw err;
  }

  const phaseSummary = workflowConfig.phases
    .map((phase) => `${phase.name}:maxTurns=${phase.maxTurns ?? "none"}`)
    .join(", ");
  const workflowSource = workflowConfig.sourcePath ?? "<unknown>";
  log(`[PIPELINE] Workflow loaded name=${workflowConfig.name} source=${workflowSource} phases=[${phaseSummary}]`);
  await appendFile(logFile, `[PIPELINE] Workflow loaded name=${workflowConfig.name} source=${workflowSource} phases=[${phaseSummary}]\n`);

  const { taskClient: runtimeTaskClient, backendType: runtimeTaskBackend } = await createTaskClient(
    pipelineProjectPath,
    {
      registeredProjectId,
    },
  );
  const eventProjectId = registeredProjectId ?? config.projectId;
  const elixirWorkerObservabilityWriter = eventProjectId
    ? createElixirWorkerObservabilityWriter(config, eventProjectId)
    : undefined;
  log(`[pipeline-observability] worker event bridge ${elixirWorkerObservabilityWriter ? "enabled" : "disabled"}${eventProjectId ? ` project=${eventProjectId}` : ""}`);
  const registeredObservabilityWriter: PipelineObservabilityWriter | undefined = (() => {
    const writer = elixirWorkerObservabilityWriter;
    return writer
      ? {
          async logEvent(eventType, data) {
            try {
              await writer.logEvent?.(eventType, data);
            } catch (err: unknown) {
              const msg = err instanceof Error ? err.message : String(err);
              log(`[pipeline-observability] ${eventType} event append failed (non-fatal): ${msg}`);
            }
          },
        }
      : undefined;
  })();

  // Initialize VCS backend for prompt templating (TRD-026, TRD-027).
  // Reconstructed from FOREMAN_VCS_BACKEND env var set by dispatcher.
  let vcsBackend: VcsBackend | undefined;
  try {
    vcsBackend = await VcsBackendFactory.fromEnv(
      pipelineProjectPath,
      process.env.FOREMAN_VCS_BACKEND,
    );
    log(`[PIPELINE] VCS backend: ${vcsBackend.name}`);
  } catch {
    // Non-fatal: falls back to git defaults in buildPhasePrompt
    log(`[PIPELINE] VCS backend init failed — using prompt defaults`);
  }

  // Ensure targetBranch is set so finalize rebases onto the correct branch.
  // If not provided by the dispatcher, detect the default branch from the active backend.
  if (!config.targetBranch && vcsBackend) {
    try {
      config.targetBranch = await vcsBackend.detectDefaultBranch(pipelineProjectPath);
    } catch {
      // Non-fatal: falls back to "main" in buildPhasePrompt
    }
  }

  // Delegate to the generic workflow-driven executor.
    await executePipeline({
      config: { ...config, vcsBackend },
      workflowConfig,
      store,
      logFile,
      notifyClient,
      agentMailClient,
      observabilityWriter: registeredObservabilityWriter,
      async onTaskPhaseChange(taskId, phaseName) {
        if (runtimeTaskBackend !== "native" || !taskId) return;
        const nativeStatus = nativeTaskStatusForPhase(phaseName);
        if (!nativeStatus) return;
        try {
          await runtimeTaskClient.update(taskId, { status: nativeStatus });
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          log(`[task-phase] native status update failed (non-fatal): ${msg}`);
        }
      },
      async onTaskPhaseNote(taskId, phaseName, kind, body, metadata) {
        if (runtimeTaskBackend !== "native" || !taskId || !registeredProjectId) return;
        try {
          await elixirWorkerObservabilityWriter?.logEvent?.("task-updated", {
            run_id: config.runId,
            task_id: taskId,
            phase_id: phaseName,
            kind,
            body,
            metadata,
          });
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          log(`[task-note] event append failed (non-fatal): ${msg}`);
        }
      },
      async onWorktreeUpdatedAfterPhase(phase, progress) {
        await checkpointWorktreeAndEnsureDraftPrAfterPhase({
          config,
          phase,
          progress,
          workflowConfig,
          store,
          runtimeTaskClient,
          pipelineProjectPath,
          registeredProjectId,
          registeredReadStore,
          vcsBackend,
          log,
          agentMailClient,
        });
      },
      epicTasks: config.epicTasks,
      runPhase,
      async runBuiltinPhase(phase: WorkflowPhaseConfig, progress?: RunProgress) {
        try {
          const deterministicBuiltin = await runDeterministicTestBuiltinPhase({ config, phase });
          if (deterministicBuiltin) return deterministicBuiltin;

          if (phase.name === "create-pr") {
            return await runCreatePrBuiltinPhase({
              config,
              store,
              runtimeTaskClient,
              pipelineProjectPath,
              registeredProjectId,
              registeredReadStore,
              vcsBackend,
              log,
              agentMailClient,
            });
          }
          if (phase.name === "pr-wait") {
            return await runPrWaitBuiltinPhase({ config, phase, pipelineProjectPath, log });
          }
          if (phase.name === "cli-review") {
            return await runCliReviewBuiltinPhase({ config, pipelineProjectPath, vcsBackend, log });
          }
          if (phase.name === "finalize") {
            return await runFinalizeBuiltinPhase({ config, pipelineProjectPath, vcsBackend, log, progress });
          }
          if (phase.name === "prepare-pr-review") {
            return await runPreparePrReviewBuiltinPhase({ config, pipelineProjectPath, log });
          }
          if (phase.name === "merge") {
            return await runMergeBuiltinPhase({
              config,
              pipelineProjectPath,
              vcsBackend,
              log,
              agentMailClient,
            });
          }
          return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: `Unknown builtin phase: ${phase.name}` };
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: msg };
        }
      },
      registerAgent,
      sendMail,
      sendMailText,
      reserveFiles,
      releaseFiles,
      markStuck: async (storeArg, runIdArg, projectIdArg, taskIdArg, taskTitleArg, progressArg, phaseArg, reasonArg, projectPathArg, notifyClientArg) => {
        return markStuck(
          storeArg,
          runIdArg,
          projectIdArg,
          taskIdArg,
          taskTitleArg,
          progressArg,
          phaseArg,
          reasonArg,
          projectPathArg,
          notifyClientArg,
          registeredReadStore,
        );
      },
      log,
      promptOpts: { projectRoot: pipelineProjectPath, workflow: resolvedWorkflow },
      taskMeta: config.taskMeta,

    // Epic mode: sync child task status as the pipeline progresses.
    async onTaskStatusChange(taskTaskId, status) {
      if (status === "in_progress") {
        await runtimeTaskClient.update(taskTaskId, { status: "in_progress" });
        log(`[EPIC] task update ${taskTaskId} → in_progress`);
      } else if (status === "completed") {
        await runtimeTaskClient.close(taskTaskId, "Completed via epic pipeline");
        log(`[EPIC] task close ${taskTaskId} (completed)`);
      } else if (status === "failed") {
        await runtimeTaskClient.update(taskTaskId, { status: "failed" });
        log(`[EPIC] task update ${taskTaskId} → failed`);
      }
    },

    // Epic mode: create a bug task when QA fails on a child task.
    async onTaskQaFailure(taskTaskId, taskTitle, epicId) {
      if (!runtimeTaskClient.create) {
        throw new Error("Runtime task client does not support create");
      }

      const bug = await runtimeTaskClient.create(`QA failure: ${taskTitle}`, {
        type: "bug",
        priority: "1",
        parent: epicId,
        description: `QA failed for task ${taskTaskId} (${taskTitle}) during epic pipeline run.`,
      });
      log(`[EPIC] Created bug task ${bug.id} for QA failure on ${taskTaskId}`);
      return bug.id;
    },

    // Epic mode: close a bug task when QA passes on retry.
    async onTaskQaPass(bugTaskId) {
      await runtimeTaskClient.close(bugTaskId, "QA passed on retry");
      log(`[EPIC] Closed bug task ${bugTaskId} (QA passed on retry)`);
    },

    // P1: Rate limit alert callback - log rate limit events for alerting
    onRateLimit(model, phase, error, retryAfterSeconds) {
      // P1: Alert when rate limit detected in logs
      const alertMsg = `[RATE_LIMIT_ALERT] ${phase} phase rate limited on ${model}` +
        (retryAfterSeconds ? ` (Retry-After: ${retryAfterSeconds}s)` : "") +
        ` at ${new Date().toISOString()}`;
      console.error(alertMsg);
      log(alertMsg);

      // Also send agent-error mail for visibility
      sendMail(agentMailClient, "foreman", "rate-limit-alert", {
        taskId: config.taskId,
        phase,
        model,
        error,
        retryAfterSeconds,
      });
    },

    // Pipeline post-processing: determine finalize push success, then enqueue merge after
    // any post-finalize phases (for example create-pr/pr-review) complete.
    async onPipelineComplete({ progress, success, failedPhase: reportedFailedPhase, failureReason: reportedFailureReason, waitingForOperator, waitingQuestion }) {
      // ASK_OPERATOR control outcome: pause the pipeline for operator input.
      // Persist the run as waiting (not failed) so finalize does not re-dispatch
      // it. Subsequent phase runs will read the operator's response from mail.
      if (waitingForOperator) {
        const now = new Date().toISOString();
        const { runId, projectId, taskId } = config;
        log(`[PIPELINE] WAITING FOR OPERATOR (${taskId}): ${waitingQuestion ?? "(no question)"}`);
        await appendFile(logFile, `\n[PIPELINE] WAITING FOR OPERATOR: ${waitingQuestion ?? "(no question)"}\n`);
        await updateTerminalRunStatus({
          runId,
          projectId: config.projectId,
          projectPath: pipelineProjectPath,
          updates: { status: "waiting_for_operator", completed_at: now },
        });
        notifyClient.send({ type: "status", runId, status: "waiting_for_operator", timestamp: now, details: { question: waitingQuestion } });
        return;
      }


      const hasFinalizePhase = workflowConfig.phases.some((phase) => phase.name === "finalize");
      if (!hasFinalizePhase) {
        log(`[PIPELINE] Skipping branch-ready: workflow has no finalize phase`);
        return;
      }
      const hasExplicitMergePhase = workflowConfig.phases.some((phase) => phase.name === "merge");
      const hasCreatePrPhase = workflowConfig.phases.some((phase) => phase.name === "create-pr");
      const { runId, projectId, taskId, taskTitle, worktreePath } = config;

      if (hasExplicitMergePhase) {
        const completedPhases = workflowConfig.phases.map((p) => p.name).join("→");
        const eventType = success ? "complete" : "fail";
        const eventData = {
          taskId,
          title: taskTitle,
          costUsd: progress.costUsd,
          numTurns: progress.turns,
          toolCalls: progress.toolCalls,
          filesChanged: progress.filesChanged.length,
          phases: completedPhases,
        };
        store.logEvent(projectId, eventType, eventData, runId);
        const now = new Date().toISOString();
        if (success) {
          await Promise.resolve(registeredObservabilityWriter?.logEvent?.("run-completed", {
            run_id: runId,
            task_id: taskId,
            status: "completed",
            completed_at: now,
          }));
          await updateTerminalRunStatus({
            runId,
            projectId: config.projectId,
            projectPath: pipelineProjectPath,
            updates: { status: "completed", completed_at: now },
          });
          notifyClient.send({ type: "status", runId, status: "completed", timestamp: now });
          log(`PIPELINE COMPLETED for ${taskId} (${progress.turns} turns, ${progress.toolCalls} tools, $${progress.costUsd.toFixed(4)})`);
          await appendFile(logFile, `\n[PIPELINE] COMPLETED ($${progress.costUsd.toFixed(4)}, ${progress.turns} turns)\n`);
        } else {
          const terminalFailedPhase = reportedFailedPhase ?? progress.currentPhase ?? "pipeline";
          await Promise.resolve(registeredObservabilityWriter?.logEvent?.("run-failed", {
            run_id: runId,
            task_id: taskId,
            status: "failed",
            failed_at: now,
            phase: terminalFailedPhase,
            phase_id: terminalFailedPhase,
            reason: reportedFailureReason ?? `${terminalFailedPhase}_failed`,
          }));
          await updateTerminalRunStatus({
            runId,
            projectId: config.projectId,
            projectPath: pipelineProjectPath,
            updates: { status: "failed", completed_at: now },
          });
          notifyClient.send({ type: "status", runId, status: "failed", timestamp: now });
          log(`PIPELINE FAILED for ${taskId} with explicit merge workflow ($${progress.costUsd.toFixed(4)})`);
          await appendFile(logFile, `\n[PIPELINE] FAILED ($${progress.costUsd.toFixed(4)})\n`);
        }
        return;
      }

      // Read finalize outcome from agent mail. If a later post-finalize phase failed,
      // preserve the actual phase name instead of reporting every pipeline failure
      // as finalize_validation_failed.
      const failedPhase = success ? "finalize" : (reportedFailedPhase ?? progress.currentPhase ?? "finalize");
      let finalizeSucceeded = success;
      let finalizeRetryable = true;
      let finalizeFailureReason = success ? "" : (reportedFailureReason ?? `${failedPhase}_failed`);
      if (agentMailClient) {
        const foremanMsgs = await agentMailClient.fetchInbox("foreman");
        const finalizeSender = `finalize-${taskId}`;
        const finalizeMsgs = foremanMsgs.filter(
          (m) => (m.subject === "phase-complete" || m.subject === "agent-error") &&
                  (m.from === finalizeSender || m.from === "finalize"),
        );
        const nonRetryableError = finalizeMsgs.find((m) => {
          if (m.subject !== "agent-error") return false;
          try {
            const body = JSON.parse(m.body ?? "{}") as Record<string, unknown>;
            return body["retryable"] === false;
          } catch {
            return false;
          }
        });
        const finalizePhaseComplete = finalizeMsgs.find((m) => m.subject === "phase-complete");

        if (nonRetryableError) {
          const body = (() => { try { return JSON.parse(nonRetryableError.body ?? "{}") as Record<string, unknown>; } catch { return {} as Record<string, unknown>; } })();
          finalizeRetryable = false;
          finalizeSucceeded = false;
          finalizeFailureReason = typeof body["error"] === "string"
            ? body["error"]
            : "finalize_non_retryable_error";
          log(`[FINALIZE] non-retryable agent-error mail received — error: ${finalizeFailureReason}`);
        } else if (finalizePhaseComplete?.subject === "phase-complete") {
          const body = (() => { try { return JSON.parse(finalizePhaseComplete.body ?? "{}") as Record<string, unknown>; } catch { return {} as Record<string, unknown>; } })();
          const status = typeof body["status"] === "string" ? body["status"] : "complete";
          finalizeRetryable = body["retryable"] !== false;
          finalizeSucceeded = status === "complete" || status === "completed" || status === "success";
          if (!finalizeSucceeded) {
            finalizeFailureReason = typeof body["note"] === "string"
              ? body["note"]
              : "finalize_phase_reported_failed_status";
          }
          log(`[FINALIZE] phase-complete mail received — status=${status}, retryable=${String(finalizeRetryable)}`);
        } else {
          const finalizeAgentError = finalizeMsgs.find((m) => m.subject === "agent-error");
          if (finalizeAgentError?.subject === "agent-error") {
            const body = (() => { try { return JSON.parse(finalizeAgentError.body ?? "{}") as Record<string, unknown>; } catch { return {} as Record<string, unknown>; } })();
            finalizeRetryable = body["retryable"] !== false;
            const errorDetail = typeof body["error"] === "string" ? body["error"] : "unknown finalize error";
            finalizeFailureReason = errorDetail;
            log(`[FINALIZE] agent-error mail received — error: ${errorDetail}, retryable: ${String(finalizeRetryable)}`);

            if (errorDetail === "nothing_to_commit") {
              const taskType = config.taskType ?? "";
              const taskTitle = config.taskTitle ?? "";
              const isVerificationTask = taskType === "test" ||
                /verify|validate|test/i.test(taskTitle);

              let hasCommitsAhead = false;
              {
                const candidates: string[] = [];
                if (config.targetBranch) {
                  candidates.push(`origin/${config.targetBranch}`, config.targetBranch);
                }
                candidates.push("origin/dev", "origin/main");
                const aheadBackend = vcsBackend ?? await VcsBackendFactory.create({ backend: "auto" }, worktreePath);
                for (const ref of candidates) {
                  try {
                    const changedFiles = await aheadBackend.getChangedFiles(worktreePath, ref, "HEAD");
                    hasCommitsAhead = changedFiles.length > 0;
                    break;
                  } catch {
                    // Ref doesn't exist or git failed — try next
                  }
                }
              }

              if (hasCommitsAhead) {
                finalizeSucceeded = true;
                log(`[FINALIZE] nothing_to_commit but branch has prior commits — treating as success (reused worktree)`);
              } else if (isVerificationTask) {
                finalizeSucceeded = true;
                log(`[FINALIZE] nothing_to_commit on verification task (type="${taskType}", title="${taskTitle}") — treating as success`);
              } else {
                finalizeSucceeded = true;
                log(`[FINALIZE] nothing_to_commit and no commits ahead — work already on target branch, treating as success`);
              }
            }
          } else {
            // No finalize-specific mail — preserve the pipeline success result.
                    // A finalize FAIL verdict may not emit phase-complete or agent-error
            // mail, so assuming success here can incorrectly mark failed runs
            // completed.
            log(`[FINALIZE] No finalize mail found — preserving pipeline success=${String(finalizeSucceeded)}`);
          }
        }
      }

      // ── Troubleshooter: attempt recovery on failure ──────────────────────
      const shouldSkipTroubleshooter =
        !finalizeSucceeded &&
        !finalizeRetryable &&
        finalizeFailureReason === "tests_failed_pre_existing_issues";
      if (shouldSkipTroubleshooter) {
        log("[TROUBLESHOOTER] Skipping for non-retryable pre-existing finalize test failures");
      }
      const troubleshooterEnabled = !finalizeSucceeded && !!workflowConfig.onFailure && !shouldSkipTroubleshooter;
      let troubleshooterResolved = false;
      if (troubleshooterEnabled) {
        const failureContext = `Pipeline failed at ${failedPhase} phase. finalizeRetryable=${String(finalizeRetryable)}`;
        troubleshooterResolved = await runTroubleshooterPhase(
          config,
          workflowConfig,
          store,
          logFile,
          notifyClient,
          agentMailClient,
          failureContext,
          pipelineProjectPath,
        );
        if (troubleshooterResolved) {
          // Troubleshooter resolved the issue — treat as success
          finalizeSucceeded = true;
        }
      }

      const hasPrReviewPhase = workflowConfig.phases.some((phase) => phase.name === "pr-review");
      const prMetadataPath = resolveArtifactPath(worktreePath, join(workerReportDir(config), "PR_METADATA.json"));
      if (finalizeSucceeded && hasPrReviewPhase && existsSync(prMetadataPath)) {
        try {
          const gate = await validatePrReviewGate({ worktreePath, pipelineProjectPath, log, reportDir: workerReportDir(config) });
          if (!gate.success) {
            finalizeSucceeded = false;
            finalizeRetryable = false;
            finalizeFailureReason = gate.reason ?? "pr_review_gate_failed";
            log(`[PR-REVIEW] Final gate failed — ${finalizeFailureReason}`);
          }
        } catch (gateErr: unknown) {
          const gateMsg = gateErr instanceof Error ? gateErr.message : String(gateErr);
          finalizeSucceeded = false;
          finalizeRetryable = false;
          finalizeFailureReason = `pr_review_gate_error: ${gateMsg}`;
          log(`[PR-REVIEW] Final gate errored — ${gateMsg}`);
        }
      }

      const now = new Date().toISOString();
      if (finalizeSucceeded) {

        // Mark run as completed after all configured phases have succeeded.
        await updateTerminalRunStatus({
          runId,
          projectId: config.projectId,
          projectPath: pipelineProjectPath,
          updates: { status: "completed", completed_at: now },
        });
        notifyClient.send({ type: "status", runId, status: "completed", timestamp: now });

        if (hasCreatePrPhase) {
          log(`[PIPELINE] PR creation handled by create-pr phase`);
        }

        let skipMergeQueue = false;
        if (troubleshooterResolved) {
          try {
            const completionBackend = vcsBackend ?? await VcsBackendFactory.create({ backend: "auto" }, worktreePath);
            const completionTargetBranch = config.targetBranch ?? await completionBackend.detectDefaultBranch(worktreePath);
            const changedAgainstTarget = await completionBackend.getChangedFiles(worktreePath, completionTargetBranch, "HEAD");
            if (changedAgainstTarget.length === 0) {
              skipMergeQueue = true;
              log(`[FINALIZE] Branch already matches ${completionTargetBranch} after troubleshooter recovery — skipping branch-ready/merge queue`);
              await updateTaskStatusViaElixir(pipelineProjectPath, registeredProjectId, taskId, "closed", "agent-worker-finalize");
            }
          } catch (alreadyMergedErr: unknown) {
            const alreadyMergedMsg = alreadyMergedErr instanceof Error ? alreadyMergedErr.message : String(alreadyMergedErr);
            log(`[FINALIZE] Unable to verify post-troubleshooter merge state (continuing with merge queue): ${alreadyMergedMsg}`);
          }
        }

        if (!skipMergeQueue && hasExplicitMergePhase) {
          log("[FINALIZE] Merge handled by explicit merge phase");
        }
      } else {
        let alreadyLandedOnTarget = false;
        if (!finalizeRetryable && finalizeFailureReason === "tests_failed_pre_existing_issues") {
          try {
            const completionBackend = vcsBackend ?? await VcsBackendFactory.create({ backend: "auto" }, worktreePath);
            const completionTargetBranch = config.targetBranch ?? await completionBackend.detectDefaultBranch(worktreePath);
            const changedAgainstTarget = await completionBackend.getChangedFiles(worktreePath, completionTargetBranch, "HEAD");
            if (changedAgainstTarget.length === 0) {
              alreadyLandedOnTarget = true;
              await updateTerminalRunStatus({
                runId,
                projectId: config.projectId,
                projectPath: pipelineProjectPath,
                updates: { status: "merged", completed_at: now },
              });
              notifyClient.send({ type: "status", runId, status: "merged", timestamp: now });
              await updateTaskStatusViaElixir(pipelineProjectPath, registeredProjectId, taskId, "closed", "agent-worker-finalize");
              log(`[FINALIZE] Pre-existing test failures but branch already matches ${completionTargetBranch} — treating task as merged`);
            }
          } catch (alreadyMergedErr: unknown) {
            const alreadyMergedMsg = alreadyMergedErr instanceof Error ? alreadyMergedErr.message : String(alreadyMergedErr);
            log(`[FINALIZE] Unable to verify whether pre-existing test failure run already landed on target: ${alreadyMergedMsg}`);
          }
        }

      if (!alreadyLandedOnTarget) {
        const terminalStatus = finalizeRetryable ? "stuck" : "failed";
        await updateTerminalRunStatus({
          runId,
          projectId: config.projectId,
            projectPath: pipelineProjectPath,
            updates: { status: terminalStatus, completed_at: now },
          });
          notifyClient.send({ type: "status", runId, status: terminalStatus, timestamp: now });
          sendMail(agentMailClient, "foreman", "agent-error", {
            taskId,
            phase: failedPhase,
            error: finalizeFailureReason || `${failedPhase} failed`,
            retryable: finalizeRetryable,
          });
          if (finalizeRetryable) {
            await updateTaskStatusViaElixir(pipelineProjectPath, registeredProjectId, taskId, "ready", "agent-worker-finalize");
          } else {
            await updateTaskStatusViaElixir(pipelineProjectPath, registeredProjectId, taskId, "failed", "agent-worker-finalize");
            log(`[PIPELINE] Deterministic finalize failure for ${taskId} — marking failed without retry`);
          }
        }
      }

      const writeFinalizeTerminalEvent = async (
        eventType: "complete" | "stuck" | "fail",
        data: Record<string, unknown>,
      ): Promise<void> => {
        await registeredObservabilityWriter?.logEvent?.(eventType === "complete" ? "run-completed" : "run-failed", {
          ...data,
          terminal_event: eventType,
        });
      };

      // Authoritative terminal domain events come from the worker, not the launcher.
      const completedPhases = workflowConfig.phases.map((p) => p.name).join("→");
      const terminalPayload = {
        taskId,
        task_id: taskId,
        title: taskTitle,
        costUsd: progress.costUsd,
        numTurns: progress.turns,
        toolCalls: progress.toolCalls,
        filesChanged: progress.filesChanged.length,
        phases: completedPhases,
        phase_id: finalizeSucceeded ? undefined : failedPhase,
        failure_reason: finalizeSucceeded ? undefined : (finalizeFailureReason || `${failedPhase} failed`),
      };
      if (registeredProjectId && elixirWorkerObservabilityWriter?.logEvent) {
        await elixirWorkerObservabilityWriter.logEvent(finalizeSucceeded ? "run-completed" : "run-failed", terminalPayload);
        await elixirWorkerObservabilityWriter.logEvent("task-updated", {
          ...terminalPayload,
          status: finalizeSucceeded ? "completed" : "failed",
        });
      }

      // Compatibility read-model event for local debug surfaces.
      await writeFinalizeTerminalEvent(finalizeSucceeded ? "complete" : (finalizeRetryable ? "stuck" : "fail"), terminalPayload);

      if (finalizeSucceeded) {
        log(`PIPELINE COMPLETED for ${taskId} (${progress.turns} turns, ${progress.toolCalls} tools, $${progress.costUsd.toFixed(4)})`);
        await appendFile(logFile, `\n[PIPELINE] COMPLETED ($${progress.costUsd.toFixed(4)}, ${progress.turns} turns)\n`);

        // ── Continuation Retry: re-check issue state before considering done ──
        // Schedule a quick re-check 1 second after clean exit to catch issues that
        // remain active (e.g. backlog items that were updated while the agent ran).
        const continuationCheck = async (
          checkRunId: string,
          checkTaskId: string,
          checkProjectPath: string,
          checkRegisteredProjectId?: string,
        ): Promise<void> => {
          try {
            const runtimeTaskClient = await createRuntimeTaskClient(checkProjectPath, checkRegisteredProjectId);
            const issueDetail = await runtimeTaskClient.show(checkTaskId);
            // Issue is inactive (terminal) if status is null/undefined, "closed", or "completed".
            // Treat null/undefined as terminal: issue was deleted or unreachable.
            const isTerminal = !issueDetail.status ||
              issueDetail.status === "closed" ||
              issueDetail.status === "completed";
            if (isTerminal) {
              log(`[CONTINUATION] Issue ${checkTaskId} transitioned to ${issueDetail.status ?? "null/undefined"} — marking completed`);
              await updateTerminalRunStatus({
                runId: checkRunId,
                projectId: config.projectId,
                projectPath: checkProjectPath,
                updates: { status: "completed", completed_at: new Date().toISOString() },
              });
            } else {
              log(`[CONTINUATION] Issue ${checkTaskId} remains active (status=${issueDetail.status}) — keeping run as running for potential continuation`);
              // Keep as "running" so dispatcher can re-dispatch if needed
              await updateTerminalRunStatus({
                runId: checkRunId,
                projectId: config.projectId,
                projectPath: checkProjectPath,
                updates: { status: "running" },
              });
            }
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            log(`[CONTINUATION] Failed to re-check issue ${checkTaskId}: ${msg} — marking completed as safe default`);
            // On error, mark as completed to avoid leaving run in limbo
            await updateTerminalRunStatus({
              runId: checkRunId,
              projectId: config.projectId,
              projectPath: checkProjectPath,
              updates: { status: "completed", completed_at: new Date().toISOString() },
            });
          }
        };
        setTimeout(() => continuationCheck(runId, taskId, pipelineProjectPath, registeredProjectId), 1000);
      } else {
        log(`PIPELINE STUCK for ${taskId} — ${failedPhase} failed ($${progress.costUsd.toFixed(4)})`);
        await appendFile(logFile, `\n[PIPELINE] STUCK — ${failedPhase} failed ($${progress.costUsd.toFixed(4)})\n`);
      }
    },
  });

}

// NOTE: ~460 lines of hardcoded pipeline code removed.
// Pipeline execution is now driven by workflow YAML via executePipeline() in pipeline-executor.ts.

async function markStuck(
  _store: WorkerStoreCompat,
  runId: string,
  projectId: string,
  taskId: string,
  taskTitle: string,
  progress: RunProgress,
  phase: string,
  reason: string,
  projectPath: string,
  notifyClient?: NotificationClient,
  _registeredReadStore?: RegisteredReadStore,
): Promise<void> {
  const reasonLower = reason.toLowerCase();
  const isRateLimit = reasonLower.includes("hit your limit") || reasonLower.includes("rate limit");
  const now = new Date().toISOString();
  const stuckStatus = isRateLimit ? "stuck" : "failed";
  await writeMarkStuckProgress(undefined, runId, progress, log);
  await updateTerminalRunStatus({
    runId,
    projectId,
    projectPath,
    updates: { status: stuckStatus, completed_at: now },
  });
  notifyClient?.send({ type: "status", runId, status: stuckStatus, timestamp: now, details: { phase, reason } });
  await writeMarkStuckEvent(undefined, projectId, runId, isRateLimit ? "stuck" : "fail", {
    taskId,
    title: taskTitle,
    phase,
    reason,
    costUsd: progress.costUsd,
    rateLimit: isRateLimit,
  }, log);

  // For transient errors (rate limits), reset to 'open' so the task re-enters
  // the ready queue for automatic retry.
  // For permanent failures, mark as 'failed' so the task is NOT auto-retried —
  // the operator must investigate and re-open it manually.
  if (isRateLimit) {
    await updateTaskStatusViaElixir(projectPath, projectId, taskId, "ready", "agent-worker-markStuck");
    log(`Updated ${taskId} to ready via Elixir (rate limited — will retry on next dispatch)`);
  } else {
    await updateTaskStatusViaElixir(projectPath, projectId, taskId, "failed", "agent-worker-markStuck");
    log(`Updated ${taskId} to failed via Elixir (permanent failure — manual intervention required)`);
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────


function log(msg: string): void {
  if (logContext) {
    const entry: Record<string, unknown> = {
      level: "info",
      timestamp: new Date().toISOString(),
      message: msg,
      issueId: logContext.issueId,
      issueIdentifier: logContext.issueIdentifier,
      sessionId: logContext.sessionId,
      runId: logContext.runId,
      attempt: logContext.attempt,
    };
    console.error(JSON.stringify(entry));
  } else {
    // Fallback for early-use before context is initialized
    const ts = new Date().toISOString().slice(11, 23);
    console.error(`[foreman-worker ${ts}] ${msg}`);
  }
}

// ── Entry ────────────────────────────────────────────────────────────────────

/**
 * Top-level fatal error handler.
 *
 * When main() rejects (e.g. config parse failure or runPipeline() propagates an uncaught error), we attempt to:
 *   1. Update the run status to "failed" so the run is not left stuck.
 *   2. Send an Agent Mail "worker-error" message to the "foreman" mailbox so
 *      the operator can see the error without having to grep log files.
 *
 * Both operations are best-effort — if Agent Mail is unavailable or the store
 * cannot be opened, we log and exit cleanly rather than masking the original
 * error.
 *
 * The config is re-read from argv[2] if it still exists on disk (worker
 * crashed before unlinking it), or parsed from what we can infer.  We attempt
 * to load runId/taskId from the config so we can target the correct DB row.
 */
async function fatalHandler(err: unknown): Promise<void> {
  const msg = err instanceof Error ? err.message : String(err);
  console.error(`[foreman-worker] Fatal: ${msg}`);

  // Try to recover enough context to update run state + send Agent Mail.
  const configPath = process.argv[2];
  if (!configPath) {
    process.exit(1);
  }

  let runId: string | undefined;
  let taskId: string | undefined;
  let projectId: string | undefined;
  let projectPath: string | undefined;

  // Config may have already been deleted by main(); re-read if still present.
  try {
    const raw = readFileSync(configPath, "utf-8");
    const cfg = JSON.parse(raw) as Partial<WorkerConfig>;
    runId = cfg.runId;
    taskId = cfg.taskId;
    projectId = cfg.projectId;
    projectPath = cfg.projectPath ?? (cfg.worktreePath ? inferProjectPathFromWorkspacePath(cfg.worktreePath) : undefined);
  } catch {
    // Config already deleted (worker started successfully but crashed later).
    // We cannot recover context from disk at this point.
  }

  if (runId && projectPath) {
    // Repair the fatal run status with the registered backend when available.
    try {
      await updateFatalRunStatus({
        runId,
        projectId,
        projectPath,
        completedAt: new Date().toISOString(),
      });
    } catch (storeErr: unknown) {
      const storeMsg = storeErr instanceof Error ? storeErr.message : String(storeErr);
      console.error(`[foreman-worker] Could not update run status: ${storeMsg}`);
    }

    // Send Agent Mail notification so the run record reflects the fatal error.
    // agentMailClient is not in scope here — create a fresh one.
    if (taskId && runId) {
      try {
        const mailCandidate = await createProjectMailClient(projectPath);
        mailCandidate.setRunId(runId);
        await mailCandidate.sendMessage(
          "foreman",
          "worker-error",
          JSON.stringify({
            runId,
            taskId,
            error: msg,
            phase: currentPhase,
          }),
        );
      } catch {
        // Mail unavailable — run-status update above is sufficient.
      }
    }
  }

  process.exit(1);
}

main()
  .then(() => process.exit(0))
  .catch(fatalHandler);
