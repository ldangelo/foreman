/**
 * `foreman inbox` — View the Postgres message inbox for agents in a pipeline run.
 *
 * Options:
 *   --agent <name>   Filter to a specific agent/role (default: show all)
 *   --run <id>       Filter to a specific run ID (default: latest run)
 *   --watch          Poll every 2s for new messages, show only new ones
 *   --unread         Show only unread messages
 *   --limit <n>      Max messages to show (default: 50)
 *   --ack            Mark shown messages as read
 */

import { Command } from "commander";
import chalk from "chalk";
import { randomUUID } from "node:crypto";
import { resolve } from "node:path";
import { ForemanStore } from "../../lib/store.js";
import type { Message, Run } from "../../lib/store.js";
import { createTrpcClient } from "../../lib/trpc-client.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { foremanBackendMode } from "../../lib/backend-mode.js";
type AgentMessageRow = Message;
type RunRow = Run;
class BackendInboxAdapter {
  listPipelineEventsForRun(_runId: string, _limit: number): Promise<[]> { return Promise.resolve([]); }
  listProjectPipelineEvents(_projectId: string, _limit: number): Promise<[]> { return Promise.resolve([]); }
  getTask(_projectId: string, _taskId: string): Promise<{ run_id?: string | null } | null> { return Promise.resolve(null); }
  listRuns(_projectId: string, _opts: { limit?: number }): Promise<RunRow[]> { return Promise.resolve([]); }
  getAllMessagesGlobal(_projectId: string, _limit: number): Promise<AgentMessageRow[]> { return Promise.resolve([]); }
  getMessages(_projectId: string, _runId: string, _agent?: string, _unread?: boolean): Promise<AgentMessageRow[]> { return Promise.resolve([]); }
  getAllMessages(_runId: string): Promise<AgentMessageRow[]> { return Promise.resolve([]); }
  markMessageRead(_projectId: string, _messageId: string): Promise<void> { return Promise.resolve(); }
}
import { ElixirServerClient } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { listRegisteredProjects, resolveRepoRootProjectPath, requireProjectOrAllInMultiMode } from "./project-task-support.js";

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

interface DaemonRunRow {
  id: string;
  task_id: string;
  status: string;
  branch: string;
  queued_at: string;
  started_at: string | null;
  finished_at: string | null;
  created_at: string;
}

interface DaemonPipelineEventRow {
  id: string;
  run_id: string | null;
  event_type: string;
  details: string | null;
  created_at: string;
}

type InboxClientContext =
  | { backend: "node"; client: ReturnType<typeof createTrpcClient>; projectId: string }
  | { backend: "elixir"; client: ElixirServerClient; projectId: string };

async function createElixirInboxClient(): Promise<ElixirServerClient> {
  const manager = new ElixirServerManager();
  const status = await manager.ensureRunning();
  return new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN);
}

interface PipelineEvent {
  id: string;
  runId: string | null;
  taskId?: string | null;
  projectId?: string | null;
  eventType: string;
  details: Record<string, unknown> | null;
  createdAt: string;
}

// ── Pipeline event formatting ──────────────────────────────────────────────

const PIPELINE_EVENT_ICONS: Record<string, string> = {
  "phase-start":           "▶",
  "PhaseStarted":          "▶",
  "phase-complete":        "✓",
  "PhaseCompleted":        "✓",
  "PhaseFailed":           "✗",
  "PhaseRetried":          "↻",
  "PhaseSkipped":          "↷",
  "PhaseVerdict":          "◆",
  "PhaseNudged":           "!",
  "phase-nudge":           "!",
  "PhaseReportProduced":   "☰",
  "dispatch":              "→",
  "claim":                 "◈",
  "complete":              "✓",
  "fail":                  "✗",
  "RunFailed":             "✗",
  "WorkerLaunchFailed":    "✗",
  "WorkerProcessExited":   "◼",
  "AssistantMessage":      "✎",
  "ToolCallFinished":      "⚙",
  "merge":                 "⚡",
  "pr-created":            "⎇",
  "merge-queue-enqueue":   "⏳",
  "merge-queue-dequeue":   "▶",
  "merge-queue-resolve":   "✓",
  "merge-queue-fallback":  "⚠",
  "merge-cleanup-fallback":"⚠",
  "WorktreeCreated":       "▣",
  "worktree-created":      "▣",
  "conflict":              "⚠",
  "test-fail":             "✗",
  "stuck":                 "⚠",
};

export function formatPipelineEvent(event: PipelineEvent): string {
  const ts = formatTimestamp(event.createdAt);
  const icon = PIPELINE_EVENT_ICONS[event.eventType] ?? "·";
  const details = normalizedEventDetails(event);
  const taskId = details ? detailString(details, ["task_id", "taskId", "task_id", "taskId"]) : undefined;
  const taskPrefix = taskId ? ` ${taskId}` : "";
  const summary = formatEventSummary(event.eventType, details);
  return `[${ts}]${taskPrefix} ${icon} ${event.eventType} — ${summary}`;
}

function normalizedEventDetails(event: PipelineEvent): Record<string, unknown> | null {
  return event.details ? {
    ...event.details,
    task_id: event.details.task_id ?? event.taskId,
    run_id: event.details.run_id ?? event.runId,
    project_id: event.details.project_id ?? event.projectId,
  } : null;
}

function eventPhase(details: Record<string, unknown> | null): string | undefined {
  return details ? detailString(details, ["phase_id", "phase", "current_phase"]) : undefined;
}

function eventTurns(details: Record<string, unknown> | null): string | undefined {
  return details ? detailString(details, ["numTurns", "num_turns", "turns", "totalTurns", "total_turns"]) : undefined;
}

function eventTask(event: PipelineEvent, details: Record<string, unknown> | null): string | undefined {
  return details ? detailString(details, ["task_id", "taskId", "task_id", "taskId"]) : event.taskId ?? undefined;
}

function eventKind(eventType: string): string {
  switch (eventType) {
    case "RunStarted":
    case "TaskCreated":
    case "WorkerLaunchRequested":
    case "WorktreeCreated":
    case "worktree-created":
    case "PhaseStarted":
    case "phase-start":
    case "dispatch":
    case "claim":
    case "merge-queue-dequeue":
      return "start";
    case "RunCompleted":
    case "TaskUpdated":
    case "PhaseCompleted":
    case "phase-complete":
    case "PhaseReportProduced":
    case "PhaseVerdict":
    case "WorkerProcessExited":
    case "complete":
    case "merge":
    case "Merge":
    case "pr-created":
    case "merge-queue-resolve":
      return "stop";
    case "RunFailed":
    case "WorkerLaunchFailed":
    case "PhaseFailed":
    case "fail":
    case "test-fail":
    case "conflict":
    case "stuck":
      return "error";
    case "PhaseRetried":
      return "retry";
    case "PhaseSkipped":
      return "skip";
    case "ToolCallRequested":
    case "ToolCallApproved":
    case "ToolCallDenied":
    case "ToolCallFinished":
      return "tool";
    case "InboxMessageAppended":
    case "AssistantMessage":
    case "PhaseNudged":
    case "phase-nudge":
      return "mail";
    default:
      return eventType;
  }
}

interface PipelineEventTableRow {
  time: string;
  task: string;
  phase: string;
  turns: string;
  event: string;
  message: string;
}

export function formatPipelineEventTableRow(event: PipelineEvent, messageWidth = 90): PipelineEventTableRow {
  const details = normalizedEventDetails(event);
  return {
    time: formatTimestamp(event.createdAt),
    task: eventTask(event, details) ?? "-",
    phase: eventPhase(details) ?? "-",
    turns: eventTurns(details) ?? "-",
    event: eventKind(event.eventType),
    message: truncate(formatEventSummary(event.eventType, details), messageWidth),
  };
}

function pipelineEventTableWidths(rows: PipelineEventTableRow[], messageWidth = 90) {
  return {
    time: 19,
    task: Math.max(12, ...rows.map((row) => row.task.length)),
    phase: Math.max(10, ...rows.map((row) => row.phase.length)),
    turns: Math.max(5, ...rows.map((row) => row.turns.length)),
    event: Math.max(5, ...rows.map((row) => row.event.length)),
    message: messageWidth,
  };
}

function renderPipelineEventTableRows(rows: PipelineEventTableRow[], widths: ReturnType<typeof pipelineEventTableWidths>): string[] {
  return rows.map((row) => [
    pad(row.time, widths.time),
    pad(row.task, widths.task),
    pad(row.phase, widths.phase),
    pad(row.turns, widths.turns),
    pad(row.event, widths.event),
    pad(row.message, widths.message),
  ].join(" │ "));
}

export function renderPipelineEventsTableRows(events: PipelineEvent[], messageWidth = 90): string {
  const rows = sortEventsChronologically(events).map((event) => formatPipelineEventTableRow(event, messageWidth));
  if (rows.length === 0) return "";
  return renderPipelineEventTableRows(rows, pipelineEventTableWidths(rows, messageWidth)).join("\n");
}

export function renderPipelineEventsTable(events: PipelineEvent[], messageWidth = 90): string {
  const rows = sortEventsChronologically(events).map((event) => formatPipelineEventTableRow(event, messageWidth));
  if (rows.length === 0) return "";
  const widths = pipelineEventTableWidths(rows, messageWidth);
  const header = [
    pad("TIME", widths.time),
    pad("TASK", widths.task),
    pad("PHASE", widths.phase),
    pad("TURNS", widths.turns),
    pad("EVENT", widths.event),
    pad("MESSAGE", widths.message),
  ].join(" │ ");
  const totalWidth = widths.time + widths.task + widths.phase + widths.turns + widths.event + widths.message + 15;
  const hr = "─".repeat(totalWidth);
  const lines = renderPipelineEventTableRows(rows, widths);
  return [hr, header, hr, ...lines, hr].join("\n");
}

export function formatPipelineEventsGrouped(events: PipelineEvent[]): string[] {
  const lines: string[] = [];
  let currentWorkflow = "workflow";
  let currentPhase: string | null = null;

  for (const event of sortEventsChronologically(events)) {
    const details = normalizedEventDetails(event);
    const workflow = details ? detailString(details, ["workflow"]) : undefined;
    const phase = eventPhase(details);

    if (event.eventType === "RunStarted") {
      currentWorkflow = workflow ?? currentWorkflow;
      lines.push(chalk.bold(`workflow: ${currentWorkflow}`));
      continue;
    }

    if (event.eventType === "PhaseStarted" && phase) {
      currentPhase = phase;
      lines.push(chalk.bold(`  phase: ${phase}`));
      lines.push(`    ${formatPipelineEvent(event)}`);
      continue;
    }

    const effectivePhase: string | null = phase ?? currentPhase;
    if (effectivePhase && effectivePhase !== currentPhase) {
      currentPhase = effectivePhase;
      lines.push(chalk.bold(`  phase: ${effectivePhase}`));
    }

    lines.push(`${currentPhase ? "    " : "  "}${formatPipelineEvent(event)}`);
  }

  return lines;
}

