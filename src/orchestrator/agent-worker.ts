#!/usr/bin/env node
/**
 * Agent Worker — standalone process that runs a single SDK agent.
 *
 * Spawned as a detached child process by the dispatcher. Survives parent exit.
 * Reads config from a JSON file passed as argv[2], runs the SDK query(),
 * and updates the Postgres store with progress/completion.
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
  createCloseBeadTool,
  createGetRunStatusTool,
  createGraphifyExplainTool,
  createGraphifyQueryTool,
  createMailReadTool,
  createMailSendTool,
  createPhaseHandoffTool,
  createProgressUpdateTool,
  createSafeCommandRunTool,
  createSendMailTool,
  createTaskBlockTool,
  createValidationResultTool,
  type ForemanToolContext,
} from "./pi-sdk-tools.js";
import { ensureGraphifyIndex } from "./graphify-index.js";
import { executePipeline } from "./pipeline-executor.js";
import type { EpicTask, PhaseObservabilityInput, PipelineObservabilityWriter } from "./pipeline-executor.js";
import { ForemanStore } from "../lib/store.js";
import type { RunProgress } from "../lib/store.js";
import { PostgresStore } from "../lib/postgres-store.js";
import type { RunProgressSummary } from "./read-models.js";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import { initPool, isPoolInitialised } from "../lib/db/pool-manager.js";
import { ElixirServerManager } from "../lib/elixir-server-manager.js";
import { ElixirServerClient } from "../lib/elixir-server-client.js";
import { PIPELINE_BUFFERS, PIPELINE_TIMEOUTS } from "../lib/config.js";
import {
  ROLE_CONFIGS,
  getDisallowedTools,
} from "./roles.js";
import { enqueueToMergeQueue } from "./agent-worker-enqueue.js";
import { enqueueResetTaskToOpen, enqueueMarkBeadFailed, enqueueAddNotesToBead, enqueueCloseTask } from "./task-backend-ops.js";
import { updateFatalRunStatus } from "./agent-worker-fatal-path.js";
import { updateTerminalRunStatus } from "./agent-worker-run-status.js";
import { createDualWriteStore } from "./rate-limit-dual-write.js";
import { writeMarkStuckEvent, writeMarkStuckProgress } from "./agent-worker-mark-stuck-observability.js";
import { writeSingleAgentProgress, writeSingleAgentTerminalEvent } from "./agent-worker-single-agent-observability.js";
import type { WorkerNotification } from "./types.js";
import { inferProjectPathFromWorkspacePath } from "../lib/workspace-paths.js";
import type { AgentMailClient } from "../lib/agent-mail-client.js";
import { createProjectMailClient, resolveProjectDatabaseUrl } from "../lib/project-mail-client.js";
import { ProjectRegistry } from "../lib/project-registry.js";
import { createTaskClient } from "../lib/task-client-factory.js";
import { loadWorkflowConfig, resolveWorkflowName, type WorkflowConfig } from "../lib/workflow-loader.js";
import { getRunReportsDir, resolveArtifactPath } from "../lib/report-paths.js";
import { autoMerge } from "./auto-merge.js";
import { runCodeRabbitCliReview } from "./coderabbit-cli-review.js";
import { collectPrReviewContext, collectPrWaitSnapshot, summarizePrWaitStatus, updatePrReadyStability, writePrReviewFindings, writePrWaitReport } from "./pr-review-context.js";
import { Refinery } from "./refinery.js";
import type { ITaskClient } from "../lib/task-client.js";
import { VcsBackendFactory } from "../lib/vcs/index.js";
import type { VcsBackend } from "../lib/vcs/interface.js";
import type { TaskMeta } from "../lib/interpolate.js";
import type { WorkflowPhaseConfig } from "../lib/workflow-loader.js";
import { runWorkspaceHook } from "../lib/setup.js";
import { loadProjectConfig, type ProjectHooksConfig } from "../lib/project-config.js";
import { nativeTaskStatusForPhase } from "./task-phase-status.js";

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

async function resolveRegisteredProjectIdForPath(
  projectPath: string,
  databaseUrl?: string,
): Promise<string | undefined> {
  if (!databaseUrl) return undefined;

  if (!isPoolInitialised()) {
    try {
      initPool({ databaseUrl });
    } catch {
      // Fall through to the legacy registry source when Postgres is unavailable.
    }
  }

  const registries = [
    new ProjectRegistry({ pg: new PostgresAdapter() }),
    new ProjectRegistry(),
  ];

  for (const registry of registries) {
    try {
      const projects = await registry.list();
      const match = projects.find((project) => project.path === projectPath);
      if (match) {
        return match.id;
      }
    } catch {
      // Fall through to the next registry source.
    }
  }

  return undefined;
}

// ── Agent Mail helper ─────────────────────────────────────────────────────────

/** Mail client type. */
type AnyMailClient = AgentMailClient;

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
  /** Project root directory (contains .beads/). Used as cwd for br commands. */
  projectPath?: string;
  prompt: string;
  env: Record<string, string>;
  resume?: string;  // SDK session ID to resume
  pipeline?: boolean;  // Run as lead pipeline (explorer → developer → qa → reviewer)
  /** Explicit workflow name/path for direct task execution. Overrides task labels/type. */
  workflowName?: string;
  workflowPath?: string;
  /**
   * Bead type field (e.g. "feature", "bug", "task", "smoke").
   * Used to resolve the workflow name when no `workflow:<name>` label is set.
   */
  taskType?: string;
  /**
   * Labels from the bead. Used to resolve `workflow:<name>` overrides.
   * e.g. ["phase:explorer", "workflow:smoke"]
   */
  taskLabels?: string[];
  /**
   * Bead priority string ("P0"–"P4", "0"–"4", or undefined).
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
   * Parent epic bead ID (TRD-2026-007).
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
  const isTempTestHome = Boolean(homeDir?.includes("foreman-test-home-") || homeDir?.includes("foreman-no-br-home-"));
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

  // Open local store and mirror key runtime writes into Postgres-backed store.
  const databaseUrl = resolveProjectDatabaseUrl(storeProjectPath);
  const localStore = ForemanStore.forProject(storeProjectPath);
  const registeredProjectId = await resolveRegisteredProjectIdForPath(storeProjectPath, databaseUrl);
  const pgStore = registeredProjectId ? PostgresStore.forProject(registeredProjectId) : undefined;
  const store = pgStore ? createDualWriteStore(localStore, pgStore, true, log) : localStore;
  const registeredReadStore = registeredProjectId && pgStore ? pgStore : undefined;

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

  // Initialize Postgres pool for dual-write mirrors when DATABASE_URL is available.
  if (registeredProjectId && databaseUrl && !isPoolInitialised()) {
    try {
      initPool({ databaseUrl });
    } catch {
      // Non-fatal: dual-write mirrors log their own failures if the pool is unavailable.
    }
  }

  // Create notification client using FOREMAN_NOTIFY_URL (set in env above if provided by dispatcher)
  const notifyClient = new NotificationClient(process.env.FOREMAN_NOTIFY_URL);

  // Create daemon-backed mail client when Postgres is available; fall back to Postgres mail otherwise.
  let agentMailClient: AnyMailClient | null = null;
  try {
    const mailClient = await createProjectMailClient(storeProjectPath);
    mailClient.setRunId(runId);
    agentMailClient = mailClient;
    log(`[agent-mail] Using ${mailClient.constructor.name} (scoped to run ${runId})`);
  } catch {
    // Non-fatal — mail is optional infrastructure
  }

  // Build clean env for SDK
  const env: Record<string, string | undefined> = { ...process.env };

  // ── Pipeline mode: run each phase as a separate SDK session ─────────
  if (pipeline) {
    try {
      await runPipeline(config, store, localStore, logFile, notifyClient, agentMailClient, registeredReadStore, registeredProjectId);
      log(`Pipeline worker exiting for ${taskId}`);
    } finally {
      await runAfterRunHook(config);
      store.close();
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
      progressFlushTail = progressFlushTail.then(() => writeSingleAgentProgress(localStore, registeredReadStore, runId, progress, log));
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
    await writeSingleAgentProgress(localStore, registeredReadStore, runId, progress, log);

    const now = new Date().toISOString();

    if (piResult.success) {
      await updateTerminalRunStatus({
        runId,
        projectId,
        projectPath: storeProjectPath,
        updates: { status: "completed", completed_at: now },
      });
      notifyClient.send({ type: "status", runId, status: "completed", timestamp: now });
      await writeSingleAgentTerminalEvent(localStore, registeredReadStore, projectId, runId, "complete", {
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
      await writeSingleAgentTerminalEvent(localStore, registeredReadStore, projectId, runId, "fail", {
        taskId,
        reason,
        costUsd: progress.costUsd,
        numTurns: progress.turns,
        resumed: !!resume,
      }, log);
      log(`FAILED: ${reason.slice(0, 300)}`);
      // Permanent failure — mark bead as 'failed' so it is NOT auto-retried.
      enqueueMarkBeadFailed(store, taskId, "agent-worker");
    }
  } catch (err: unknown) {
    clearInterval(progressTimer);
    await waitForProgressFlush();
    await writeSingleAgentProgress(localStore, registeredReadStore, runId, progress, log);
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
    await writeSingleAgentTerminalEvent(localStore, registeredReadStore, projectId, runId, isRateLimit ? "stuck" : "fail", {
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
      enqueueResetTaskToOpen(store, taskId, "agent-worker");
    } else {
      enqueueMarkBeadFailed(store, taskId, "agent-worker");
    }
  }

  await runAfterRunHook(config);
  store.close();
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
  store: ForemanStore,
  notifyClient: NotificationClient,
  agentMailClient?: AnyMailClient | null,
  observability?: PhaseObservabilityInput,
  observabilityWriter?: PipelineObservabilityWriter,
): Promise<PhaseResult> {
  const baseRoleConfig = (ROLE_CONFIGS as Record<string, typeof ROLE_CONFIGS.developer | undefined>)[role] ?? ROLE_CONFIGS.developer;
  const roleConfig = config.allowedTools
    ? { ...baseRoleConfig, role: role as typeof baseRoleConfig.role, allowedTools: config.allowedTools }
    : baseRoleConfig;
  // Use the model resolved by the pipeline executor (from workflow YAML + bead priority).
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
  };
  if (agentMailClient) {
    customTools.push(createSendMailTool(agentMailClient, agentName));
    customTools.push(createMailSendTool(agentMailClient, foremanToolContext));
    customTools.push(createMailReadTool(agentMailClient, agentName, foremanToolContext));
  }
  if (role === "explorer" || roleConfig.allowedTools.includes("GraphifyQuery") || roleConfig.allowedTools.includes("GraphifyExplain")) {
    try {
      const result = await ensureGraphifyIndex(config.worktreePath);
      log(`[GRAPHIFY] ${result.command} ready at ${result.graphPath}`);
      await appendFile(logFile, `[GRAPHIFY] ${result.command} ready at ${result.graphPath}\n`);
    } catch (err: unknown) {
      const reason = err instanceof Error ? err.message : String(err);
      log(`[GRAPHIFY] index failed: ${reason.slice(0, 200)}`);
      await appendFile(logFile, `[GRAPHIFY] index failed: ${reason}\n`);
      return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: reason };
    }
    customTools.push(createGraphifyQueryTool(foremanToolContext));
    customTools.push(createGraphifyExplainTool(foremanToolContext));
  }
  customTools.push(createPhaseHandoffTool(agentMailClient ?? null, foremanToolContext));
  customTools.push(createArtifactWriteTool(foremanToolContext));
  customTools.push(createValidationResultTool(foremanToolContext));
  customTools.push(createTaskBlockTool(agentMailClient ?? null, foremanToolContext));
  customTools.push(createProgressUpdateTool(agentMailClient ?? null, foremanToolContext));
  if (role !== "explorer") {
    customTools.push(createSafeCommandRunTool(foremanToolContext));
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
  workflowConfig: import("../lib/workflow-loader.js").WorkflowConfig,
  store: ForemanStore,
  logFile: string,
  notifyClient: NotificationClient,
  agentMailClient: AnyMailClient | null,
  failureContext: string,
  pipelineProjectPath: string,
): Promise<boolean> {
  const onFailure = workflowConfig.onFailure;
  if (!onFailure) return false;

  const { runId, taskId: beadId, taskTitle: beadTitle } = config;
  log(`[TROUBLESHOOTER] Activating for ${beadId} — failure context: ${failureContext.slice(0, 120)}`);

  // Build a basic troubleshooter prompt with failure context injected
  const prompt = [
    `# Troubleshooter Agent`,
    ``,
    `**Bead:** ${beadId} — ${beadTitle}`,
    `**Run ID:** ${runId}`,
    `**Failure Context:**`,
    failureContext,
    ``,
    `Use get_run_status, read artifacts, and apply fixes. Write TROUBLESHOOT_REPORT.md when done.`,
    `Use bead terminology in your notes. Include "RESOLVED" in the report if the failure was fixed, or "ESCALATED" if not.`,
  ].join("\n");

  const roleConfig = ROLE_CONFIGS.troubleshooter;
  const resolvedModel = onFailure.models?.["default"] ?? roleConfig.model;

  const customTools: import("@mariozechner/pi-coding-agent").ToolDefinition[] = [];
  if (agentMailClient) {
    customTools.push(createSendMailTool(agentMailClient, `troubleshooter-${beadId}`));
  }
  customTools.push(createGetRunStatusTool(store));
  customTools.push(createCloseBeadTool(pipelineProjectPath));

  try {
    const result = await runPhaseSession({
      prompt,
      systemPrompt: `You are the troubleshooter agent for Foreman. Your job is to diagnose and fix a pipeline failure for bead: ${beadTitle}`,
      cwd: config.worktreePath,
      model: resolvedModel,
      allowedTools: roleConfig.allowedTools,
      customTools,
      logFile,
      context: {
        phaseName: "troubleshooter",
        runId,
        taskId: beadId,
        taskTitle: beadTitle,
        taskType: config.taskType,
        taskDescription: config.taskDescription,
        worktreePath: config.worktreePath,
        targetBranch: config.targetBranch,
      },
      observability: {
        runId,
        taskId: beadId,
        phase: "troubleshooter",
        phaseType: "prompt",
        model: resolvedModel,
        worktreePath: config.worktreePath,
        rawPrompt: prompt,
        systemPrompt: `You are the troubleshooter agent for Foreman. Your job is to diagnose and fix a pipeline failure for bead: ${beadTitle}`,
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
        log(`[TROUBLESHOOTER] PIPELINE RECOVERED for ${beadId}`);
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

/**
 * Derive fallback refinery options for registered/native run lookups.
 *
 * If registeredProjectId is missing but a database URL exists in the project path,
 * derive a PostgresStore for run lookups. This ensures registered/native runs can
 * be found even when registeredProjectId was not propagated.
 *
 * Error handling: Safely handles the case where the connection pool may not be
 * properly initialized by wrapping PostgresStore.forProject in a try-catch that
 * logs the error and returns undefined instead of throwing.
 */