interface CompactPhaseSummary {
  started?: string;
  completed?: string;
  failed?: string;
  retryCount: number;
  denials: Map<string, number>;
  tools: Map<string, number>;
}

function compactTaskId(events: PipelineEvent[], messages: Message[], fallback?: string): string {
  for (const event of events) {
    const details = normalizedEventDetails(event);
    const taskId = details ? detailString(details, ["task_id", "taskId", "task_id", "taskId"]) : event.taskId ?? undefined;
    if (taskId) return taskId;
  }
  for (const msg of messages) {
    const taskId = messageTask(msg);
    if (taskId && taskId !== msg.run_id) return taskId;
  }
  return fallback ?? "unknown";
}

function compactPhaseKey(event: PipelineEvent, details: Record<string, unknown> | null): string | undefined {
  return details ? detailString(details, ["phase_id", "phase", "current_phase"]) : undefined;
}

function incrementMap(map: Map<string, number>, key: string): void {
  map.set(key, (map.get(key) ?? 0) + 1);
}

function compactMap(map: Map<string, number>): string {
  return [...map.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .map(([key, count]) => `${key}×${count}`)
    .join(", ");
}

export function formatCompactInboxSummary(input: {
  runId: string;
  taskId?: string | null;
  status?: string | null;
  messages?: Message[];
  events?: PipelineEvent[];
}): string {
  const messages = input.messages ?? [];
  const events = sortEventsChronologically(input.events ?? []);
  const taskId = input.taskId ?? compactTaskId(events, messages, input.runId);
  const phases = new Map<string, CompactPhaseSummary>();
  const notable: string[] = [];
  const notableKeys = new Set<string>();
  const pushNotable = (key: string, line: string): void => {
    if (notableKeys.has(key)) return;
    notableKeys.add(key);
    notable.push(line);
  };

  const phaseSummary = (phase: string): CompactPhaseSummary => {
    const existing = phases.get(phase);
    if (existing) return existing;
    const created: CompactPhaseSummary = { retryCount: 0, denials: new Map(), tools: new Map() };
    phases.set(phase, created);
    return created;
  };

  for (const event of events) {
    const details = normalizedEventDetails(event);
    const phase = compactPhaseKey(event, details);
    const tool = details ? detailString(details, ["tool_name", "toolName"]) : undefined;
    const at = formatTimestamp(event.createdAt);

    if (phase) {
      const summary = phaseSummary(phase);
      if (event.eventType === "PhaseStarted") summary.started = at;
      if (event.eventType === "PhaseCompleted") summary.completed = at;
      if (event.eventType === "PhaseFailed") summary.failed = at;
      if (event.eventType === "PhaseRetried") summary.retryCount += 1;
      if (event.eventType === "ToolCallRequested" && tool) incrementMap(summary.tools, tool);
      if (event.eventType === "ToolCallDenied" && tool) incrementMap(summary.denials, tool);
    }

    if (["RunFailed", "WorkerLaunchFailed", "PhaseFailed", "PhaseNudged", "ToolCallDenied"].includes(event.eventType)) {
      const reason = details ? detailString(details, ["reason", "message", "error"]) : undefined;
      pushNotable(`${event.eventType}:${phase ?? "run"}:${tool ?? ""}:${reason ?? ""}`, formatPipelineEvent(event));
    }
  }

  const mailDenials = new Map<string, number>();
  for (const msg of messages) {
    const row = formatMessageTable(msg, 120);
    if (row.kind === "denied" || row.kind === "error") {
      const key = `${row.receiver}:${row.tool ?? row.kind}`;
      incrementMap(mailDenials, key);
      pushNotable(`mail:${key}:${row.args ?? msg.subject}`, formatInboxMessageLine(msg));
    }
  }

  const lines: string[] = [
    chalk.bold("Compact Inbox"),
    `task=${taskId}  run=${input.runId}  status=${input.status ?? "unknown"}`,
  ];

  if (phases.size > 0) {
    lines.push(chalk.bold("Phases"));
    for (const [phase, summary] of phases) {
      const state = summary.failed ? "failed" : summary.completed ? "done" : summary.started ? "active" : "seen";
      const bits = [`${phase}: ${state}`];
      if (summary.retryCount > 0) bits.push(`retries=${summary.retryCount}`);
      if (summary.tools.size > 0) bits.push(`tools=${compactMap(summary.tools)}`);
      if (summary.denials.size > 0) bits.push(chalk.yellow(`denied=${compactMap(summary.denials)}`));
      lines.push(`- ${bits.join("  ")}`);
    }
  }

  if (mailDenials.size > 0) {
    lines.push(chalk.bold("Mail/Overwatch"));
    lines.push(`- denials=${compactMap(mailDenials)}`);
  }

  if (notable.length > 0) {
    lines.push(chalk.bold("Notable"));
    for (const line of notable.slice(-10)) lines.push(`- ${line}`);
  }

  return lines.join("\n");
}

function detailString(details: Record<string, unknown>, keys: string[]): string | undefined {
  for (const key of keys) {
    const value = details[key];
    if (typeof value === "string" && value.length > 0) return value;
    if (typeof value === "number") return String(value);
  }
  return undefined;
}

export function formatEventSummary(eventType: string, details: Record<string, unknown> | null): string {
  if (!details) return eventType;

  const taskId = detailString(details, ["task_id", "taskId", "task_id", "taskId"]);
  const runId = detailString(details, ["run_id", "runId"]);
  const phase = detailString(details, ["phase_id", "phase", "current_phase"]);
  const status = detailString(details, ["status"]);
  const workflow = detailString(details, ["workflow"]);
  const error = detailString(details, ["error", "reason", "message"]);
  const target = taskId ? `task ${taskId}` : runId ? `run ${runId}` : undefined;

  switch (eventType) {
    case "phase-start":
    case "PhaseStarted":
      return phase ? (target ? `Start ${phase} for ${target}` : `Start: ${phase}`) : target ? `Start phase for ${target}` : eventType;
    case "phase-complete":
    case "PhaseCompleted":
      return phase ? (target ? `Complete ${phase} for ${target}${status ? ` → ${status}` : ""}` : `Complete: ${phase}${status ? ` → ${status}` : ""}`) : target ? `Complete phase for ${target}` : eventType;
    case "PhaseFailed":
      return phase ? `Failed ${phase}${target ? ` for ${target}` : ""}${error ? `: ${error}` : ""}` : target ? `Failed phase for ${target}` : eventType;
    case "PhaseRetried": {
      const retryTarget = detailString(details, ["retry_target", "retryTarget"]);
      const attempt = detailString(details, ["attempt"]);
      const max = detailString(details, ["max_retries", "maxRetries"]);
      const retryText = attempt && max ? ` (${attempt}/${max})` : "";
      return phase ? `Retry ${phase}${retryTarget ? ` via ${retryTarget}` : ""}${retryText}${target ? ` for ${target}` : ""}${error ? `: ${error}` : ""}` : eventType;
    }
    case "PhaseSkipped":
      return phase ? `Skipped ${phase}${target ? ` for ${target}` : ""}${error ? `: ${error}` : ""}` : eventType;
    case "PhaseVerdict": {
      const verdict = detailString(details, ["verdict"]);
      return phase ? `${phase} verdict${verdict ? `: ${verdict}` : ""}${target ? ` for ${target}` : ""}` : eventType;
    }
    case "PhaseNudged":
    case "phase-nudge": {
      const recipient = detailString(details, ["recipient"]);
      return phase ? `Overwatch nudged ${phase}${target ? ` for ${target}` : ""}${recipient ? ` → ${recipient}` : ""}${error ? `: ${error}` : ""}` : eventType;
    }
    case "PhaseReportProduced": {
      const outcome = detailString(details, ["outcome", "status"]);
      const nextPhase = detailString(details, ["next_phase", "nextPhase", "retry_target", "retryTarget"]);
      const verdict = detailString(details, ["verdict"]);
      return phase ? `Report ${phase}${target ? ` for ${target}` : ""}${outcome ? ` → ${outcome}` : ""}${verdict ? ` (${verdict})` : ""}${nextPhase ? `; steer ${nextPhase}` : ""}` : eventType;
    }
    case "RunStarted":
      return `Started${target ? ` ${target}` : ""}${workflow ? ` (${workflow})` : ""}`;
    case "TaskCreated":
      return `Created${target ? ` ${target}` : ""}${status ? ` → ${status}` : ""}`;
    case "TaskUpdated":
      return `Updated${target ? ` ${target}` : ""}${status ? ` → ${status}` : ""}${runId ? ` (run ${runId})` : ""}`;
    case "TaskAnnotated":
      return `Note added${target ? ` to ${target}` : ""}`;
    case "WorkerLaunchRequested":
      return `Worker launch requested${target ? ` for ${target}` : ""}${workflow ? ` (${workflow})` : ""}${runId ? ` (run ${runId})` : ""}`;
    case "WorktreeCreated":
    case "worktree-created": {
      const branch = detailString(details, ["branchName", "branch_name"]);
      const path = detailString(details, ["worktreePath", "worktree_path"]);
      return `Worktree created${target ? ` for ${target}` : ""}${branch ? ` (${branch})` : ""}${path ? ` at ${path}` : ""}`;
    }
    case "WorkerLaunchFailed":
      return `Worker launch failed${target ? ` for ${target}` : ""}${error ? `: ${error}` : ""}`;
    case "WorkerProcessExited": {
      const exitCode = detailString(details, ["exit_code", "exitCode"]);
      return `Worker process exited${target ? ` for ${target}` : ""}${exitCode ? ` (exit ${exitCode})` : ""}`;
    }
    case "AssistantMessage": {
      const phase = detailString(details, ["phase", "phase_id"]);
      const body = detailString(details, ["message", "output"]);
      return `Assistant message${phase ? ` in ${phase}` : ""}${body ? `: ${body.slice(0, 120)}${body.length > 120 ? "…" : ""}` : ""}`;
    }
    case "ToolCallRequested": {
      const tool = detailString(details, ["tool_name", "toolName"]) || "tool";
      const phase = detailString(details, ["phase", "phase_id"]);
      const path = detailString(details, ["path", "file_path", "filePath"]);
      const args = details.args && typeof details.args === "object" ? details.args as Record<string, unknown> : undefined;
      const argPath = args ? detailString(args, ["path", "file_path", "filePath", "command", "query"]) : undefined;
      return `Tool ${tool} requested${phase ? ` in ${phase}` : ""}${path || argPath ? `: ${truncate(path || argPath || "", 80)}` : ""}`;
    }
    case "ToolCallApproved": {
      const tool = detailString(details, ["tool_name", "toolName"]) || "tool";
      const phase = detailString(details, ["phase", "phase_id"]);
      return `Tool ${tool} approved${phase ? ` in ${phase}` : ""}`;
    }
    case "ToolCallDenied": {
      const tool = detailString(details, ["tool_name", "toolName"]) || "tool";
      const phase = detailString(details, ["phase", "phase_id"]);
      const reason = detailString(details, ["reason", "message", "error"]);
      return `Tool ${tool} denied${phase ? ` in ${phase}` : ""}${reason ? `: ${reason}` : ""}`;
    }
    case "ToolCallFinished": {
      const tool = detailString(details, ["tool_name", "toolName"]) || "tool";
      const status = detailString(details, ["status"]);
      const phase = detailString(details, ["phase", "phase_id"]);
      return `Tool ${tool}${status ? ` ${status}` : " finished"}${phase ? ` in ${phase}` : ""}`;
    }
    case "RunFailed":
      return `Failed${target ? ` ${target}` : ""}${phase ? ` at ${phase}` : ""}${error ? `: ${error}` : ""}`;
    case "dispatch":
      return taskId ? `Dispatch: ${taskId}` : "Dispatch";
    case "complete":
      return taskId ? `Complete: ${taskId}` : "Complete";
    case "fail":
      return taskId ? `Failed: ${taskId}` : "Failed";
    case "merge":
    case "Merge":
      return taskId ? `Merged: ${taskId}` : "Merged";
    case "pr-created":
      return details.pr_number ? `PR #${details.pr_number} created` : "PR created";
    case "merge-queue-enqueue":
    case "merge-queue-dequeue":
    case "merge-queue-resolve":
    case "merge-queue-fallback":
    case "merge-cleanup-fallback":
      return taskId ? `${eventType}: ${taskId}` : eventType;
    case "conflict":
    case "test-fail":
      return taskId ? `${eventType}: ${taskId}` : eventType;
    case "stuck":
      return taskId ? `Stuck: ${taskId}` : "Stuck";
    default:
      return taskId ? `${eventType}: ${taskId}` : runId ? `${eventType}: ${runId}` : eventType;
  }
}

export function adaptPostgresEvent(row: { id: string; run_id: string | null; task_id?: string | null; project_id?: string | null; event_type: string; payload: unknown; created_at: string | Date }): PipelineEvent {
  const payload = typeof row.payload === "string"
    ? JSON.parse(row.payload)
    : row.payload;
  return {
    id: row.id,
    runId: row.run_id,
    taskId: row.task_id,
    projectId: row.project_id,
    eventType: row.event_type,
    details: payload && typeof payload === "object" ? payload as Record<string, unknown> : null,
    createdAt: row.created_at instanceof Date ? row.created_at.toISOString() : row.created_at,
  };
}

export async function fetchPostgresEvents(
  adapter: BackendInboxAdapter,
  projectId: string,
  options: { all?: boolean; runId?: string; limit: number },
): Promise<PipelineEvent[]> {
  const rows = options.runId
    ? await adapter.listPipelineEventsForRun(options.runId, options.limit)
    : options.all
      ? await adapter.listProjectPipelineEvents(projectId, options.limit)
      : [];
  return rows.map(adaptPostgresEvent);
}

export function sortEventsChronologically(events: PipelineEvent[]): PipelineEvent[] {
  return [...events].sort((a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime());
}

export function selectUnseenEvents(events: PipelineEvent[], seenIds: Set<string>): PipelineEvent[] {
  return sortEventsChronologically(events.filter((event) => !seenIds.has(event.id)));
}

export async function fetchDaemonEvents(
  daemon: InboxClientContext,
  options: { all?: boolean; runId?: string; limit: number },
): Promise<PipelineEvent[]> {
  if (daemon.backend === "elixir") {
    const rows = await daemon.client.listEvents({
      projectId: daemon.projectId,
      runId: options.all ? undefined : options.runId,
      limit: 1000,
    });
    return rows
      .map((row) => {
        const payload = row.payload && typeof row.payload === "object" ? row.payload as Record<string, unknown> : null;
        const nestedDetails = payload?.details && typeof payload.details === "object" ? payload.details as Record<string, unknown> : null;
        return {
          id: String(row.event_id ?? `${row.run_id ?? "run"}-${row.event_type ?? row.type ?? "event"}`),
          runId: row.run_id ? String(row.run_id) : null,
          taskId: row.task_id ? String(row.task_id) : null,
          projectId: row.project_id ? String(row.project_id) : null,
          eventType: String(row.event_type ?? row.type ?? "event"),
          details: payload ? { ...payload, ...(nestedDetails ?? {}) } : null,
          createdAt: String(row.occurred_at ?? row.created_at ?? new Date().toISOString()),
        };
      })
      .sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime())
      .slice(0, options.limit);
  }

  if (options.all) {
    const runs = await daemon.client.runs.list({ projectId: daemon.projectId, limit: 100 }) as DaemonRunRow[];
    const eventLists = await Promise.all(
      runs.map((run) => daemon.client.runs.listEvents({ runId: run.id }) as Promise<DaemonPipelineEventRow[]>),
    );
    return eventLists
      .flat()
      .map((row) => ({
        id: row.id,
        runId: row.run_id,
        eventType: row.event_type,
        details: row.details ? JSON.parse(row.details) : null,
        createdAt: row.created_at,
      }))
      .sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime())
      .slice(0, options.limit);
  }
  if (!options.runId) return [];
  const rows = await daemon.client.runs.listEvents({ runId: options.runId }) as DaemonPipelineEventRow[];
  return rows
    .map((row) => ({
      id: row.id,
      runId: row.run_id,
      eventType: row.event_type,
      details: row.details ? JSON.parse(row.details) : null,
      createdAt: row.created_at,
    }))
    .sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime())
    .slice(0, options.limit);
}

// ── Formatting helpers ────────────────────────────────────────────────────────

/**
 * Get the terminal width for output wrapping.
 * Falls back to 80 columns when stdout is not a TTY.
 */
export function getTerminalWidth(): number {
  return process.stdout.columns || 80;
}

/**
 * Wrap text to fit within a maximum width, breaking at word boundaries.
 * Preserves existing newlines and indents continuation lines.
 */
export function wrapText(text: string, maxWidth: number): string {
  const lines = text.split("\n");
  return lines
    .map((line) => {
      if (line.length <= maxWidth) return line;
      // Word wrap: break at maxWidth, then continue at indent
      let result = "";
      let remaining = line;
      while (remaining.length > maxWidth) {
        // Find last space before maxWidth
        const slice = remaining.slice(0, maxWidth);
        const lastSpace = slice.lastIndexOf(" ");
        if (lastSpace > 0) {
          result += slice.slice(0, lastSpace) + "\n";
          remaining = remaining.slice(lastSpace + 1);
        } else {
          // No space found, force break
          result += slice + "\n";
          remaining = remaining.slice(maxWidth);
        }
      }
      return result + remaining;
    })
    .join("\n");
}

function formatTimestamp(isoStr: string): string {
  try {
    const d = new Date(isoStr);
    const pad = (n: number): string => String(n).padStart(2, "0");
    return (
      `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
      `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
    );
  } catch {
    return isoStr;
  }
}

function formatMessage(msg: Message, fullPayload = false): string {
  const ts = formatTimestamp(msg.created_at);
  const readMark = msg.read === 1 ? " [read]" : "";
  const header = `[${ts}] ${msg.sender_agent_type} → ${msg.recipient_agent_type}  |  ${msg.subject}${readMark}`;

  if (fullPayload) {
    // Show full body — try to pretty-print JSON, otherwise show raw
    let bodyDisplay: string;
    try {
      const parsed = JSON.parse(msg.body);
      bodyDisplay = JSON.stringify(parsed, null, 2);
    } catch {
      bodyDisplay = msg.body;
    }
    // Wrap at terminal width to prevent line clipping on long JSON payloads
    const terminalWidth = getTerminalWidth();
    const wrappedBody = wrapText(bodyDisplay, terminalWidth - 2); // -2 for indentation
    return `${header}\n${wrappedBody.split("\n").map((l) => `  ${l}`).join("\n")}`;
  }

  // Default: try to parse JSON and show key fields for readability
  let preview: string;
  try {
    const parsed = JSON.parse(msg.body) as Record<string, unknown>;
    const parts: string[] = [];
    if (typeof parsed["phase"] === "string") parts.push(`phase=${parsed["phase"]}`);
    if (typeof parsed["status"] === "string") parts.push(`status=${parsed["status"]}`);
    if (typeof parsed["error"] === "string") parts.push(`error=${parsed["error"]}`);
    if (typeof parsed["currentPhase"] === "string") parts.push(`currentPhase=${parsed["currentPhase"]}`);
    if (typeof parsed["taskId"] === "string") parts.push(`taskId=${parsed["taskId"]}`);
    if (typeof parsed["runId"] === "string") parts.push(`runId=${parsed["runId"]}`);
    if (typeof parsed["message"] === "string") parts.push(`message=${parsed["message"]}`);
    if (typeof parsed["kind"] === "string") parts.push(`kind=${parsed["kind"]}`);
    if (typeof parsed["tool"] === "string") parts.push(`tool=${parsed["tool"]}`);
    if (typeof parsed["argsPreview"] === "string") parts.push(`args=${parsed["argsPreview"]}`);
    if (typeof parsed["traceFile"] === "string") parts.push(`trace=${parsed["traceFile"]}`);
    if (typeof parsed["commandHonored"] === "boolean") parts.push(`commandHonored=${parsed["commandHonored"] ? "yes" : "no"}`);
    if (typeof parsed["verdict"] === "string") parts.push(`verdict=${parsed["verdict"]}`);
    if (parts.length > 0) {
      preview = parts.join(", ");
    } else {
      // No recognized fields — fall back to truncated raw body
      preview = msg.body.slice(0, 200).replace(/\n/g, " ");
      if (msg.body.length > 200) preview += "...";
    }
  } catch {
    // Not JSON — truncate with ellipsis
    preview = msg.body.slice(0, 200).replace(/\n/g, " ");
    if (msg.body.length > 200) preview += "...";
  }

  return `${header}\n  ${preview}`;
}