function deriveFallbackRefineryOptions(
  registeredProjectId: string | undefined,
  registeredReadStore: PostgresStore | undefined,
  pipelineProjectPath: string,
  configProjectId: string,
  log?: (msg: string) => void,
): { registeredProjectId: string; runLookup: PostgresStore } | undefined {
  const fallbackRegisteredProjectId = !registeredProjectId && resolveProjectDatabaseUrl(pipelineProjectPath)
    ? configProjectId
    : undefined;
  const refineryProjectId = registeredProjectId ?? fallbackRegisteredProjectId;

  if (!refineryProjectId) {
    return undefined;
  }

  let fallbackReadStore: PostgresStore | undefined;
  const projectIdForFallback = fallbackRegisteredProjectId ?? registeredProjectId;
  if (!registeredReadStore && projectIdForFallback) {
    try {
      fallbackReadStore = PostgresStore.forProject(projectIdForFallback);
    } catch (err) {
      log?.(`[deriveFallbackRefineryOptions] Failed to create PostgresStore for fallback: ${err instanceof Error ? err.message : String(err)}`);
      return undefined;
    }
  }

  const runLookup = registeredReadStore ?? fallbackReadStore;
  if (!runLookup) {
    return undefined;
  }

  return {
    registeredProjectId: refineryProjectId,
    runLookup,
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

async function runCreatePrBuiltinPhase(args: {
  config: WorkerConfig;
  store: ForemanStore;
  runtimeTaskClient: ITaskClient;
  pipelineProjectPath: string;
  registeredProjectId?: string;
  registeredReadStore?: PostgresStore;
  vcsBackend?: VcsBackend;
  workflowConfig: WorkflowConfig;
  log: (msg: string) => void;
  agentMailClient: AnyMailClient | null;
}): Promise<import("./pipeline-executor.js").PhaseResult> {
  const { config, store, runtimeTaskClient, pipelineProjectPath, registeredProjectId, registeredReadStore, vcsBackend, workflowConfig, log, agentMailClient } = args;

  // Fallback logic mirrors runPipeline: if registeredReadStore is missing but a database
  // URL exists in the project path, derive a PostgresStore for run lookups. This ensures
  // registered/native runs can be found even when registeredProjectId was not propagated.
  const registeredRefineryOptions = deriveFallbackRefineryOptions(
    registeredProjectId,
    registeredReadStore,
    pipelineProjectPath,
    config.projectId,
    log,
  );

  const refinery = new Refinery(
    store,
    runtimeTaskClient,
    pipelineProjectPath,
    vcsBackend,
    registeredRefineryOptions,
  );
  const baseBranch = config.targetBranch ?? await vcsBackend?.detectDefaultBranch(pipelineProjectPath).catch(() => "main") ?? "main";
  const branchName = `foreman/${config.taskId}`;
  const branchHasChanges = await hasChangesAgainstBase(vcsBackend, pipelineProjectPath, baseBranch, branchName).catch(() => true);
  if (!branchHasChanges) {
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
    bodyNote: workflowConfig.merge === "auto"
      ? "Automatically published before PR review and refinery merge."
      : "Published for operator review.",
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
  }, null, 2) + "\n", "utf8");
  log(`[CREATE-PR] PR ready: ${pr.prUrl}`);
  sendMail(agentMailClient, "foreman", "pr-created", {
    taskId: config.taskId,
    runId: config.runId,
    branchName: pr.branchName,
    prUrl: pr.prUrl,
    prNumber,
    strategy: workflowConfig.merge ?? "auto",
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
}): Promise<import("./pipeline-executor.js").PhaseResult> {
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
  const success = finalStatus.checksTerminal && finalStatus.codeRabbitComplete && !finalStatus.mergeConflict;
  return {
    success,
    costUsd: 0,
    turns: 0,
    tokensIn: 0,
    tokensOut: 0,
    error: success
      ? undefined
      : finalStatus.mergeConflict
        ? `PR has merge conflicts: ${finalStatus.mergeConflictReason ?? "unknown"}`
        : finalStatus.checksTerminal
          ? "CodeRabbit review did not complete before timeout"
          : "PR checks did not reach a terminal state before timeout",
    outputText: `checksTerminal=${String(finalStatus.checksTerminal)} codeRabbitSeen=${String(finalStatus.codeRabbitSeen)} codeRabbitComplete=${String(finalStatus.codeRabbitComplete)} mergeConflict=${String(finalStatus.mergeConflict)} timedOut=${String(timedOut)}`,
  };
}

async function runPreparePrReviewBuiltinPhase(args: {
  config: WorkerConfig;
  pipelineProjectPath: string;
  log: (msg: string) => void;
}): Promise<import("./pipeline-executor.js").PhaseResult> {
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
}): Promise<import("./pipeline-executor.js").PhaseResult> {
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
    `- Output:\n\n\`\`\`text\n${truncateFinalizeOutput(args.output) || "(no output)"}\n\`\`\`\n\n` +
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

async function runFinalizeBuiltinPhase(args: {
  config: WorkerConfig;
  pipelineProjectPath: string;
  vcsBackend?: VcsBackend;
  log: (msg: string) => void;
  progress?: RunProgress;
}): Promise<import("./pipeline-executor.js").PhaseResult> {
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
    const test = await runShellForFinalize("npm test -- --reporter=dot", config.worktreePath, 10 * 60_000);
    if (!test.ok) {
      await writeFinalizeValidation({ config, baseBranch, integrationStatus, validationStatus: "FAIL", failureScope: "UNKNOWN", verdict: "FAIL", qaRef, currentRef: currentTargetRef, output: test.output });
      return { success: false, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, error: "finalize_validation_failed", outputText: readFileSync(resolveArtifactPath(config.worktreePath, join(reportDir, "FINALIZE_VALIDATION.md")), "utf8") };
    }
    await writeFinalizeValidation({ config, baseBranch, integrationStatus, validationStatus: "PASS", failureScope: "SKIPPED", verdict: "PASS", qaRef, currentRef: currentTargetRef, output: test.output });
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
  store: ForemanStore;
  pipelineProjectPath: string;
  registeredProjectId?: string;
  registeredReadStore?: PostgresStore;
  vcsBackend?: VcsBackend;
  workflowConfig: WorkflowConfig;
  log: (msg: string) => void;
  agentMailClient: AnyMailClient | null;
}): Promise<import("./pipeline-executor.js").PhaseResult> {
  const { config, store, pipelineProjectPath, registeredProjectId, registeredReadStore, vcsBackend, workflowConfig, log, agentMailClient } = args;
  const mergeStrategy = workflowConfig.merge ?? "auto";
  const prNumber = (() => {
    try { return readPrNumberFromMetadata(config.worktreePath, workerReportDir(config)); } catch { return undefined; }
  })();

  if (mergeStrategy !== "auto") {
    const details = `Workflow merge strategy is ${mergeStrategy}; explicit merge phase skipped auto-merge.`;
    await writeMergeReport({ config, status: "SKIPPED", details, prNumber });
    log(`[MERGE] ${details}`);
    return { success: true, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, outputText: details };
  }

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

  sendMail(agentMailClient, "refinery", "branch-ready", {
    taskId: config.taskId,
    runId: config.runId,
    branch: `foreman/${config.taskId}`,
    worktreePath: config.worktreePath,
  });

  const now = new Date().toISOString();
  await updateTerminalRunStatus({
    runId: config.runId,
    projectId: config.projectId,
    projectPath: pipelineProjectPath,
    updates: { status: "completed", completed_at: now },
  });

  const runtimeTaskClient = await createRuntimeTaskClient(pipelineProjectPath, registeredProjectId);
  const registeredAutoMergeReadStore = registeredProjectId ? registeredReadStore : undefined;
  const currentRun = registeredAutoMergeReadStore
    ? (await registeredAutoMergeReadStore.getRun(config.runId)) ?? undefined
    : store.getRun(config.runId) ?? undefined;
  const mergeResult = await autoMerge({
    store,
    taskClient: runtimeTaskClient,
    projectPath: pipelineProjectPath,
    targetBranch: config.targetBranch,
    ...(registeredAutoMergeReadStore
      ? { registeredProjectId, readLookup: registeredAutoMergeReadStore }
      : {}),
    runId: config.runId,
    ...(currentRun ? { overrideRun: currentRun } : {}),
  });

  const targetMergeResult = mergeResult.target;
  const details = `Immediate merge drain result: merged=${mergeResult.merged}, conflicts=${mergeResult.conflicts}, failed=${mergeResult.failed}`
    + (targetMergeResult
      ? `; target=${targetMergeResult.runId} merged=${targetMergeResult.merged}, conflicts=${targetMergeResult.conflicts}, failed=${targetMergeResult.failed}`
      : "");
  const success = targetMergeResult
    ? targetMergeResult.merged > 0 && targetMergeResult.conflicts === 0 && targetMergeResult.failed === 0
    : mergeResult.merged > 0 && mergeResult.conflicts === 0 && mergeResult.failed === 0;
  await writeMergeReport({
    config,
    status: success ? "SUCCESS" : "FAIL",
    details,
    merged: mergeResult.merged,
    conflicts: mergeResult.conflicts,
    failed: mergeResult.failed,
    prNumber,
  });
  log(`[MERGE] ${details}`);

  return {
    success,
    costUsd: 0,
    turns: 0,
    tokensIn: 0,
    tokensOut: 0,
    error: success ? undefined : details,
    outputText: details,
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
  let sequence = 0;
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
  store: ForemanStore,
  localStore: ForemanStore,
  logFile: string,
  notifyClient: NotificationClient,
  agentMailClient: AnyMailClient | null,
  registeredReadStore?: PostgresStore,
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
  const registeredObservabilityWriter: PipelineObservabilityWriter | undefined = (registeredReadStore || elixirWorkerObservabilityWriter)
    ? {
        async updateProgress(progress) {
          if (!registeredReadStore) return;
          try {
            await registeredReadStore.updateRunProgress(config.runId, progress);
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            log(`[pipeline-observability] progress update failed (non-fatal): ${msg}`);
          }
        },
        async logEvent(eventType, data) {
          try {
            await elixirWorkerObservabilityWriter?.logEvent?.(eventType, data);
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            log(`[pipeline-observability] ${eventType} event append failed (non-fatal): ${msg}`);
          }

          if (eventType === "phase-report") return;
          if (!registeredReadStore || !registeredProjectId) return;
          try {
            await registeredReadStore.logEvent(registeredProjectId, eventType, data, config.runId);
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            log(`[pipeline-observability] ${eventType} projection write failed (non-fatal): ${msg}`);
          }
        },
      }
    : undefined;

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
          await new PostgresAdapter().addTaskNote(registeredProjectId, taskId, {
            runId: config.runId,
            phase: phaseName,
            author: `${phaseName}-${config.taskId}`,
            kind,
            body,
            metadata,
          });
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          log(`[task-note] append failed (non-fatal): ${msg}`);
        }
      },
      epicTasks: config.epicTasks,
      runPhase,
      async runBuiltinPhase(phase: WorkflowPhaseConfig, progress?: RunProgress) {
        try {
          if (phase.name === "create-pr") {
            return await runCreatePrBuiltinPhase({
              config,
              store,
              runtimeTaskClient,
              pipelineProjectPath,
              registeredProjectId,
              registeredReadStore,
              vcsBackend,
              workflowConfig,
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
              store,
              pipelineProjectPath,
              registeredProjectId,
              registeredReadStore,
              vcsBackend,
              workflowConfig,
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
          localStore,
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

    // Epic mode: sync child task bead status into br as the pipeline progresses.
    async onTaskStatusChange(taskTaskId, status) {
      if (status === "in_progress") {
        await runtimeTaskClient.update(taskTaskId, { status: "in_progress" });
        log(`[EPIC] br update ${taskTaskId} → in_progress`);
      } else if (status === "completed") {
        await runtimeTaskClient.close(taskTaskId, "Completed via epic pipeline");
        log(`[EPIC] br close ${taskTaskId} (completed)`);
      } else if (status === "failed") {
        await runtimeTaskClient.update(taskTaskId, { status: "failed" });
        log(`[EPIC] br update ${taskTaskId} → failed`);
      }
    },

    // Epic mode: create a bug bead when QA fails on a child task.
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
      log(`[EPIC] Created bug bead ${bug.id} for QA failure on ${taskTaskId}`);
      return bug.id;
    },

    // Epic mode: close a bug bead when QA passes on retry.
    async onTaskQaPass(bugBeadId) {
      await runtimeTaskClient.close(bugBeadId, "QA passed on retry");
      log(`[EPIC] Closed bug bead ${bugBeadId} (QA passed on retry)`);
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
    async onPipelineComplete({ progress, success, failedPhase: reportedFailedPhase, failureReason: reportedFailureReason }) {

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
        if (registeredProjectId && registeredReadStore) {
          try {
            await registeredReadStore.logEvent(registeredProjectId, eventType, eventData, runId);
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            log(`[PIPELINE] Registered terminal event write failed (non-fatal); falling back to local store: ${msg}`);
            store.logEvent(projectId, eventType, eventData, runId);
          }
        } else {
          store.logEvent(projectId, eventType, eventData, runId);
        }
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
              const beadType = config.taskType ?? "";
              const beadTitle = config.taskTitle ?? "";
              const isVerificationBead = beadType === "test" ||
                /verify|validate|test/i.test(beadTitle);

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
              } else if (isVerificationBead) {
                finalizeSucceeded = true;
                log(`[FINALIZE] nothing_to_commit on verification bead (type="${beadType}", title="${beadTitle}") — treating as success`);
              } else {
                finalizeSucceeded = true;
                log(`[FINALIZE] nothing_to_commit and no commits ahead — work already on target branch, treating as success`);
              }
            }
          } else {
            // No finalize-specific mail — preserve the pipeline success result.
            // A finalize FAIL verdict may not emit phase-complete or agent-error
            // mail, so assuming success here can incorrectly enqueue failed runs
            // to the merge queue and send branch-ready.
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
      const registeredRefineryOptions = deriveFallbackRefineryOptions(
        registeredProjectId,
        registeredReadStore,
        pipelineProjectPath,
        config.projectId,
        log,
      );
      if (finalizeSucceeded) {

        // Mark run as completed BEFORE enqueue/autoMerge — autoMerge looks
        // for completed runs, so this must happen first.
        await updateTerminalRunStatus({
          runId,
          projectId: config.projectId,
          projectPath: pipelineProjectPath,
          updates: { status: "completed", completed_at: now },
        });
        notifyClient.send({ type: "status", runId, status: "completed", timestamp: now });

        let prCreated = hasCreatePrPhase;
        if (hasCreatePrPhase) {
          log(`[PIPELINE] PR creation handled by create-pr phase`);
        } else {
          try {
            const runtimeTaskClient = await createRuntimeTaskClient(pipelineProjectPath, registeredProjectId);
            const refinery = new Refinery(store, runtimeTaskClient, pipelineProjectPath, vcsBackend, registeredRefineryOptions);
            const pr = await refinery.ensurePullRequestForRun({
              runId,
              baseBranch: config.targetBranch,
              updateRunStatus: false,
              bodyNote: workflowConfig.merge === "auto"
                ? "Automatically published before refinery PR merge."
                : "Published by finalize for operator review.",
            });
            prCreated = true;
            log(`[FINALIZE] PR ready: ${pr.prUrl}`);
            sendMail(agentMailClient, "foreman", "pr-created", {
              taskId,
              runId,
              branchName: pr.branchName,
              prUrl: pr.prUrl,
              strategy: workflowConfig.merge ?? "auto",
            });

            if ((workflowConfig.merge ?? "auto") !== "auto") {
              await updateTerminalRunStatus({
                runId,
                projectId: registeredProjectId,
                projectPath: pipelineProjectPath,
                updates: { status: "pr-created", completed_at: now },
              });
              notifyClient.send({ type: "status", runId, status: "pr-created", timestamp: now });
            }
          } catch (prErr: unknown) {
            const prMsg = prErr instanceof Error ? prErr.message : String(prErr);
            log(`[FINALIZE] PR creation failed (will rely on queue/retry path): ${prMsg}`);
          }
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
              enqueueCloseTask(store, taskId, "agent-worker-finalize");
            }
          } catch (alreadyMergedErr: unknown) {
            const alreadyMergedMsg = alreadyMergedErr instanceof Error ? alreadyMergedErr.message : String(alreadyMergedErr);
            log(`[FINALIZE] Unable to verify post-troubleshooter merge state (continuing with merge queue): ${alreadyMergedMsg}`);
          }
        }

        const mergeStrategy = workflowConfig.merge ?? "auto";
        if (!skipMergeQueue && mergeStrategy === "auto") {
          try {
            // Pre-compute modified files via VcsBackend (async) before calling
            // enqueueToMergeQueue which expects a synchronous getFilesModified callback.
            let enqueueFiles: string[] = [];
            try {
              const enqueueBackend = vcsBackend ?? await VcsBackendFactory.create({ backend: "auto" }, worktreePath);
              const enqueueDefaultBranch = await enqueueBackend.detectDefaultBranch(worktreePath);
              enqueueFiles = await enqueueBackend.getChangedFiles(worktreePath, enqueueDefaultBranch, "HEAD");
            } catch {
              // Non-fatal — proceed with empty file list
            }
            const enqueueResult = await enqueueToMergeQueue({
              projectId: config.projectId,
              taskId,
              runId,
              operation: "auto_merge",
              worktreePath,
              getFilesModified: () => enqueueFiles,
            });
            if (enqueueResult.success) {
              log(`[FINALIZE] Enqueued to merge queue`);
              // Guard: Only send branch-ready after successful finalize push (double-check).
              // Primary guard is at function entry, this is defense-in-depth.
              sendMail(agentMailClient, "refinery", "branch-ready", {
                taskId, runId, branch: `foreman/${taskId}`, worktreePath,
              });

              try {
                const runtimeTaskClient = await createRuntimeTaskClient(pipelineProjectPath, registeredProjectId);
                const registeredAutoMergeReadStore = registeredProjectId ? registeredReadStore : undefined;
                const currentRun = registeredAutoMergeReadStore
                  ? (await registeredAutoMergeReadStore.getRun(runId)) ?? undefined
                  : store.getRun(runId) ?? undefined;
                const mergeResult = await autoMerge({
                  store,
                  taskClient: runtimeTaskClient,
                  projectPath: pipelineProjectPath,
                  targetBranch: config.targetBranch,
                  ...(registeredAutoMergeReadStore
                    ? { registeredProjectId, readLookup: registeredAutoMergeReadStore }
                    : {}),
                  runId,
                  ...(currentRun ? { overrideRun: currentRun } : {}),
                });
                log(
                  `[FINALIZE] Immediate merge drain result: merged=${mergeResult.merged}, conflicts=${mergeResult.conflicts}, failed=${mergeResult.failed}`,
                );
              } catch (drainErr: unknown) {
                const drainMsg = drainErr instanceof Error ? drainErr.message : String(drainErr);
                log(`[FINALIZE] Immediate merge drain failed (non-fatal): ${drainMsg}`);
              }
            } else {
              log(`[FINALIZE] Merge queue enqueue failed (non-fatal): ${enqueueResult.error ?? "(unknown)"}`);
            }
          } catch (enqErr: unknown) {
            const enqMsg = enqErr instanceof Error ? enqErr.message : String(enqErr);
            log(`[FINALIZE] Merge queue enqueue failed (non-fatal): ${enqMsg}`);
          }
        } else if (mergeStrategy !== "auto") {
          if (prCreated) {
            log(`[FINALIZE] Workflow merge strategy is ${mergeStrategy} — PR created, skipping merge queue enqueue`);
          } else {
            log(`[FINALIZE] Workflow merge strategy is ${mergeStrategy} but PR was not created — no merge queue enqueue`);
          }
        }
      } else {
        try {
          const runtimeTaskClient = await createRuntimeTaskClient(pipelineProjectPath, registeredProjectId);
          const refinery = new Refinery(store, runtimeTaskClient, pipelineProjectPath, vcsBackend, registeredRefineryOptions);
          const pr = await refinery.ensurePullRequestForRun({
            runId,
            baseBranch: config.targetBranch,
            updateRunStatus: false,
            bodyNote: `Pipeline finished with failure: ${finalizeFailureReason || "unknown error"}`,
            existingOk: true,
          });
          log(`[FINALIZE] Failure PR ready: ${pr.prUrl}`);
          sendMail(agentMailClient, "foreman", "pr-created", {
            taskId,
            runId,
            branchName: pr.branchName,
            prUrl: pr.prUrl,
            strategy: "failure-review",
          });
        } catch (prErr: unknown) {
          const prMsg = prErr instanceof Error ? prErr.message : String(prErr);
          log(`[FINALIZE] Failed to publish PR after finalize failure: ${prMsg}`);
        }

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
              enqueueCloseTask(store, taskId, "agent-worker-finalize");
              log(`[FINALIZE] Pre-existing test failures but branch already matches ${completionTargetBranch} — treating bead as merged`);
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
            enqueueResetTaskToOpen(store, taskId, "agent-worker-finalize");
          } else {
            enqueueMarkBeadFailed(store, taskId, "agent-worker-finalize");
            log(`[PIPELINE] Deterministic finalize failure for ${taskId} — marking failed without retry`);
          }
        }
      }

      const writeFinalizeTerminalEvent = async (
        eventType: "complete" | "stuck" | "fail",
        data: Record<string, unknown>,
      ): Promise<void> => {
        if (registeredProjectId && registeredReadStore) {
          try {
            await registeredReadStore.logEvent(registeredProjectId, eventType, data, runId);
            return;
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            log(`[FINALIZE] Registered terminal event write failed (non-fatal); falling back to local store: ${msg}`);
          }
        }

        store.logEvent(projectId, eventType, data, runId);
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

      // Compatibility read-model event for legacy Postgres/local surfaces.
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
  store: ForemanStore,
  localStore: ForemanStore,
  runId: string,
  projectId: string,
  taskId: string,
  taskTitle: string,
  progress: RunProgress,
  phase: string,
  reason: string,
  projectPath: string,
  notifyClient?: NotificationClient,
  registeredReadStore?: PostgresStore,
): Promise<void> {
  const reasonLower = reason.toLowerCase();
  const isRateLimit = reasonLower.includes("hit your limit") || reasonLower.includes("rate limit");
  const now = new Date().toISOString();
  const stuckStatus = isRateLimit ? "stuck" : "failed";
  await writeMarkStuckProgress(localStore, registeredReadStore, runId, progress, log);
  await updateTerminalRunStatus({
    runId,
    projectId,
    projectPath,
    updates: { status: stuckStatus, completed_at: now },
  });
  notifyClient?.send({ type: "status", runId, status: stuckStatus, timestamp: now, details: { phase, reason } });
  await writeMarkStuckEvent(localStore, registeredReadStore, projectId, runId, isRateLimit ? "stuck" : "fail", {
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
  // Enqueue via the bead write queue instead of calling br directly — the
  // dispatcher drains the queue sequentially, preventing Postgres contention.
  if (isRateLimit) {
    enqueueResetTaskToOpen(store, taskId, "agent-worker-markStuck");
    log(`Enqueued reset-task for ${taskId} (rate limited — will retry on next dispatch)`);
  } else {
    enqueueMarkBeadFailed(store, taskId, "agent-worker-markStuck");
    log(`Enqueued mark-failed for ${taskId} (permanent failure — manual intervention required)`);
  }

  // Add failure reason as a note on the bead for visibility.
  // This allows anyone looking at the bead to see why it failed without
  // having to dig into log files or Postgres.
  const notePrefix = isRateLimit ? "[RATE_LIMITED]" : "[FAILED]";
  const failureNote = `${notePrefix} [${phase.toUpperCase()}] ${reason}`;
  enqueueAddNotesToBead(store, taskId, failureNote, "agent-worker-markStuck");
  if (projectId && taskId) {
    try {
      await new PostgresAdapter().addTaskNote(projectId, taskId, {
        runId,
        phase,
        author: "agent-worker-markStuck",
        kind: "failure",
        body: failureNote,
        metadata: { rateLimit: isRateLimit, costUsd: progress.costUsd },
      });
      log(`Added native failure note for task ${taskId}`);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      log(`[task-note] failure note append failed (non-fatal): ${msg}`);
    }
  }
  log(`Enqueued add-notes for task ${taskId}`);
  // Note: do NOT close store here — the caller (main()) owns the store lifecycle.
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
 * When main() rejects (e.g. config parse failure, ForemanStore.forProject()
 * throws, or runPipeline() propagates an uncaught error), we attempt to:
 *   1. Update the run status to "failed" in Postgres so the run is not left stuck.
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

  // Try to recover enough context to update Postgres + send Agent Mail.
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
    // Repair the fatal run status with the registered backend when available,
    // falling back to local Postgres for unregistered projects.
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

    // Send Postgres mail notification so the run record reflects the fatal error.
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
        // Mail unavailable — Postgres update above is sufficient.
      }
    }
  }

  process.exit(1);
}

main()
  .then(() => process.exit(0))
  .catch(fatalHandler);