// ── Table row type ────────────────────────────────────────────────────────────

export interface TableRow {
  date: string;
  ticket: string;
  sender: string;
  receiver: string;
  kind: string | undefined;
  tool: string | undefined;
  args: string | undefined;
  runId: string;
  isRead: boolean;
}

// ── Parsed message body ──────────────────────────────────────────────────────

interface ParsedMessageBody {
  phase?: string;
  status?: string;
  error?: string;
  currentPhase?: string;
  taskId?: string;
  runId?: string;
  message?: string;
  kind?: string;
  tool?: string;
  args?: string;
  argsPreview?: string;
  traceFile?: string;
  commandHonored?: boolean;
  verdict?: string;
  body?: string;
}

/**
 * Parse the message body JSON, extracting structured fields when present.
 * Gracefully degrades on non-JSON or missing fields.
 */
export function parseMessageBody(body: string): ParsedMessageBody {
  if (!body) return {};
  try {
    const parsed = JSON.parse(body) as Record<string, unknown>;
    return {
      phase: typeof parsed["phase"] === "string" ? parsed["phase"] : undefined,
      status: typeof parsed["status"] === "string" ? parsed["status"] : undefined,
      error: typeof parsed["error"] === "string" ? parsed["error"] : undefined,
      currentPhase: typeof parsed["currentPhase"] === "string" ? parsed["currentPhase"] : undefined,
      taskId: typeof parsed["taskId"] === "string" ? parsed["taskId"] : undefined,
      runId: typeof parsed["runId"] === "string" ? parsed["runId"] : undefined,
      message: typeof parsed["message"] === "string" ? parsed["message"] : undefined,
      kind: typeof parsed["kind"] === "string" ? parsed["kind"] : undefined,
      tool: typeof parsed["tool"] === "string" ? parsed["tool"] : undefined,
      argsPreview: typeof parsed["argsPreview"] === "string" ? parsed["argsPreview"] : undefined,
      traceFile: typeof parsed["traceFile"] === "string" ? parsed["traceFile"] : undefined,
      commandHonored: typeof parsed["commandHonored"] === "boolean" ? parsed["commandHonored"] : undefined,
      verdict: typeof parsed["verdict"] === "string" ? parsed["verdict"] : undefined,
      body: typeof parsed["body"] === "string" ? parsed["body"] : undefined,
    };
  } catch {
    return {};
  }
}

/**
 * Truncate a string to maxLen characters, appending "…" if truncated.
 */
export function truncate(str: string, maxLen: number): string {
  if (maxLen <= 0) return "";
  if (str.length <= maxLen) return str;
  if (maxLen === 1) return "…";
  if (maxLen <= 3) return "…";

  const slice = str.slice(0, maxLen);
  const lastSpace = slice.lastIndexOf(" ");
  if (lastSpace >= maxLen - 4) {
    return str.slice(0, lastSpace) + "…";
  }

  return str.slice(0, maxLen - 1) + "…";
}

// ── Table formatting ───────────────────────────────────────────────────────────

const DEFAULT_ARGS_WIDTH = 40;

/**
 * Format a message as a table row.
 * @param msg The message to format
 * @param argsMaxLen Maximum length for the args column (default: 40)
 */
export function formatMessageTable(msg: Message, argsMaxLen = DEFAULT_ARGS_WIDTH): TableRow {
  const parsed = parseMessageBody(msg.body);
  const bodyPreview = msg.body ? msg.body.replace(/\n/g, " ") : undefined;
  const plainToolMatch = bodyPreview?.match(/^Tool\s+(\S+)\s+(denied|approved|requested|finished|error)\b/i);
  const argsPreview = parsed.argsPreview ?? parsed.message ?? parsed.body ?? bodyPreview;
  return {
    date: formatTimestamp(msg.created_at),
    ticket: messageTask(msg),
    sender: msg.sender_agent_type,
    receiver: msg.recipient_agent_type,
    kind: parsed.kind ?? plainToolMatch?.[2]?.toLowerCase(),
    tool: parsed.tool ?? plainToolMatch?.[1]?.toLowerCase(),
    args: argsPreview ? truncate(argsPreview, argsMaxLen) : undefined,
    runId: msg.run_id,
    isRead: msg.read === 1,
  };
}

export function formatInboxMessageLine(msg: Message): string {
  const row = formatMessageTable(msg, 140);
  const icon = row.kind === "denied" || row.kind === "error" ? "!" : "✉";
  const route = `${msg.sender_agent_type} → ${msg.recipient_agent_type}`;
  const tool = row.tool ? ` ${row.tool}` : "";
  const kind = row.kind ? ` ${row.kind}` : "";
  const summary = row.args ?? msg.subject;
  return `[${row.date}] ${row.ticket} ${icon} Mail${kind}${tool} — ${route}: ${summary}`;
}

// ── ASCII table renderer ───────────────────────────────────────────────────────

/**
 * Column widths for the inbox table.
 * Compact sortable datetime | run/task | sender | receiver | kind | tool | args
 */
const COL_WIDTHS = {
  date: 19,    // "2026-04-30 14:23:45"
  ticket: 20,
  sender: 12,
  receiver: 12,
  kind: 14,
  tool: 14,
} as const;
const ARGS_DEFAULT = 40;

interface ColumnSizes {
  date: number;
  ticket: number;
  sender: number;
  receiver: number;
  kind: number;
  tool: number;
  args: number;
}

/**
 * Render an array of table rows as a formatted ASCII table.
 * @param rows TableRow[] to render
 * @param argsWidth override for the args column width (default 40)
 */
export function renderMessageTable(rows: TableRow[], argsWidth = ARGS_DEFAULT): string {
  if (rows.length === 0) return "";

  const sizes: ColumnSizes = {
    date: COL_WIDTHS.date,
    ticket: Math.max(...rows.map((r) => r.ticket.length), COL_WIDTHS.ticket),
    sender: Math.max(...rows.map((r) => r.sender.length), COL_WIDTHS.sender),
    receiver: Math.max(...rows.map((r) => r.receiver.length), COL_WIDTHS.receiver),
    kind: Math.max(...rows.map((r) => r.kind?.length ?? 4), COL_WIDTHS.kind),
    tool: Math.max(...rows.map((r) => r.tool?.length ?? 4), COL_WIDTHS.tool),
    args: argsWidth,
  };

  const totalWidth =
    sizes.date + sizes.ticket + sizes.sender + sizes.receiver +
    sizes.kind + sizes.tool + sizes.args + 8;

  const hr = "─".repeat(totalWidth);

  const header = [
    pad("DATE", sizes.date),
    pad("TASK", sizes.ticket),
    pad("SENDER", sizes.sender),
    pad("RECEIVER", sizes.receiver),
    pad("KIND", sizes.kind),
    pad("TOOL", sizes.tool),
    pad("ARGS", sizes.args),
  ].join(" │ ");

  const padCell = (val: string | undefined, width: number): string =>
    pad(val ?? "-", width);

  const tableLines = rows.map((row) =>
    [
      pad(row.date, sizes.date),
      pad(row.ticket, sizes.ticket),
      pad(row.sender, sizes.sender),
      pad(row.receiver, sizes.receiver),
      padCell(row.kind, sizes.kind),
      padCell(row.tool, sizes.tool),
      padCell(row.args, sizes.args),
    ].join(" │ ")
  );

  return [hr, header, hr, ...tableLines, hr].join("\n");
}

function pad(val: string, width: number): string {
  if (val.length > width) return val.slice(0, width - 1) + "…";
  return val.padEnd(width, " ");
}

// ── TableFormatter (tabular message view) ────────────────────────────────────

/**
 * Extract structured fields from a JSON message body for the newer table view.
 * Returns nulls for missing fields and falls back through
 * argsPreview → message → body for ARGS.
 */
export function extractBodyFields(body: string): {
  kind: string | null;
  tool: string | null;
  args: string | null;
} {
  const parsed = parseMessageBody(body);
  const plainToolMatch = body.match(/^Tool\s+(\S+)\s+(denied|approved|requested|finished|error)\b/i);
  return {
    kind: parsed.kind ?? plainToolMatch?.[2]?.toLowerCase() ?? null,
    tool: parsed.tool ?? plainToolMatch?.[1]?.toLowerCase() ?? null,
    args: parsed.argsPreview ?? parsed.message ?? parsed.body ?? (body ? body : null),
  };
}

interface TableColumns {
  datetime: string;
  ticket: string;
  sender: string;
  receiver: string;
  kind: string;
  tool: string;
  args: string;
}

interface FormattedRow {
  columns: TableColumns;
  raw: Message;
}

/**
 * Formats inbox messages as a space-aligned table with columns:
 * DATETIME | TASK | SENDER | RECEIVER | KIND | TOOL | ARGS
 */
export class TableFormatter {
  private readonly terminalWidth: number;

  constructor({ terminalWidth }: { terminalWidth: number }) {
    this.terminalWidth = terminalWidth;
  }

  private formatDatetime(isoStr: string): string {
    return formatTimestamp(isoStr);
  }

  private middleCutTicket(id: string): string {
    const MAX = 20;
    if (id.length <= MAX) return id;
    const prefix = id.slice(0, 7);
    const suffix = id.slice(id.length - (MAX - 7 - 1));
    return `${prefix}…${suffix}`;
  }

  formatRow(msg: Message): FormattedRow {
    const { kind, tool, args } = extractBodyFields(msg.body);
    const dash = "—";
    const argsMax = 30;

    return {
      columns: {
        datetime: this.formatDatetime(msg.created_at),
        ticket: this.middleCutTicket(messageTask(msg)),
        sender: msg.sender_agent_type,
        receiver: msg.recipient_agent_type,
        kind: kind ?? dash,
        tool: tool ?? dash,
        args: truncate(args ?? dash, argsMax),
      },
      raw: msg,
    };
  }

  calcWidths(messages: Message[]): {
    datetime: number;
    ticket: number;
    sender: number;
    receiver: number;
    kind: number;
    tool: number;
    args: number;
  } {
    const rows = messages.map((m) => this.formatRow(m));
    const base = { datetime: 19, ticket: 8, sender: 8, receiver: 8, kind: 4, tool: 4, args: 4 };

    const computed = {
      datetime: Math.max(base.datetime, ...rows.map((r) => r.columns.datetime.length)),
      ticket: Math.max(base.ticket, ...rows.map((r) => r.columns.ticket.length)),
      sender: Math.max(base.sender, ...rows.map((r) => r.columns.sender.length)),
      receiver: Math.max(base.receiver, ...rows.map((r) => r.columns.receiver.length)),
      kind: Math.max(base.kind, ...rows.map((r) => r.columns.kind.length)),
      tool: Math.max(base.tool, ...rows.map((r) => r.columns.tool.length)),
      args: Math.max(base.args, ...rows.map((r) => r.columns.args.length)),
    };

    computed.ticket = Math.min(computed.ticket, 20);
    computed.datetime = 19;
    computed.sender = Math.min(Math.max(computed.sender, 8), 15);
    computed.receiver = Math.min(Math.max(computed.receiver, 8), 15);
    computed.kind = Math.min(computed.kind, 12);
    computed.tool = Math.min(computed.tool, 12);

    const fixed =
      computed.datetime +
      computed.ticket +
      computed.sender +
      computed.receiver +
      computed.kind +
      computed.tool +
      6;
    const available = this.terminalWidth - fixed;
    computed.args = Math.max(computed.args, Math.min(available, 80));

    return computed;
  }

  formatHeader(): string {
    return "DATETIME          TASK        SENDER     RECEIVER   KIND       TOOL       ARGS";
  }

  private formatSeparator(widths: ReturnType<typeof this.calcWidths>): string {
    const { datetime, ticket, sender, receiver, kind, tool, args } = widths;
    return (
      `${"─".repeat(datetime)} ` +
      `${"─".repeat(ticket)} ` +
      `${"─".repeat(sender)} ` +
      `${"─".repeat(receiver)} ` +
      `${"─".repeat(kind)} ` +
      `${"─".repeat(tool)} ` +
      `${"─".repeat(args)}`
    );
  }

  private formatRowLine(
    row: FormattedRow,
    widths: ReturnType<typeof this.calcWidths>,
  ): string {
    const { datetime, ticket, sender, receiver, kind, tool, args } = widths;
    return (
      row.columns.datetime.padEnd(datetime) +
      " " +
      row.columns.ticket.padEnd(ticket) +
      " " +
      row.columns.sender.padEnd(sender) +
      " " +
      row.columns.receiver.padEnd(receiver) +
      " " +
      row.columns.kind.padEnd(kind) +
      " " +
      row.columns.tool.padEnd(tool) +
      " " +
      row.columns.args.padEnd(args)
    );
  }

  formatTable(messages: Message[]): string {
    if (messages.length === 0) {
      return this.formatHeader() + "\n";
    }

    const rows = messages.map((m) => this.formatRow(m));
    const widths = this.calcWidths(messages);

    return [
      this.formatHeader(),
      this.formatSeparator(widths),
      ...rows.map((r) => this.formatRowLine(r, widths)),
    ].join("\n") + "\n";
  }
}

// ── Run status formatting ─────────────────────────────────────────────────────

function formatRunStatus(run: Run): string {
  const ts = formatTimestamp(new Date().toISOString());
  let statusStr: string;
  if (run.status === "completed") {
    statusStr = chalk.green("COMPLETED");
  } else if (run.status === "failed") {
    statusStr = chalk.red("FAILED");
  } else if (run.status === "running") {
    statusStr = chalk.blue("RUNNING");
  } else {
    statusStr = chalk.yellow(run.status.toUpperCase());
  }
  return `[${ts}] ${chalk.bold("●")} ${run.task_id} ${statusStr} (run ${run.id})`;
}

export function adaptDaemonMessage(row: DaemonMailMessage): Message {
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

function phaseFromSender(sender: string): string | undefined {
  const match = sender.match(/^(explorer|developer|qa|reviewer|finalize|refinery)(?:-|$)/);
  return match?.[1];
}

function messagePhase(msg: Message): string | undefined {
  return parseMessageBody(msg.body).phase ?? phaseFromSender(msg.sender_agent_type);
}

function messageTask(msg: Message): string {
  const projectedTaskId = (msg as Message & { task_id?: string | null }).task_id;
  return parseMessageBody(msg.body).taskId ?? projectedTaskId ?? msg.run_id;
}

function messageActivity(msg: Message): string {
  const parsed = parseMessageBody(msg.body);
  const parts: string[] = [];
  if (parsed.phase ?? phaseFromSender(msg.sender_agent_type)) parts.push(`phase=${parsed.phase ?? phaseFromSender(msg.sender_agent_type)}`);
  if (parsed.kind) parts.push(`kind=${parsed.kind}`);
  if (parsed.status) parts.push(`status=${parsed.status}`);
  if (parsed.verdict) parts.push(`verdict=${parsed.verdict}`);
  if (parsed.tool) parts.push(`tool=${parsed.tool}`);
  if (parsed.commandHonored !== undefined) parts.push(`honored=${parsed.commandHonored ? "yes" : "no"}`);
  if (parsed.error) parts.push(`error=${parsed.error}`);
  if (parsed.message && !parsed.error) parts.push(parsed.message);
  return parts.length > 0 ? parts.join(" ") : msg.subject;
}

function messageArgs(msg: Message): string | null {
  const parsed = parseMessageBody(msg.body);
  return parsed.argsPreview ?? parsed.body ?? parsed.message ?? null;
}

function renderRunProgressSummary(messages: Message[], runs: Run[]): string {
  if (messages.length === 0 && runs.length === 0) return "";

  const byRun = new Map<string, Message[]>();
  for (const msg of messages) {
    const list = byRun.get(msg.run_id) ?? [];
    list.push(msg);
    byRun.set(msg.run_id, list);
  }

  const runById = new Map(runs.map((run) => [run.id, run]));
  const activeRunIds = runs
    .filter((run) => run.status === "pending" || run.status === "running")
    .map((run) => run.id);
  const runIds = new Set<string>([...messages.map((msg) => msg.run_id), ...activeRunIds]);
  const lines: string[] = [chalk.bold("Run Summary")];
  for (const runId of runIds) {
    const list = (byRun.get(runId) ?? []).sort((a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime());
    const run = runById.get(runId);
    const latest = list[list.length - 1];
    const latestError = [...list].reverse().find((msg) => msg.subject === "agent-error" || parseMessageBody(msg.body).error);
    const phase = latest ? messagePhase(latest) : undefined;
    const parsedLatest = latest ? parseMessageBody(latest.body) : {};
    const task = run?.task_id ?? (latest ? messageTask(latest) : runId);
    const status = run?.status ?? "unknown";
    const stage = phase
      ? `${phase}${parsedLatest.kind ? `:${parsedLatest.kind}` : ""}`
      : "unknown";
    const lastAt = latest ? formatTimestamp(latest.created_at) : "—";
    const error = latestError ? parseMessageBody(latestError.body).error : undefined;
    lines.push(`- ${task}  run=${runId.slice(0, 8)}…  status=${status}  stage=${stage}  last=${lastAt}`);
    if (error) lines.push(`  ${chalk.red("error:")} ${wrapText(error, Math.max(40, getTerminalWidth() - 10)).replace(/\n/g, "\n  ")}`);
  }
  return lines.join("\n");
}

function renderRecentActivity(messages: Message[]): string {
  if (messages.length === 0) return "";
  const width = Math.max(40, getTerminalWidth() - 4);
  const lines: string[] = [chalk.bold("Recent Activity")];
  for (const msg of messages) {
    const phase = messagePhase(msg) ?? "—";
    const activity = messageActivity(msg);
    lines.push(`[${formatTimestamp(msg.created_at)}] ${messageTask(msg)} ${phase} ${msg.sender_agent_type} → ${msg.recipient_agent_type}`);
    lines.push(`  ${activity}`);
    const args = messageArgs(msg);
    if (args && args !== activity) {
      lines.push(`  args: ${wrapText(args, width).replace(/\n/g, "\n        ")}`);
    }
  }
  return lines.join("\n");
}

export function adaptDaemonRun(row: DaemonRunRow): Run {
  return {
    id: row.id,
    project_id: "",
    task_id: row.task_id,
    agent_type: "daemon",
    session_key: null,
    worktree_path: null,
    status: row.status as Run["status"],
    started_at: row.started_at,
    completed_at: row.finished_at,
    created_at: row.created_at,
    progress: null,
    base_branch: null,
  };
}

function adaptPostgresRun(row: RunRow): Run {
  return {
    id: row.id,
    project_id: row.project_id,
    task_id: row.task_id,
    agent_type: row.agent_type,
    session_key: row.session_key,
    worktree_path: row.worktree_path,
    status: row.status as Run["status"],
    started_at: row.started_at,
    completed_at: row.completed_at,
    created_at: row.created_at,
    progress: row.progress,
    base_branch: row.base_branch,
  };
}

function adaptPostgresMessage(row: AgentMessageRow): Message {
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

export async function resolvePostgresInboxProject(projectPath: string, projectSelector?: string): Promise<{ adapter: BackendInboxAdapter; projectId: string } | null> {
  const projects = await listRegisteredProjects();
  const project = projectSelector
    ? projects.find((record) => record.id === projectSelector || record.name === projectSelector)
    : projects.find((record) => resolve(record.path) === resolve(projectPath));
  if (!project) return null;
  return { adapter: new BackendInboxAdapter(), projectId: project.id };
}

export async function resolvePostgresRunId(
  adapter: BackendInboxAdapter,
  projectId: string,
  options: { run?: string; task?: string },
): Promise<string | null> {
  if (options.run) return options.run;
  const taskFilter = options.task;
  if (taskFilter) {
    const task = typeof adapter.getTask === "function"
      ? await adapter.getTask(projectId, taskFilter)
      : null;
    if (task?.run_id) return task.run_id;
    const runs = await adapter.listRuns(projectId, { limit: 100 });
    return runs.find((run) => run.task_id === taskFilter)?.id ?? null;
  }
  const runs = await adapter.listRuns(projectId, { limit: 100 });
  return runs[0]?.id ?? null;
}

export async function fetchPostgresMessages(
  adapter: BackendInboxAdapter,
  projectId: string,
  options: { all?: boolean; runId?: string; agent?: string; unread?: boolean; limit: number },
): Promise<Message[]> {
  if (options.all) {
    let rows = await adapter.getAllMessagesGlobal(projectId, options.limit);
    if (options.agent) rows = rows.filter((row) => row.recipient_agent_type === options.agent);
    if (options.unread) rows = rows.filter((row) => row.read === 0);
    return rows.map(adaptPostgresMessage);
  }
  if (!options.runId) return [];
  if (options.agent) {
    const rows = await adapter.getMessages(projectId, options.runId, options.agent, options.unread ?? false);
    return selectRecentMessages(rows.map(adaptPostgresMessage), options.limit);
  }
  let rows = await adapter.getAllMessages(options.runId);
  if (options.unread) rows = rows.filter((row) => row.read === 0);
  return selectRecentMessages(rows.map(adaptPostgresMessage), options.limit);
}

export async function resolveDaemonInboxContext(projectPath: string, projectSelector?: string): Promise<InboxClientContext | null> {
  const backendMode = foremanBackendMode();
  let projects: Awaited<ReturnType<typeof listRegisteredProjects>>;
  try {
    projects = await listRegisteredProjects();
  } catch (error) {
    if (backendMode === "elixir") throw error;
    return null;
  }
  const project = projectSelector
    ? projects.find((record) => record.id === projectSelector || record.name === projectSelector)
    : projects.find((record) => resolve(record.path) === resolve(projectPath));
  if (!project) return null;
  if (backendMode === "elixir") {
    return { backend: "elixir", client: await createElixirInboxClient(), projectId: project.id };
  }
  return { backend: "node", client: createTrpcClient(), projectId: project.id };
}

export async function resolveDaemonRunId(
  daemon: InboxClientContext,
  options: { run?: string; task?: string },
): Promise<string | null> {
  if (options.run) return options.run;
  if (daemon.backend === "elixir") {
    const taskFilter = options.task;
    if (taskFilter && typeof daemon.client.getTask === "function") {
      const task = await daemon.client.getTask(taskFilter).catch(() => null);
      const taskRunId = task && typeof task.run_id === "string" ? task.run_id : null;
      if (taskRunId) return taskRunId;
    }

    const runs = await daemon.client.listRuns({ projectId: daemon.projectId });
    if (taskFilter) {
      const match = runs.find((run) => String(run.task_id ?? "") === taskFilter);
      return match?.run_id ? String(match.run_id) : match?.id ? String(match.id) : null;
    }
    const first = runs[0];
    return first?.run_id ? String(first.run_id) : first?.id ? String(first.id) : null;
  }
  const runs = await daemon.client.runs.list({ projectId: daemon.projectId, limit: 100 }) as DaemonRunRow[];
  const taskFilter = options.task;
  if (taskFilter) {
    const match = runs.find((run) => run.task_id === taskFilter);
    return match?.id ?? null;
  }
  return runs[0]?.id ?? null;
}

export function selectRecentMessages(messages: Message[], limit: number): Message[] {
  return messages.slice(Math.max(0, messages.length - limit));
}

export async function fetchDaemonMessages(
  daemon: InboxClientContext,
  options: { all?: boolean; runId?: string; agent?: string; unread?: boolean; limit: number },
): Promise<Message[]> {
  if (daemon.backend === "elixir") {
    const rows = await daemon.client.listInbox({
      projectId: daemon.projectId,
      runId: options.all ? undefined : options.runId,
      unread: options.unread,
      limit: options.limit,
    });
    const messages = rows
      .map((row) => ({
        id: String(row.message_id ?? `${row.run_id ?? "run"}-${row.subject ?? randomUUID()}`),
        run_id: String(row.run_id ?? ""),
        task_id: typeof row.task_id === "string" ? row.task_id : undefined,
        sender_agent_type: String(row.sender_agent_type ?? row.sender ?? row.from ?? "agent"),
        recipient_agent_type: String(row.recipient_agent_type ?? row.recipient ?? row.to ?? "run"),
        subject: String(row.subject ?? row.hook ?? "message"),
        body: typeof row.body === "string" ? row.body : JSON.stringify(row.body ?? {}),
        read: row.unread === false ? 1 : 0,
        created_at: String(row.created_at ?? new Date().toISOString()),
        deleted_at: null,
      }))
      .filter((row) => !options.agent || row.recipient_agent_type === options.agent);
    return options.all ? messages : selectRecentMessages(messages, options.limit);
  }

  if (options.all) {
    const rows = await daemon.client.mail.listGlobal({ projectId: daemon.projectId, limit: options.limit }) as DaemonMailMessage[];
    const filtered = options.agent
      ? rows.filter((row) => row.recipient_agent_type === options.agent)
      : rows;
    const unreadFiltered = options.unread ? filtered.filter((row) => row.read === 0) : filtered;
    return unreadFiltered.map(adaptDaemonMessage);
  }
  if (!options.runId) return [];
  const rows = await daemon.client.mail.list({
    projectId: daemon.projectId,
    runId: options.runId,
    agentType: options.agent,
    unreadOnly: options.unread,
  }) as DaemonMailMessage[];
  return selectRecentMessages(rows.map(adaptDaemonMessage), options.limit);
}

// ── Run resolution ────────────────────────────────────────────────────────────

function resolveLatestRunId(store: ForemanStore): string | null {
  // Get the most recently created run (any status)
  const runs = store.getRunsByStatuses(
    ["pending", "running", "completed", "failed", "stuck", "merged", "conflict", "test-failed", "pr-created", "reset"],
  );
  if (runs.length === 0) return null;
  // Runs are returned in DESC created_at order
  return runs[0]?.id ?? null;
}

function resolveRunIdByTask(store: ForemanStore, taskId: string): string | null {
  const runs = store.getRunsByStatuses(
    ["pending", "running", "completed", "failed", "stuck", "merged", "conflict", "test-failed", "pr-created", "reset"],
  );
  const taskRuns = runs.filter((r) => r.task_id === taskId);
  // Runs are returned DESC by created_at, so [0] is most recent
  return taskRuns[0]?.id ?? null;
}

function getInboxStatusRuns(store: ForemanStore): ReturnType<ForemanStore["getRunsByStatuses"]> {
  if (typeof store.getRunsByStatuses !== "function") return [];
  return store.getRunsByStatuses(["pending", "running", "completed", "failed", "stuck", "merged", "conflict", "test-failed", "pr-created", "reset"]);
}

export async function listDaemonRuns(daemon: InboxClientContext): Promise<Run[]> {
  if (daemon.backend === "elixir") {
    const runs = await daemon.client.listRuns();
    return runs
      .filter((run) => run.project_id === daemon.projectId)
      .map((run) => ({
        id: String(run.run_id ?? run.id ?? "unknown"),
        project_id: daemon.projectId,
        task_id: String(run.task_id ?? run.run_id ?? run.id ?? "unknown"),
        agent_type: "elixir",
        session_key: null,
        worktree_path: null,
        status: String(run.status ?? "running") as Run["status"],
        started_at: typeof run.started_at === "string" ? run.started_at : null,
        completed_at: typeof run.completed_at === "string" ? run.completed_at : null,
        created_at: typeof run.created_at === "string" ? run.created_at : new Date().toISOString(),
        progress: null,
        base_branch: null,
        merge_strategy: null,
      }));
  }
  const runs = await daemon.client.runs.list({ projectId: daemon.projectId, limit: 100 }) as DaemonRunRow[];
  return runs.map(adaptDaemonRun);
}

async function markDaemonMessageRead(daemon: InboxClientContext, messageId: string): Promise<void> {
  if (daemon.backend === "elixir") {
    return;
  }
  await daemon.client.mail.markRead({ projectId: daemon.projectId, messageId });
}

async function sendDaemonMessage(
  daemon: InboxClientContext,
  input: { runId: string; from: string; to: string; subject: string; body: string },
): Promise<void> {
  if (daemon.backend === "elixir") {
    const response = await daemon.client.sendCommand({
      command_id: `inbox-send-${randomUUID()}`,
      command_type: "inbox.send",
      payload: {
        project_id: daemon.projectId,
        run_id: input.runId,
        sender_agent_type: input.from,
        recipient_agent_type: input.to,
        subject: input.subject,
        body: input.body,
      },
    });
    if (!response.ok) {
      throw new Error(response.error.message);
    }
    return;
  }
  await daemon.client.mail.send({
    projectId: daemon.projectId,
    runId: input.runId,
    senderAgentType: input.from,
    recipientAgentType: input.to,
    subject: input.subject,
    body: input.body,
  });
}

// ── Events helper ───────────────────────────────────────────────────────────

function fetchEventsFromStore(store: ForemanStore, limit: number): PipelineEvent[] {
  // Fetch all runs and their events
  const runs = store.getRunsByStatuses([
    "pending", "running", "completed", "failed", "stuck", "merged", "conflict", "test-failed", "pr-created", "reset",
  ]);

  const allEvents: PipelineEvent[] = [];
  for (const run of runs) {
    const rows = store.getRunEvents(run.id);
    for (const row of rows) {
      allEvents.push({
        id: row.id,
        runId: row.run_id,
        eventType: row.event_type,
        details: row.details ? JSON.parse(row.details) : null,
        createdAt: row.created_at,
      });
    }
  }

  // Sort by created_at descending
  allEvents.sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());
  return allEvents.slice(0, limit);
}

function fetchEventsFromStoreForRun(store: ForemanStore, runId: string, limit: number): PipelineEvent[] {
  const rows = store.getRunEvents(runId);
  return rows.map((row) => ({
    id: row.id,
    runId: row.run_id,
    eventType: row.event_type,
    details: row.details ? JSON.parse(row.details) : null,
    createdAt: row.created_at,
  }));
}

// ── send subcommand ───────────────────────────────────────────────────────────

/**
 * `foreman inbox send` — Send an Agent Mail message from one agent to another
 * within a pipeline run (replaces the removed `foreman mail send`).
 *
 * The --run-id flag falls back to the FOREMAN_RUN_ID environment variable when
 * not provided.
 */
const inboxSendCommand = new Command("send")
  .description("Send an Agent Mail message within a pipeline run")
  .option("--run-id <id>", "Run ID (falls back to FOREMAN_RUN_ID env var)")
  .requiredOption("--from <agent>", "Sender agent role (e.g. explorer, developer)")
  .requiredOption("--to <agent>", "Recipient agent role (e.g. foreman, developer)")
  .requiredOption("--subject <subject>", "Message subject (e.g. phase-started, phase-complete, agent-error)")
  .option("--body <json>", "Message body as JSON string (defaults to '{}')", "{}")
  .action(async (options: {
    runId?: string;
    from: string;
    to: string;
    subject: string;
    body: string;
  }) => {
    // Resolve run ID: flag takes priority, then env var
    const runId = options.runId ?? (process.env["FOREMAN_RUN_ID"] || undefined);
    if (!runId) {
      process.stderr.write(
        "inbox send error: --run-id is required (or set FOREMAN_RUN_ID)\n",
      );
      process.exit(1);
      return;
    }

    // Validate body is valid JSON
    let parsedBody: string;
    try {
      // Parse and re-stringify to normalise whitespace; also validates JSON
      parsedBody = JSON.stringify(JSON.parse(options.body));
    } catch {
      process.stderr.write(
        `inbox send error: --body must be valid JSON (got: ${options.body})\n`,
      );
      process.exit(1);
      return;
    }

    const projectPath = await resolveRepoRootProjectPath({});
    try {
      const resolvedProjectPath = resolve(projectPath);
      const daemon = await resolveDaemonInboxContext(resolvedProjectPath);
      if (!daemon) {
        throw new Error(`Project at '${projectPath}' is not registered with the daemon.`);
      }
      await sendDaemonMessage(daemon, {
        runId,
        from: options.from,
        to: options.to,
        subject: options.subject,
        body: parsedBody,
      });
      process.exit(0);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      process.stderr.write(`inbox send error: ${msg}\n`);
      process.exit(1);
    }
  });

// ── Main command ──────────────────────────────────────────────────────────────

// Exported for unit testing
export { formatMessage };

export const inboxCommand = new Command("inbox")
  .description("View the Postgres message inbox for agents in a pipeline run")
  .addCommand(inboxSendCommand)
  .option("--agent <name>", "Filter to a specific agent/role (default: show all)")
  .option("--run <id>", "Filter to a specific run ID (default: latest run)")
  .option("--task <id>", "Resolve run by task ID (uses most recent run for that task)")
  .option("--all", "Watch messages across all runs (ignores --run and --task)")
  .option("--watch", "Poll every 2s for new messages (shows only new ones)")
  .option("--unread", "Show only unread messages")
  .option("--limit <n>", "Max messages to show", "50")
  .option("--ack", "Mark shown messages as read after displaying them")
  .option("--full", "Show full message payloads (no truncation, JSON pretty-printed)")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .option("--events", "Also show pipeline events as a columnar table (time, task, phase, turns, event, message)")
  .option("--compact", "Show compact task/run summary instead of raw event/mail spam")
  .option("--grouped", "Group pipeline events by workflow/phase instead of the default event table")
  .option("--events-limit <n>", "Max pipeline events to show (default: 50)", "50")
  .action(async (options: {
    agent?: string;
    run?: string;
    task?: string;
    all?: boolean;
    watch?: boolean;
    unread?: boolean;
    limit?: string;
    ack?: boolean;
    full?: boolean;
    project?: string;
    projectPath?: string;
    events?: boolean;
    compact?: boolean;
    grouped?: boolean;
    eventsLimit?: string;
    "events-limit"?: string;
  }) => {
    const fullPayload = options.full ?? false;
    const limit = parseInt(options.limit ?? "50", 10);
    const eventsLimit = parseInt(options.eventsLimit ?? options["events-limit"] ?? "50", 10);
    const showEvents = options.events ?? false;
    const compactOutput = options.compact ?? false;
    const groupedEvents = options.grouped ?? false;
    const taskFilter = options.task;

    // Require --project or --all in multi-project mode
    await requireProjectOrAllInMultiMode(options.project, options.all ?? false);

    // Resolve the project root via --project flag or VCS auto-detection
    let projectPath: string;
    try {
      projectPath = await resolveRepoRootProjectPath({
        project: options.project,
        projectPath: options.projectPath,
      });
    } catch {
      projectPath = process.cwd();
    }

    const daemon = await resolveDaemonInboxContext(projectPath, options.project);
    const postgres = process.env.FOREMAN_ENABLE_INBOX_POSTGRES === "1"
      ? await resolvePostgresInboxProject(projectPath, options.project)
      : null;
    const store = daemon || postgres ? null : ForemanStore.forProject(projectPath);

    try {
      // ── One-shot global mode (--all without --watch) ───────────────────────
      if (options.all && !options.watch) {
        let messages = postgres
          ? await fetchPostgresMessages(postgres.adapter, postgres.projectId, { all: true, agent: options.agent, unread: options.unread, limit })
          : daemon
            ? await fetchDaemonMessages(daemon, { all: true, agent: options.agent, unread: options.unread, limit })
            : store!.getAllMessagesGlobal(limit);

        // Apply agent filter (by recipient, matching single-run behavior)
        if (!daemon && options.agent) {
          messages = messages.filter((m) => m.recipient_agent_type === options.agent);
        }

        // Apply unread filter
        if (!daemon && options.unread) {
          messages = messages.filter((m) => m.read === 0);
        }

        const summaryRuns = postgres
          ? (await postgres.adapter.listRuns(postgres.projectId, { limit: 100 })).map(adaptPostgresRun)
          : daemon
            ? await listDaemonRuns(daemon)
            : getInboxStatusRuns(store!);
        const chronologicalMessages = [...messages].sort((a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime());

        if (messages.length === 0) {
          console.log(`No ${options.unread ? "unread " : ""}messages found across all runs${options.agent ? ` (agent: ${options.agent})` : ""}.`);
        } else {
          console.log(renderRunProgressSummary(chronologicalMessages, summaryRuns));
          console.log("");
          console.log(renderRecentActivity(chronologicalMessages.slice(-Math.min(chronologicalMessages.length, 12))));
          console.log("");
          if (fullPayload) {
            console.log(`\nInbox — all runs${options.agent ? `  agent: ${options.agent}` : ""}\n${"─".repeat(70)}`);
            for (const msg of messages) {
              console.log(formatMessage(msg, true));
              console.log("");
            }
            console.log(`${"─".repeat(70)}\n${messages.length} message(s) shown.`);
          } else {
            console.log(`${messages.length} message(s) analyzed. Use --full for complete raw payloads.`);
          }
        }

        if (options.ack && messages.length > 0) {
          if (postgres) {
            for (const msg of messages) await postgres.adapter.markMessageRead(postgres.projectId, msg.id);
          } else if (daemon) {
            for (const msg of messages) {
              await markDaemonMessageRead(daemon, msg.id);
            }
          } else {
            for (const msg of messages) {
              store!.markMessageRead(msg.id);
            }
          }
          console.log(`Marked ${messages.length} message(s) as read.`);
        }

        // ── Pipeline events section (--events) ─────────────────────────────
        if (showEvents) {
          console.log("");
          const events = postgres
            ? await fetchPostgresEvents(postgres.adapter, postgres.projectId, { all: true, limit: eventsLimit })
            : daemon
              ? await fetchDaemonEvents(daemon, { all: true, limit: eventsLimit })
              : fetchEventsFromStore(store!, eventsLimit);

          if (events.length === 0) {
            console.log("No pipeline events found.");
          } else {
            console.log(chalk.bold("\nPipeline Events — all runs"));
            if (groupedEvents) {
              console.log("─".repeat(70));
              for (const line of formatPipelineEventsGrouped(events)) {
                console.log(line);
              }
              console.log("─".repeat(70));
            } else {
              console.log(renderPipelineEventsTable(events));
            }
            console.log(`${events.length} event(s) shown.`);
          }
        }
        return;
      }

      // ── Global watch mode (--all --watch) ──────────────────────────────────
      if (options.all && options.watch) {
        console.log("Watching all runs... (Ctrl-C to stop)\n");
        const seenIds = new Set<string>();
        const seenEventIds = new Set<string>();
        const seenRunStatuses = new Map<string, string>();
        const initialGlobal = postgres
          ? await fetchPostgresMessages(postgres.adapter, postgres.projectId, { all: true, agent: options.agent, unread: false, limit })
          : daemon
            ? await fetchDaemonMessages(daemon, { all: true, agent: options.agent, unread: false, limit })
            : store!.getAllMessagesGlobal(limit);
        if (initialGlobal.length > 0) {
          console.log(`── past messages ${"─".repeat(53)}`);
          if (fullPayload) {
            for (const m of initialGlobal) { console.log(formatMessage(m, true)); console.log(""); seenIds.add(m.id); }
          } else {
            const rows = initialGlobal.map((m) => formatMessageTable(m));
            console.log(renderMessageTable(rows));
            console.log("");
            for (const m of initialGlobal) seenIds.add(m.id);
          }
          console.log(`── live ─────────────────────────────────────────────────────────────\n`);
        }
        const initRuns = postgres
          ? (await postgres.adapter.listRuns(postgres.projectId, { limit: 100 })).map(adaptPostgresRun)
          : daemon
            ? await listDaemonRuns(daemon)
            : store!.getRunsByStatuses(["completed", "failed", "running"]);
        for (const r of initRuns) seenRunStatuses.set(r.id, r.status);

        if (showEvents) {
          const initialEvents = postgres
            ? await fetchPostgresEvents(postgres.adapter, postgres.projectId, { all: true, limit: eventsLimit })
            : daemon
              ? await fetchDaemonEvents(daemon, { all: true, limit: eventsLimit })
              : fetchEventsFromStore(store!, eventsLimit);

          if (initialEvents.length > 0) {
            console.log(`── past events ${"─".repeat(55)}`);
            const sortedEvents = sortEventsChronologically(initialEvents);
            for (const event of sortedEvents) seenEventIds.add(event.id);
            if (groupedEvents) {
              for (const event of sortedEvents) console.log(formatPipelineEvent(event));
            } else {
              console.log(renderPipelineEventsTable(sortedEvents));
            }
            console.log(`── live ${"─".repeat(62)}\n`);
          } else {
            console.log(`── live ${"─".repeat(62)}\n`);
          }
        }
        const pollAll = (): void => {
          void (async () => {
            const statusRuns = postgres
              ? (await postgres.adapter.listRuns(postgres.projectId, { limit: 100 })).map(adaptPostgresRun)
              : daemon
                ? await listDaemonRuns(daemon)
                : store!.getRunsByStatuses(["completed", "failed", "running"]);
            for (const run of statusRuns) {
              const priorStatus = seenRunStatuses.get(run.id);
              if (priorStatus !== run.status) {
                seenRunStatuses.set(run.id, run.status);
                console.log(formatRunStatus(run));
                console.log("");
              }
            }

            if (showEvents) {
              const events = postgres
                ? await fetchPostgresEvents(postgres.adapter, postgres.projectId, { all: true, limit: eventsLimit })
                : daemon
                  ? await fetchDaemonEvents(daemon, { all: true, limit: eventsLimit })
                  : fetchEventsFromStore(store!, eventsLimit);
              const unseenEvents = selectUnseenEvents(events, seenEventIds);
              if (unseenEvents.length > 0) {
                for (const event of unseenEvents) seenEventIds.add(event.id);
                if (groupedEvents) {
                  for (const event of unseenEvents) console.log(formatPipelineEvent(event));
                } else {
                  console.log(renderPipelineEventsTableRows(unseenEvents));
                }
              }
            }
            const msgs = postgres
              ? await fetchPostgresMessages(postgres.adapter, postgres.projectId, { all: true, agent: options.agent, unread: false, limit })
              : daemon
                ? await fetchDaemonMessages(daemon, { all: true, agent: options.agent, unread: false, limit })
                : store!.getAllMessagesGlobal(limit);
            for (const msg of msgs.filter((m) => !seenIds.has(m.id))) {
              seenIds.add(msg.id);
              if (fullPayload) {
                console.log(formatMessage(msg, true));
                console.log("");
              } else {
                const rows = [formatMessageTable(msg)];
                console.log(renderMessageTable(rows));
                console.log("");
              }
            }
          })().catch(() => undefined);
        };
        pollAll();
        const interval = setInterval(pollAll, 2000);
        process.on("SIGINT", () => { clearInterval(interval); store?.close(); process.exit(0); });
        return;
      }

      const runId = postgres
        ? await resolvePostgresRunId(postgres.adapter, postgres.projectId, { run: options.run, task: options.task })
        : daemon
          ? await resolveDaemonRunId(daemon, { run: options.run, task: options.task })
          : options.run
            ?? (taskFilter ? resolveRunIdByTask(store!, taskFilter) : null)
            ?? resolveLatestRunId(store!);
      if (!runId) {
        console.error("No runs found. Start a pipeline first with `foreman run`.");
        process.exit(1);
      }

      // Resolve task ID for display (run record carries task_id)
      const allRuns = postgres
        ? (await postgres.adapter.listRuns(postgres.projectId, { limit: 100 })).map(adaptPostgresRun)
        : daemon
          ? await listDaemonRuns(daemon)
          : store!.getRunsByStatuses(
            ["pending", "running", "completed", "failed", "stuck", "merged", "conflict", "test-failed", "pr-created", "reset"],
          );
      const thisRun = allRuns.find((r) => r.id === runId);
      const taskLabel = thisRun?.task_id ? `  task: ${thisRun.task_id}` : "";

      if (!options.watch) {
        // One-shot: show current run lifecycle status then fetch and display messages
        const runStatusRuns = postgres
          ? (await postgres.adapter.listRuns(postgres.projectId, { limit: 100 })).map(adaptPostgresRun)
          : daemon
            ? await listDaemonRuns(daemon)
            : store!.getRunsByStatuses(["completed", "failed"]);
        const currentRun = runStatusRuns.find((r) => r.id === runId);
        if (currentRun) {
          console.log(formatRunStatus(currentRun));
          console.log("");
        }

        const messages = postgres
          ? await fetchPostgresMessages(postgres.adapter, postgres.projectId, { runId, agent: options.agent, unread: options.unread, limit })
          : daemon
            ? await fetchDaemonMessages(daemon, { runId, agent: options.agent, unread: options.unread, limit })
            : fetchMessages(store!, runId, options.agent, options.unread ?? false, limit);
        if (messages.length === 0) {
          if (!compactOutput) {
            console.log(`No ${options.unread ? "unread " : ""}messages for run ${runId}${taskLabel}${options.agent ? ` (agent: ${options.agent})` : ""}.`);
          }
        } else {
          if (compactOutput) {
            // Summarized with events below.
          } else if (fullPayload) {
            console.log(`\nInbox — run: ${runId}${taskLabel}${options.agent ? `  agent: ${options.agent}` : ""}\n${"─".repeat(70)}`);
            for (const msg of messages) {
              console.log(formatMessage(msg, true));
              console.log("");
            }
            console.log(`${"─".repeat(70)}\n${messages.length} message(s) shown.`);
          } else if (showEvents) {
            console.log(chalk.bold(`\nInbox Messages — run: `) + `${runId}${taskLabel}${options.agent ? `  agent: ${options.agent}` : ""}`);
            console.log("─".repeat(70));
            for (const msg of messages) console.log(formatInboxMessageLine(msg));
            console.log("─".repeat(70));
            console.log(`${messages.length} message(s) shown.`);
          } else {
            const rows = messages.map((msg) => formatMessageTable(msg));
            console.log(`\nInbox — run: ${runId}${taskLabel}${options.agent ? `  agent: ${options.agent}` : ""}`);
            console.log(renderMessageTable(rows));
            console.log(`${messages.length} message(s) shown.`);
          }
        }

        if (postgres && !showEvents) {
          const lifecycleEvents = await fetchPostgresEvents(postgres.adapter, postgres.projectId, { runId, limit: Math.min(eventsLimit, 10) });
          if (lifecycleEvents.length > 0) {
            console.log(chalk.bold("\nLifecycle Events — run: ") + runId);
            console.log("─".repeat(70));
            for (const event of lifecycleEvents) console.log(formatPipelineEvent(event));
            console.log("─".repeat(70));
          }
        }

        if (options.ack && messages.length > 0) {
          if (postgres) {
            for (const msg of messages) await postgres.adapter.markMessageRead(postgres.projectId, msg.id);
          } else if (daemon) {
            for (const msg of messages) {
              await markDaemonMessageRead(daemon, msg.id);
            }
          } else {
            for (const msg of messages) {
              store!.markMessageRead(msg.id);
            }
          }
          console.log(`Marked ${messages.length} message(s) as read.`);
        }

        // ── Pipeline events / compact section (--events, --compact) ────────
        if (showEvents || compactOutput) {
          console.log("");
          const eventFetchLimit = compactOutput ? Math.max(eventsLimit, 500) : eventsLimit;
          const events = postgres
            ? await fetchPostgresEvents(postgres.adapter, postgres.projectId, { runId, limit: eventFetchLimit })
            : daemon
              ? await fetchDaemonEvents(daemon, { runId, limit: eventFetchLimit })
              : fetchEventsFromStoreForRun(store!, runId, eventFetchLimit);

          if (compactOutput) {
            console.log(formatCompactInboxSummary({
              runId,
              taskId: thisRun?.task_id,
              status: currentRun?.status ?? thisRun?.status,
              messages,
              events,
            }));
          }

          if (!compactOutput) {
            if (events.length === 0) {
              console.log("\nNo pipeline events found.");
            } else {
              console.log(chalk.bold("\nPipeline Events — run: ") + `${runId}${taskLabel}`);
              if (groupedEvents) {
                console.log("─".repeat(70));
                for (const line of formatPipelineEventsGrouped(events)) {
                  console.log(line);
                }
                console.log("─".repeat(70));
              } else {
                console.log(renderPipelineEventsTable(events));
              }
              console.log(`${events.length} event(s) shown.`);
            }
          }
        }
        return;
      }

      // Watch mode: poll every 2s, show past messages first then new ones
      console.log(`Watching inbox for run ${runId}${taskLabel}${options.agent ? ` (agent: ${options.agent})` : ""}... (Ctrl-C to stop)\n`);
      const seenIds = new Set<string>();
      const seenRunIds = new Set<string>();

      // Initial fetch — print existing messages immediately, then track them as seen
      const initial = postgres
        ? await fetchPostgresMessages(postgres.adapter, postgres.projectId, { runId, agent: options.agent, unread: false, limit })
        : daemon
          ? await fetchDaemonMessages(daemon, { runId, agent: options.agent, unread: false, limit })
          : fetchMessages(store!, runId, options.agent, false, limit);
      if (initial.length > 0) {
        console.log(`── past messages ${"─".repeat(53)}`);
        if (fullPayload) {
          for (const m of initial) { console.log(formatMessage(m, true)); console.log(""); seenIds.add(m.id); }
          console.log(`── live ─────────────────────────────────────────────────────────────\n`);
        } else if (showEvents) {
          for (const m of initial) { console.log(formatInboxMessageLine(m)); seenIds.add(m.id); }
          console.log(`── live ─────────────────────────────────────────────────────────────\n`);
        } else {
          const rows = initial.map((m) => formatMessageTable(m));
          console.log(renderMessageTable(rows));
          console.log("");
          for (const m of initial) seenIds.add(m.id);
          console.log(`── live ─────────────────────────────────────────────────────────────\n`);
        }
      }

      // Task seenRunIds with any already-completed/failed runs so we only show new transitions
      const initialRuns = postgres
        ? (await postgres.adapter.listRuns(postgres.projectId, { limit: 100 })).map(adaptPostgresRun)
        : daemon
          ? await listDaemonRuns(daemon)
          : store!.getRunsByStatuses(["completed", "failed"]);
      for (const r of initialRuns) seenRunIds.add(r.id);

      const poll = (): void => {
        void (async () => {
          const statusRuns = postgres
            ? (await postgres.adapter.listRuns(postgres.projectId, { limit: 100 })).map(adaptPostgresRun)
            : daemon
              ? await listDaemonRuns(daemon)
              : store!.getRunsByStatuses(["completed", "failed"]);
          for (const run of statusRuns) {
            if (!seenRunIds.has(run.id)) {
              seenRunIds.add(run.id);
              console.log(formatRunStatus(run));
              console.log("");
            }
          }

          const msgs = postgres
            ? await fetchPostgresMessages(postgres.adapter, postgres.projectId, { runId, agent: options.agent, unread: options.unread, limit })
            : daemon
              ? await fetchDaemonMessages(daemon, { runId, agent: options.agent, unread: options.unread, limit })
              : fetchMessages(store!, runId, options.agent, options.unread ?? false, limit);
          const newMsgs = msgs.filter((m) => !seenIds.has(m.id));
          for (const msg of newMsgs) {
            seenIds.add(msg.id);
            if (fullPayload) {
              console.log(formatMessage(msg, true));
              console.log("");
            } else if (showEvents) {
              console.log(formatInboxMessageLine(msg));
              console.log("");
            } else {
              const rows = [formatMessageTable(msg)];
              console.log(renderMessageTable(rows));
              console.log("");
            }
            if (options.ack) {
              if (postgres) {
                await postgres.adapter.markMessageRead(postgres.projectId, msg.id);
              } else if (daemon) {
                await markDaemonMessageRead(daemon, msg.id);
              } else {
                store!.markMessageRead(msg.id);
              }
            }
          }
        })().catch(() => undefined);
      };

      // Initial poll after setup
      poll();

      const interval = setInterval(poll, 2000);
      // Keep the process alive
      process.on("SIGINT", () => {
        clearInterval(interval);
        store?.close();
        process.exit(0);
      });
    } catch (err: unknown) {
      store?.close();
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`inbox error: ${msg}`);
      process.exit(1);
    }
  });

// ── Helpers ───────────────────────────────────────────────────────────────────

function fetchMessages(
  store: ForemanStore,
  runId: string,
  agent: string | undefined,
  unreadOnly: boolean,
  limit: number,
): Message[] {
  let messages: Message[];
  if (agent) {
    messages = store.getMessages(runId, agent, unreadOnly);
  } else {
    // No agent filter — get all messages for the run
    const all = store.getAllMessages(runId);
    messages = unreadOnly ? all.filter((m) => m.read === 0) : all;
  }
  return selectRecentMessages(messages, limit);
}
