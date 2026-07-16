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
import { existsSync, readdirSync, statSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { randomUUID } from "node:crypto";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { createInterface } from "readline";
import { resolveEditor } from "./board.js";
import { runSuperTui } from "../super-tui/render.js";
import type { SuperTuiDataAdapter } from "../super-tui/data.js";
import type { SuperTuiView } from "../super-tui/model.js";
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
  worktree_path?: string | null;
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

/**
 * Render a structured detail view for a pipeline event, showing
 * the event metadata and formatted JSON payload.
 */
export function renderEventDetail(event: PipelineEvent): string {
  const lines: string[] = [];
  const terminalWidth = getTerminalWidth();
  const indentWidth = 2;
  const keyWidth = 14;

  // Event header
  lines.push(chalk.bold("EVENT DETAIL"));
  lines.push("─".repeat(Math.min(terminalWidth, 60)));

  // Metadata
  lines.push(`${pad("id:", keyWidth)} ${event.id}`);
  lines.push(`${pad("runId:", keyWidth)} ${event.runId ?? "-"}`);
  lines.push(`${pad("taskId:", keyWidth)} ${event.taskId ?? "-"}`);
  lines.push(`${pad("projectId:", keyWidth)} ${event.projectId ?? "-"}`);
  lines.push(`${pad("type:", keyWidth)} ${event.eventType}`);
  lines.push(`${pad("createdAt:", keyWidth)} ${formatTimestamp(event.createdAt)}`);

  // Structured JSON payload
  const details = normalizedEventDetails(event);
  const hasPayload = event.details != null && Object.keys(event.details).length > 0;
  if (hasPayload && details) {
    lines.push("");
    lines.push(chalk.bold("PAYLOAD:"));
    // Format JSON with indentation for readability
    const jsonStr = JSON.stringify(details, null, 2);
    const formattedJson = wrapText(jsonStr, Math.max(40, terminalWidth - indentWidth - 4));
    formattedJson.split("\n").forEach((line) => {
      lines.push(`${" ".repeat(indentWidth)}${line}`);
    });
  } else {
    lines.push("");
    lines.push(chalk.dim("No payload details available."));
  }

  return lines.join("\n");
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

function eventProject(event: PipelineEvent, details: Record<string, unknown> | null): string | undefined {
  // projectId is stored in the normalized details as project_id
  return details
    ? detailString(details, ["project_id", "projectId"]) ?? event.projectId ?? undefined
    : event.projectId ?? undefined;
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
  project: string;
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
    project: eventProject(event, details) ?? "-",
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
    project: Math.max(10, ...rows.map((row) => row.project.length)),
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
    pad(row.project, widths.project),
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
    pad("PROJECT", widths.project),
    pad("EVENT", widths.event),
    pad("MESSAGE", widths.message),
  ].join(" │ ");
  const totalWidth = widths.time + widths.task + widths.phase + widths.turns + widths.project + widths.event + widths.message + 18;
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

function parseRecordPayload(value: unknown): Record<string, unknown> | null {
  let raw = value;
  if (typeof value === "string") {
    try {
      raw = JSON.parse(value);
    } catch {
      return null;
    }
  }
  return raw && typeof raw === "object" && !Array.isArray(raw) ? raw as Record<string, unknown> : null;
}

export function adaptPostgresEvent(row: { id: string; run_id: string | null; task_id?: string | null; project_id?: string | null; event_type: string; payload: unknown; created_at: string | Date }): PipelineEvent {
  const payload = parseRecordPayload(row.payload);
  return {
    id: row.id,
    runId: row.run_id,
    taskId: row.task_id,
    projectId: row.project_id,
    eventType: row.event_type,
    details: payload,
    createdAt: normalizedIso(row.created_at) ?? new Date().toISOString(),
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
  return [...events].sort((a, b) => timestampMs(a.createdAt) - timestampMs(b.createdAt));
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
          createdAt: normalizedIso(row.occurred_at ?? row.created_at ?? new Date().toISOString()) ?? new Date().toISOString(),
        };
      })
      .sort((a, b) => timestampMs(b.createdAt) - timestampMs(a.createdAt))
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
        details: parseRecordPayload(row.details),
        createdAt: row.created_at,
      }))
      .sort((a, b) => timestampMs(b.createdAt) - timestampMs(a.createdAt))
      .slice(0, options.limit);
  }
  if (!options.runId) return [];
  const rows = await daemon.client.runs.listEvents({ runId: options.runId }) as DaemonPipelineEventRow[];
  return rows
    .map((row) => ({
      id: row.id,
      runId: row.run_id,
      eventType: row.event_type,
      details: parseRecordPayload(row.details),
      createdAt: row.created_at,
    }))
    .sort((a, b) => timestampMs(b.createdAt) - timestampMs(a.createdAt))
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

/**
 * Remove control characters that could manipulate terminal state.
 * Allows printable characters, tabs, and standard line endings.
 */
function sanitizeForTerminal(str: string): string {
  // Remove control characters except tab (\t), newline (\n), carriage return (\r)
  // These can cause screen clearing, cursor movement, or text spoofing
  return str.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, "�");
}

function formatMessage(msg: Message, fullPayload = false): string {
  const ts = formatTimestamp(msg.created_at);
  const readMark = msg.read === 1 ? " [read]" : "";
  const header = `[${ts}] ${msg.sender_agent_type} → ${msg.recipient_agent_type}  |  ${msg.subject}${readMark}`;

  if (fullPayload) {
    // Show full body — try to format as key-value pairs, otherwise show raw
    let bodyLines: string[];
    try {
      const parsed = JSON.parse(msg.body);
      const terminalWidth = getTerminalWidth();
      // Only render as key-value pairs for non-null, non-array objects with entries
      if (
        parsed !== null &&
        typeof parsed === "object" &&
        !Array.isArray(parsed) &&
        Object.keys(parsed).length > 0
      ) {
        const entries = Object.entries(parsed as Record<string, unknown>);
        bodyLines = entries.map(([key, value]) => {
          // Sanitize key and serialize value before outputting to prevent terminal injection
          const safeKey = sanitizeForTerminal(key);
          // Serialize nested objects as JSON strings within the value
          const valueStr = typeof value === "object" && value !== null
            ? JSON.stringify(value)
            : String(value);
          const safeValue = sanitizeForTerminal(valueStr);
          // Wrap long values at terminal width (accounting for "  key: " prefix)
          const prefixLen = safeKey.length + 4; // "  key: "
          const wrappedValue = wrapText(safeValue, Math.max(1, terminalWidth - prefixLen));
          // Indent continuation lines to align after "key: "
          return wrappedValue.split("\n").map((line, i) =>
            i === 0 ? `  ${safeKey}: ${line}` : `  ${" ".repeat(safeKey.length + 2)}${line}`
          ).join("\n");
        });
      } else {
        // Fallback for empty objects, arrays, primitives, etc.: show serialized payload
        bodyLines = JSON.stringify(parsed, null, 2).split("\n");
      }
    } catch {
      bodyLines = msg.body.split("\n");
    }
    return `${header}\n${bodyLines.join("\n")}`;
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
  command?: string;
  path?: string;
  instructions?: string;
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
      command: typeof parsed["command"] === "string" ? parsed["command"] : undefined,
      path: typeof parsed["path"] === "string" ? parsed["path"] : undefined,
      instructions: typeof parsed["instructions"] === "string" ? parsed["instructions"] : undefined,
      traceFile: typeof parsed["traceFile"] === "string" ? parsed["traceFile"] : undefined,
      commandHonored: typeof parsed["commandHonored"] === "boolean" ? parsed["commandHonored"] : undefined,
      verdict: typeof parsed["verdict"] === "string" ? parsed["verdict"] : undefined,
      body: typeof parsed["body"] === "string" ? parsed["body"] : undefined,
    };
  } catch {
    return {};
  }
}

function displayArgsPayload(value: string): string {
  try {
    const parsed = JSON.parse(value) as Record<string, unknown>;
    const args = parsed["args"];
    if (args && typeof args === "object" && !Array.isArray(args)) {
      const nested = args as Record<string, unknown>;
      const command = nested["command"];
      if (typeof command === "string") return command;
      const path = nested["path"];
      if (typeof path === "string") return path;
    }
    const command = parsed["command"];
    if (typeof command === "string") return command;
    const path = parsed["path"];
    if (typeof path === "string") return path;
    const instructions = parsed["instructions"];
    if (typeof instructions === "string") return instructions;
    const message = parsed["message"];
    if (typeof message === "string") return message;
    const body = parsed["body"];
    if (typeof body === "string") return body;
  } catch {
    // Not a JSON payload; show as-is.
  }
  return value;
}

function singleLine(value: string): string {
  return value.replace(/[\r\n\t]+/g, " ").replace(/\s{2,}/g, " ").trim();
}

function messageArgsPreview(parsed: ParsedMessageBody, fallbackRaw?: string): string | undefined {
  const candidate = parsed.argsPreview
    ?? parsed.command
    ?? parsed.path
    ?? parsed.instructions
    ?? parsed.message
    ?? parsed.body
    ?? fallbackRaw;
  return candidate ? singleLine(displayArgsPayload(candidate)) : undefined;
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
const FORMAT_ARGS_MAX = 1000;

/**
 * Format a message as a table row.
 * @param msg The message to format
 * @param argsMaxLen Maximum length for the args column (default: 40)
 */
export function formatMessageTable(msg: Message, argsMaxLen = FORMAT_ARGS_MAX): TableRow {
  const parsed = parseMessageBody(msg.body);
  const bodyPreview = msg.body ? msg.body.replace(/\n/g, " ") : undefined;
  const plainToolMatch = bodyPreview?.match(/^Tool\s+(\S+)\s+(denied|approved|requested|finished|error)\b/i);
  const argsPreview = messageArgsPreview(parsed, bodyPreview);
  return {
    date: formatTimestamp(msg.created_at),
    ticket: messageTask(msg),
    sender: messagePhase(msg) ?? displayAgent(msg.sender_agent_type),
    receiver: displayAgent(msg.recipient_agent_type),
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

function terminalArgsWidth(): number {
  const columns = process.stdout.columns ?? 140;
  const fixedWidth = COL_WIDTHS.date + COL_WIDTHS.ticket + COL_WIDTHS.sender + COL_WIDTHS.receiver + COL_WIDTHS.kind + COL_WIDTHS.tool + 18;
  return Math.max(ARGS_DEFAULT, columns - fixedWidth);
}

function fullArgsWidth(rows: TableRow[]): number {
  return Math.max(terminalArgsWidth(), ...rows.map((row) => row.args?.length ?? 0));
}

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
function messageTableSizes(rows: TableRow[], argsWidth = ARGS_DEFAULT): ColumnSizes {
  return {
    date: COL_WIDTHS.date,
    ticket: Math.max(...rows.map((r) => r.ticket.length), COL_WIDTHS.ticket),
    sender: Math.max(...rows.map((r) => r.sender.length), COL_WIDTHS.sender),
    receiver: Math.max(...rows.map((r) => r.receiver.length), COL_WIDTHS.receiver),
    kind: Math.max(...rows.map((r) => r.kind?.length ?? 4), COL_WIDTHS.kind),
    tool: Math.max(...rows.map((r) => r.tool?.length ?? 4), COL_WIDTHS.tool),
    args: argsWidth,
  };
}

function renderMessageTableDataRows(rows: TableRow[], sizes: ColumnSizes): string {
  const padCell = (val: string | undefined, width: number): string =>
    pad(val ?? "-", width);

  return rows.map((row) =>
    [
      pad(row.date, sizes.date),
      pad(row.ticket, sizes.ticket),
      pad(row.sender, sizes.sender),
      pad(row.receiver, sizes.receiver),
      padCell(row.kind, sizes.kind),
      padCell(row.tool, sizes.tool),
      padCell(row.args, sizes.args),
    ].join(" │ ")
  ).join("\n");
}

export function renderMessageTableRows(rows: TableRow[], argsWidth = terminalArgsWidth()): string {
  if (rows.length === 0) return "";
  return renderMessageTableDataRows(rows, messageTableSizes(rows, argsWidth));
}

export function renderFullMessageTableRows(rows: TableRow[]): string {
  return renderMessageTableRows(rows, fullArgsWidth(rows));
}

export function renderMessageTable(rows: TableRow[], argsWidth = terminalArgsWidth()): string {
  if (rows.length === 0) return "";

  const sizes = messageTableSizes(rows, argsWidth);
  const totalWidth =
    sizes.date + sizes.ticket + sizes.sender + sizes.receiver +
    sizes.kind + sizes.tool + sizes.args + 8;

  const hr = "─".repeat(totalWidth);

  const header = [
    pad("DATE", sizes.date),
    pad("TASK", sizes.ticket),
    pad("PHASE", sizes.sender),
    pad("RECEIVER", sizes.receiver),
    pad("KIND", sizes.kind),
    pad("TOOL", sizes.tool),
    pad("ARGS", sizes.args),
  ].join(" │ ");

  return [hr, header, hr, renderMessageTableDataRows(rows, sizes), hr].join("\n");
}

function renderInboxMessagesTable(messages: Message[]): string {
  return renderMessageTable(messages.map((message) => formatMessageTable(message)));
}

function pad(val: string, width: number): string {
  if (val.length > width) return val.slice(0, width - 1) + "…";
  return val.padEnd(width, " ");
}

// ── TableFormatter (tabular message view) ────────────────────────────────────

/**
 * Extract structured fields from a JSON message body for the newer table view.
 * Returns nulls for missing fields and falls back through
 * argsPreview → command → path → instructions → message → body for ARGS.
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
    args: messageArgsPreview(parsed, body) ?? null,
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
 * DATETIME | TASK | PHASE | RECEIVER | KIND | TOOL | ARGS
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
        sender: messagePhase(msg) ?? displayAgent(msg.sender_agent_type),
        receiver: displayAgent(msg.recipient_agent_type),
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
    return "DATETIME          TASK        PHASE      RECEIVER   KIND       TOOL       ARGS";
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

function phaseFromAgentId(agent: string): string | undefined {
  const known = agent.match(/^(explorer|developer|documentation|repair|qa|reviewer|cli-review|finalize|refinery)(?:-|$)/);
  if (known) return known[1];

  // Phase worker IDs are commonly `<phase>-<taskId>`, e.g.
  // `cli-review-foreman-eeb44` or `repair-foreman-eeb44`.
  const taskSuffixed = agent.match(/^(.+)-foreman-[a-z0-9]+$/i);
  if (taskSuffixed && taskSuffixed[1] !== "overwatch") return taskSuffixed[1];

  return undefined;
}

function messagePhase(msg: Message): string | undefined {
  const parsed = parseMessageBody(msg.body).phase;
  if (parsed) return parsed;
  return phaseFromAgentId(msg.sender_agent_type) ?? phaseFromAgentId(msg.recipient_agent_type);
}

function displayAgent(agent: string): string {
  return phaseFromAgentId(agent) ?? agent;
}

function projectedMessageTaskId(msg: Message): string | undefined {
  const value: object = msg;
  if ("task_id" in value && typeof value.task_id === "string") return value.task_id;
  return undefined;
}

function messageTask(msg: Message): string {
  return parseMessageBody(msg.body).taskId ?? projectedMessageTaskId(msg) ?? msg.run_id;
}

function messageActivity(msg: Message): string {
  const parsed = parseMessageBody(msg.body);
  const parts: string[] = [];
  const phase = messagePhase(msg);
  if (phase) parts.push(`phase=${phase}`);
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
  return messageArgsPreview(parsed) ?? null;
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
    .filter((run) => isActiveRunStatus(run.status))
    .map((run) => run.id);
  const runIds = new Set<string>([...messages.map((msg) => msg.run_id), ...activeRunIds]);
  const lines: string[] = [chalk.bold("Run Summary")];
  for (const runId of runIds) {
    const list = (byRun.get(runId) ?? []).sort((a, b) => timestampMs(a.created_at) - timestampMs(b.created_at));
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
    lines.push(`- ${task}  run=${runId.slice(0, 10)}…  status=${status}  stage=${stage}  last=${lastAt}`);
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

export type InboxScope = "active" | "attention" | "all" | "terminal";
type ActivitySource = "event" | "message" | "run" | "none";

export interface InboxTaskSummary {
  taskId: string;
  runId: string;
  runStatus: string;
  phase: string;
  lastActivityAt: string | null;
  lastActivitySource: ActivitySource;
  statusText: string;
  attention: boolean;
  attentionReason: string | null;
  verdict: "pass" | "fail" | "retrying" | "blocked" | "unknown";
  projectId: string | null;
  worktreePath: string | null;
  messages: Message[];
  events: PipelineEvent[];
}

interface InboxDataSet {
  runs: Run[];
  messages: Message[];
  events: PipelineEvent[];
}

export function timestampMs(value: unknown): number {
  if (typeof value === "string" || typeof value === "number" || value instanceof Date) {
    const ms = new Date(value).getTime();
    return Number.isFinite(ms) ? ms : 0;
  }

  if (value && typeof value === "object" && "toISO" in value && typeof value.toISO === "function") {
    const ms = new Date(value.toISO()).getTime();
    return Number.isFinite(ms) ? ms : 0;
  }

  if (value && typeof value === "object" && "calendar" in value && "year" in value && "month" in value && "day" in value) {
    const dateTime = value;
    const year = typeof dateTime.year === "number" ? dateTime.year : 0;
    const month = typeof dateTime.month === "number" ? dateTime.month : 1;
    const day = typeof dateTime.day === "number" ? dateTime.day : 1;
    const hour = "hour" in dateTime && typeof dateTime.hour === "number" ? dateTime.hour : 0;
    const minute = "minute" in dateTime && typeof dateTime.minute === "number" ? dateTime.minute : 0;
    const second = "second" in dateTime && typeof dateTime.second === "number" ? dateTime.second : 0;
    return Date.UTC(year, month - 1, day, hour, minute, second);
  }

  return 0;
}

function normalizedIso(value: unknown): string | null {
  const ms = timestampMs(value);
  return ms > 0 ? new Date(ms).toISOString() : null;
}

function runStatusText(run: Run): string {
  return String(run.status);
}

function isActiveRunStatus(status: string): boolean {
  return status === "pending" || status === "running" || status === "in_progress" || status === "cooldown";
}

function isAttentionRunStatus(status: string): boolean {
  return status === "failed" || status === "stuck" || status === "conflict" || status === "test-failed";
}

function isTerminalRunStatus(status: string): boolean {
  return status === "completed" || status === "merged" || status === "reset" || status === "pr-created";
}

function relativeTime(iso: string | null): string {
  if (!iso) return "—";
  const deltaSeconds = Math.max(0, Math.floor((Date.now() - timestampMs(iso)) / 1000));
  if (deltaSeconds < 60) return `${deltaSeconds}s ago`;
  const deltaMinutes = Math.floor(deltaSeconds / 60);
  if (deltaMinutes < 60) return `${deltaMinutes}m ago`;
  const deltaHours = Math.floor(deltaMinutes / 60);
  if (deltaHours < 48) return `${deltaHours}h ago`;
  return formatTimestamp(iso);
}

function latestMessage(messages: Message[]): Message | undefined {
  return [...messages].sort((a, b) => timestampMs(b.created_at) - timestampMs(a.created_at))[0];
}

function latestEvent(events: PipelineEvent[]): PipelineEvent | undefined {
  return [...events].sort((a, b) => timestampMs(b.createdAt) - timestampMs(a.createdAt))[0];
}

function latestRunActivity(run: Run): string | null {
  const candidates = [run.completed_at, run.started_at, run.created_at].filter((value): value is string => Boolean(value));
  return candidates
    .map((value) => normalizedIso(value))
    .filter((value): value is string => Boolean(value))
    .sort((a, b) => timestampMs(b) - timestampMs(a))[0] ?? null;
}

function phaseFromEvent(event: PipelineEvent | undefined): string | undefined {
  if (!event) return undefined;
  return eventPhase(normalizedEventDetails(event));
}

function verdictFromActivity(runStatus: string, messages: Message[], events: PipelineEvent[]): InboxTaskSummary["verdict"] {
  if (isAttentionRunStatus(runStatus)) return "fail";
  const recentMessages = [...messages].sort((a, b) => timestampMs(b.created_at) - timestampMs(a.created_at));
  for (const message of recentMessages) {
    const parsed = parseMessageBody(message.body);
    if (parsed.verdict?.toLowerCase() === "fail" || parsed.status?.toLowerCase() === "fail") return "fail";
    if (parsed.verdict?.toLowerCase() === "pass" || parsed.status?.toLowerCase() === "pass") return "pass";
    if (message.subject.toLowerCase().includes("retry")) return "retrying";
  }
  if (events.some((event) => event.eventType === "PhaseRetried")) return "retrying";
  if (events.some((event) => event.eventType === "PhaseFailed" || event.eventType === "RunFailed")) return "fail";
  return "unknown";
}

function summaryStatusText(runStatus: string, latest: Message | undefined, event: PipelineEvent | undefined): string {
  if (latest) {
    const parsed = parseMessageBody(latest.body);
    if (parsed.error) return `error: ${truncate(parsed.error, 90)}`;
    const args = messageArgs(latest);
    const activity = messageActivity(latest);
    if (args && args !== activity) return truncate(`${activity} ${args}`, 100);
    return truncate(activity, 100);
  }
  if (event) return truncate(formatEventSummary(event.eventType, normalizedEventDetails(event)), 100);
  if (isActiveRunStatus(runStatus)) return "active; no recent messages/events";
  return runStatus;
}

function scopeIncludesSummary(scope: InboxScope, summary: InboxTaskSummary): boolean {
  if (scope === "all") return true;
  if (scope === "active") return isActiveRunStatus(summary.runStatus);
  if (scope === "attention") return isActiveRunStatus(summary.runStatus) || summary.attention;
  return isTerminalRunStatus(summary.runStatus);
}

export function buildInboxTaskSummaries(data: InboxDataSet, scope: InboxScope = "attention"): InboxTaskSummary[] {
  const messagesByRun = new Map<string, Message[]>();
  for (const message of data.messages) {
    const list = messagesByRun.get(message.run_id) ?? [];
    list.push(message);
    messagesByRun.set(message.run_id, list);
  }

  const eventsByRun = new Map<string, PipelineEvent[]>();
  for (const event of data.events) {
    if (!event.runId) continue;
    const list = eventsByRun.get(event.runId) ?? [];
    list.push(event);
    eventsByRun.set(event.runId, list);
  }

  const runById = new Map(data.runs.map((run) => [run.id, run]));
  const runIds = new Set<string>([
    ...data.runs.map((run) => run.id),
    ...data.messages.map((message) => message.run_id),
    ...data.events.map((event) => event.runId).filter((runId): runId is string => Boolean(runId)),
  ]);

  const summaries: InboxTaskSummary[] = [];
  for (const runId of runIds) {
    const run = runById.get(runId);
    const messages = [...(messagesByRun.get(runId) ?? [])].sort((a, b) => timestampMs(a.created_at) - timestampMs(b.created_at));
    const events = [...(eventsByRun.get(runId) ?? [])].sort((a, b) => timestampMs(a.createdAt) - timestampMs(b.createdAt));
    const latestMsg = latestMessage(messages);
    const latestEvt = latestEvent(events);
    const runStatus = run ? runStatusText(run) : "unknown";
    const messageTime = latestMsg ? normalizedIso(latestMsg.created_at) : null;
    const eventTime = latestEvt ? normalizedIso(latestEvt.createdAt) : null;
    const runTime = run ? latestRunActivity(run) : null;
    const activityCandidates: { source: ActivitySource; at: string }[] = [];
    if (messageTime) activityCandidates.push({ source: "message", at: messageTime });
    if (eventTime) activityCandidates.push({ source: "event", at: eventTime });
    if (runTime) activityCandidates.push({ source: "run", at: runTime });
    const latestActivity = activityCandidates.sort((a, b) => timestampMs(b.at) - timestampMs(a.at))[0];
    const attention = isAttentionRunStatus(runStatus) || messages.some((message) => {
      const parsed = parseMessageBody(message.body);
      return Boolean(parsed.error) || message.subject === "agent-error";
    });
    const phase = phaseFromEvent(latestEvt) ?? (latestMsg ? messagePhase(latestMsg) : undefined) ?? "unknown";
    const taskId = run?.task_id ?? (latestMsg ? messageTask(latestMsg) : runId);
    const summary: InboxTaskSummary = {
      taskId,
      runId,
      runStatus,
      phase,
      lastActivityAt: latestActivity?.at ?? null,
      lastActivitySource: latestActivity?.source ?? "none",
      statusText: summaryStatusText(runStatus, latestMsg, latestEvt),
      attention,
      attentionReason: attention ? summaryStatusText(runStatus, latestMsg, latestEvt) : null,
      verdict: verdictFromActivity(runStatus, messages, events),
      projectId: run?.project_id ?? null,
      worktreePath: run?.worktree_path ?? null,
      messages,
      events,
    };
    if (scopeIncludesSummary(scope, summary)) summaries.push(summary);
  }

  return summaries.sort((a, b) => timestampMs(b.lastActivityAt) - timestampMs(a.lastActivityAt));
}

export function renderInboxTaskSummaryTable(summaries: InboxTaskSummary[]): string {
  if (summaries.length === 0) return "No active or attention tasks found.";
  const rows = summaries.map((summary) => ({
    task: summary.taskId,
    state: summary.runStatus,
    phase: summary.phase,
    run: summary.runId.slice(0, 10),
    last: summary.lastActivityAt ? formatTimestamp(summary.lastActivityAt) : "—",
    age: relativeTime(summary.lastActivityAt),
    verdict: summary.verdict,
    status: summary.statusText,
  }));
  const widths = {
    task: Math.max(12, ...rows.map((row) => row.task.length)),
    state: Math.max(10, ...rows.map((row) => row.state.length)),
    phase: Math.max(10, ...rows.map((row) => row.phase.length)),
    run: 10,
    last: 19,
    age: Math.max(8, ...rows.map((row) => row.age.length)),
    verdict: Math.max(7, ...rows.map((row) => row.verdict.length)),
    status: Math.max(20, Math.min(80, getTerminalWidth() - 96)),
  };
  const header = [
    pad("TASK", widths.task),
    pad("STATE", widths.state),
    pad("PHASE", widths.phase),
    pad("RUN", widths.run),
    pad("LAST", widths.last),
    pad("AGE", widths.age),
    pad("VERDICT", widths.verdict),
    pad("STATUS", widths.status),
  ].join(" │ ");
  const body = rows.map((row) => [
    pad(row.task, widths.task),
    pad(row.state, widths.state),
    pad(row.phase, widths.phase),
    pad(row.run, widths.run),
    pad(row.last, widths.last),
    pad(row.age, widths.age),
    pad(row.verdict, widths.verdict),
    pad(truncate(row.status, widths.status), widths.status),
  ].join(" │ "));
  const separator = "─".repeat(header.length);
  return [chalk.bold("FOREMAN INBOX"), separator, header, separator, ...body, separator].join("\n");
}

export type InboxDetailTab = "summary" | "messages" | "events" | "logs" | "reports" | "files";

interface InboxTaskDetailOptions {
  agent?: string;
  unread?: boolean;
  limit: number;
  eventsLimit: number;
  messages: boolean;
  events: boolean;
  logs?: boolean;
  reports?: boolean;
  selectReport?: boolean;
  files?: boolean;
  follow?: boolean;
}

function foremanHomePath(...parts: string[]): string {
  return join(homedir(), ".foreman", ...parts);
}

function fileStatLine(label: string, path: string): string {
  if (!existsSync(path)) return `${label}: missing (${path})`;
  const stat = statSync(path);
  return `${label}: ${path} (${stat.size} bytes, updated ${relativeTime(stat.mtime.toISOString())})`;
}

function readTail(path: string, count: number): string[] {
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8")
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .slice(-count);
}

interface LogEntry {
  event_id: string;
  sequence: number;
  type: string;
  phase_id: string | null;
  worker_id: string | null;
  stream: string;
  message: string;
  occurred_at: string;
}

export function formatLogTimestamp(iso: string): string {
  try {
    // iso might be an Elixir ISO8601 string or unix epoch
    const ms = Number(iso);
    if (!isNaN(ms) && String(ms).length >= 10) {
      return new Date(ms < 1e12 ? ms * 1000 : ms).toISOString().replace("T", " ").replace("Z", "");
    }
    return new Date(iso).toISOString().replace("T", " ").replace("Z", "");
  } catch {
    return iso;
  }
}

export function colorForStream(stream: string): (s: string) => string {
  switch (stream) {
    case "stderr": return chalk.red;
    case "stdout": return chalk.dim;
    case "tool": return chalk.cyan;
    case "assistant": return chalk.green;
    default: return (s: string) => s;
  }
}

async function renderLogSection(summary: InboxTaskSummary, tailCount = 24): Promise<string> {
  let client: ElixirServerClient | undefined;
  try {
    const manager = new ElixirServerManager();
    const status = await manager.ensureRunning();
    client = new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN);
  } catch {
    // Elixir server not available — fall through to raw file display
  }
  const lines: string[] = [chalk.bold("Logs")];

  if (client) {
    try {
      const entries = await client.getRunLogs(summary.runId, "compact") as LogEntry[];
      if (entries && entries.length > 0) {
        lines.push(`Showing last ${Math.min(entries.length, tailCount)} structured log entries from Elixir backend.`);
        const shown = entries.slice(-tailCount);
        const termWidth = getTerminalWidth();
        for (const entry of shown) {
          const ts = formatLogTimestamp(entry.occurred_at);
          const stream = `[${entry.stream.padEnd(8)}]`;
          const type = entry.type ? `[${entry.type}]` : "";
          const phase = entry.phase_id ? `[${entry.phase_id}]` : "";
          const colorFn = colorForStream(entry.stream);
          const prefix = `${ts} ${colorFn(stream)} ${type ? colorFn(type) : ""} ${phase ? colorFn(phase) : ""}`;
          const msg = truncate(entry.message || "(empty)", Math.max(20, termWidth - prefix.length + 3));
          lines.push(`${prefix} ${colorFn(msg)}`);
        }
        return lines.join("\n");
      }
    } catch {
      // fall through to raw file fallback
    }
  }

  // Raw file fallback
  const rawPath = foremanHomePath("logs", `${summary.runId}.log`);
  const errPath = foremanHomePath("logs", `${summary.runId}.err`);
  const outPath = foremanHomePath("logs", `${summary.runId}.out`);
  const logDir = foremanHomePath("logs");
  const files = [
    { label: "raw", path: rawPath, name: `${summary.runId}.log` },
    { label: "err", path: errPath, name: `${summary.runId}.err` },
    { label: "out", path: outPath, name: `${summary.runId}.out` },
  ];
  const existing = files.filter((file) => existsSync(file.path));
  if (existing.length === 0) {
    lines.push(`No log files found for run ${summary.runId} under ${logDir}.`);
    lines.push(`Expected: ${files.map((file) => file.name).join(", ")}`);
    lines.push("Logs may have been removed by reset, purge, or workspace cleanup.");
    return lines.join("\n");
  }
  lines.push(...files.map((file) => fileStatLine(file.label, file.path)));
  const errTail = readTail(errPath, tailCount);
  if (errTail.length > 0) {
    lines.push("", chalk.bold("Recent error log lines"));
    lines.push(...errTail.map((line) => truncate(line, getTerminalWidth())));
  }
  return lines.join("\n");
}

function reportDirectoryCandidates(summary: InboxTaskSummary): string[] {
  const candidates: string[] = [];
  if (summary.projectId) {
    candidates.push(foremanHomePath("reports", summary.projectId, summary.taskId, summary.runId));
  }
  const reportsRoot = foremanHomePath("reports");
  if (!existsSync(reportsRoot)) return candidates;
  for (const projectEntry of readdirSync(reportsRoot, { withFileTypes: true })) {
    if (!projectEntry.isDirectory()) continue;
    const taskDir = join(reportsRoot, projectEntry.name, summary.taskId, summary.runId);
    if (!candidates.includes(taskDir)) candidates.push(taskDir);
  }
  return candidates;
}

function renderReportsSection(summary: InboxTaskSummary): string {
  const candidates = reportDirectoryCandidates(summary);
  const reportDir = candidates.find((candidate) => existsSync(candidate));
  const lines = [chalk.bold("Reports")];
  if (!reportDir) {
    lines.push(`No reports found for ${summary.taskId}/${summary.runId}.`);
    if (candidates.length > 0) lines.push(...candidates.map((candidate) => `checked: ${candidate}`));
    return lines.join("\n");
  }
  lines.push(`Directory: ${reportDir}`);
  const entries = readdirSync(reportDir, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => {
      const path = join(reportDir, entry.name);
      const stat = statSync(path);
      return { name: entry.name, path, stat };
    })
    .sort((a, b) => b.stat.mtimeMs - a.stat.mtimeMs);
  if (entries.length === 0) {
    lines.push("No report files found.");
    return lines.join("\n");
  }
  for (const entry of entries.slice(0, 10)) {
    lines.push(`${entry.name}: ${entry.stat.size} bytes, updated ${relativeTime(entry.stat.mtime.toISOString())}`);
  }
  return lines.join("\n");
}

export async function selectReportInteractive(summary: InboxTaskSummary): Promise<void> {
  const candidates = reportDirectoryCandidates(summary);
  const reportDir = candidates.find((candidate) => existsSync(candidate));
  if (!reportDir) {
    console.log(chalk.yellow("No report directory found for this task/run."));
    if (candidates.length > 0) {
      console.log("Checked directories:");
      for (const candidate of candidates) {
        console.log(`  ${candidate}`);
      }
    }
    return;
  }
  const entries = readdirSync(reportDir, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => {
      const path = join(reportDir, entry.name);
      const stat = statSync(path);
      return { name: entry.name, path, stat };
    })
    .sort((a, b) => b.stat.mtimeMs - a.stat.mtimeMs);
  if (entries.length === 0) {
    console.log(chalk.yellow("No report files found in directory:"));
    console.log(`  ${reportDir}`);
    return;
  }
  console.log(chalk.bold("\nAvailable report files in:"));
  console.log(`  ${reportDir}\n`);
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i];
    const sizeKB = (entry.stat.size / 1024).toFixed(1);
    console.log(`  ${chalk.green(i + 1)}. ${entry.name} (${sizeKB} KB)`);
  }
  console.log();
  const rl = createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  const prompt = (): Promise<string> =>
    new Promise((resolve) => {
      rl.question(chalk.cyan("Enter number to open (or press Enter to cancel): "), (answer) => {
        resolve(answer.trim());
      });
    });
  try {
    const answer = await prompt();
    if (!answer) {
      console.log(chalk.dim("Cancelled."));
      return;
    }
    // Validate that the input is a valid positive integer (no trailing characters)
    if (!/^[1-9]\d*$/.test(answer)) {
      console.log(chalk.red(`Invalid selection. Must be a number between 1 and ${entries.length}.`));
      return;
    }
    const index = parseInt(answer, 10);
    if (index < 1 || index > entries.length) {
      console.log(chalk.red(`Invalid selection. Must be a number between 1 and ${entries.length}.`));
      return;
    }
    const selected = entries[index - 1];
    console.log(chalk.dim(`Opening ${selected.name} in ${resolveEditor()}...`));
    const spawnResult = spawnSync(resolveEditor(), [selected.path], {
      stdio: "inherit",
    });
    // Handle spawn failures where status is null but error is present (e.g., ENOENT)
    if (spawnResult.error) {
      console.log(chalk.red(`Failed to launch editor: ${spawnResult.error.message}`));
      return;
    }
    const exitCode = spawnResult.status ?? 0;
    if (exitCode !== 0) {
      console.log(chalk.yellow(`Editor exited with code ${exitCode}.`));
    }
  } finally {
    rl.close();
  }
}

function renderFilesSection(summary: InboxTaskSummary): string {
  const lines = [chalk.bold("Files")];
  if (!summary.worktreePath) {
    lines.push("No files found: no worktree path recorded for this run.");
    return lines.join("\n");
  }
  lines.push(`Worktree: ${summary.worktreePath}`);
  if (!existsSync(summary.worktreePath)) {
    lines.push("No files found: worktree path does not exist.");
    return lines.join("\n");
  }
  try {
    const backend = VcsBackendFactory.createSync({ backend: "auto" }, summary.worktreePath);
    const output = backend.statusSync(summary.worktreePath);
    const changed = output.split("\n").filter((line) => line.trim().length > 0);
    if (changed.length === 0) {
      lines.push("Worktree clean.");
    } else {
      lines.push("Changed files:");
      lines.push(...changed.slice(0, 20));
      if (changed.length > 20) lines.push(`… ${changed.length - 20} more`);
    }
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    lines.push(`Unable to read git status: ${truncate(message, 120)}`);
  }
  return lines.join("\n");
}

function selectRecentChronological<T>(items: T[], limit: number, timestamp: (item: T) => string): T[] {
  if (limit <= 0) return [];
  return [...items]
    .sort((a, b) => timestampMs(timestamp(a)) - timestampMs(timestamp(b)))
    .slice(Math.max(0, items.length - limit));
}

export async function renderTaskDetail(summary: InboxTaskSummary, options: { messages: boolean; events: boolean; logs?: boolean; reports?: boolean; files?: boolean; limit: number; eventsLimit: number }): Promise<string> {
  const lines = [
    chalk.bold(`FOREMAN INBOX › ${summary.taskId}`),
    `Run:      ${summary.runId}`,
    `State:    ${summary.runStatus}`,
    `Phase:    ${summary.phase}`,
    `Activity: ${relativeTime(summary.lastActivityAt)} via ${summary.lastActivitySource}`,
    `Verdict:  ${summary.verdict}`,
    `Status:   ${summary.statusText}`,
  ];
  if (options.events) {
    lines.push("", chalk.bold("Recent Events"));
    const events = selectRecentChronological(summary.events, options.eventsLimit, (event) => event.createdAt);
    lines.push(events.length > 0 ? renderPipelineEventsTable(events, 80) : "No events found.");
  }
  if (options.messages) {
    lines.push("", chalk.bold("Recent Messages"));
    const messages = selectRecentMessages(summary.messages, options.limit);
    lines.push(messages.length > 0 ? renderInboxMessagesTable(messages) : "No messages found.");
  }
  if (options.logs) lines.push("", await renderLogSection(summary));
  if (options.reports) lines.push("", renderReportsSection(summary));
  if (options.files) lines.push("", renderFilesSection(summary));
  return lines.join("\n");
}


async function renderInteractiveInbox(sources: InboxSources, projectLabel: string, options: { agent?: string; unread?: boolean; limit: number; eventsLimit: number; scope: InboxScope; initialView?: SuperTuiView; initialTaskId?: string | null; initialRunId?: string | null; refreshIntervalMs?: number }): Promise<void> {
  const loadSummaries = (): Promise<InboxTaskSummary[]> => loadInboxOverview(sources, {
    scope: options.scope,
    agent: options.agent,
    unread: options.unread,
    limit: options.limit,
    eventsLimit: options.eventsLimit,
  });
  const summaries = await loadSummaries();
  const adapter: SuperTuiDataAdapter = {
    projectLabel,
    initialSummaries: summaries,
    loadSummaries,
    scope: options.scope === "terminal" ? "all" : options.scope,
  };
  await runSuperTui({
    adapter,
    initialView: options.initialView ?? "inbox",
    initialTaskId: options.initialTaskId,
    initialRunId: options.initialRunId,
    limit: options.limit,
    eventsLimit: options.eventsLimit,
    renderTaskDetail,
    refreshIntervalMs: options.refreshIntervalMs,
  });
}

export async function runInboxSuperTuiForProject(projectPath: string, projectLabel: string, options: { projectSelector?: string; agent?: string; unread?: boolean; limit: number; eventsLimit: number; scope?: InboxScope; initialView?: SuperTuiView; initialTaskId?: string | null; initialRunId?: string | null; refreshIntervalMs?: number }): Promise<void> {
  const sources = await resolveInboxSources(projectPath, options.projectSelector);
  try {
    await renderInteractiveInbox(sources, projectLabel, {
      agent: options.agent,
      unread: options.unread,
      limit: options.limit,
      eventsLimit: options.eventsLimit,
      scope: options.scope ?? "attention",
      initialView: options.initialView,
      initialTaskId: options.initialTaskId,
      initialRunId: options.initialRunId,
      refreshIntervalMs: options.refreshIntervalMs,
    });
  } finally {
    sources.store?.close();
  }
}

async function resolveDetailRunId(sources: InboxSources, selector: { task?: string; run?: string }): Promise<string | null> {
  return sources.postgres
    ? await resolvePostgresRunId(sources.postgres.adapter, sources.postgres.projectId, selector)
    : sources.daemon
      ? await resolveDaemonRunId(sources.daemon, selector)
      : selector.run
        ?? (selector.task && sources.store ? resolveRunIdByTask(sources.store, selector.task) : null);
}

async function loadTaskDetailSummary(
  sources: InboxSources,
  selector: { task?: string; run?: string },
  options: Pick<InboxTaskDetailOptions, "agent" | "unread" | "limit" | "eventsLimit">,
): Promise<{ runId: string; summary: InboxTaskSummary | null }> {
  const runId = await resolveDetailRunId(sources, selector);
  if (!runId) return { runId: "", summary: null };
  const runs = await listRunsForSources(sources);
  const messages = await fetchMessagesForSources(sources, {
    runId,
    agent: options.agent,
    unread: options.unread,
    limit: Math.max(options.limit, 500),
  });
  let events: PipelineEvent[] = [];
  try {
    events = await fetchEventsForSources(sources, { runId, limit: options.eventsLimit });
  } catch {
    events = [];
  }
  const boundedMessages = selectRecentMessages(messages, options.limit);
  const boundedEvents = [...events]
    .sort((a, b) => timestampMs(b.createdAt) - timestampMs(a.createdAt))
    .slice(0, options.eventsLimit);
  const summaries = buildInboxTaskSummaries({ runs, messages: boundedMessages, events: boundedEvents }, "all");
  return {
    runId,
    summary: findSummaryForRunOrTask(summaries, { run: runId }) ?? findSummaryForRunOrTask(summaries, { task: selector.task }) ?? summaries[0] ?? null,
  };
}

async function followInboxTaskOrRunDetail(
  sources: InboxSources,
  selector: { task?: string; run?: string },
  options: InboxTaskDetailOptions,
): Promise<void> {
  const renderSnapshot = async (): Promise<void> => {
    const { runId, summary } = await loadTaskDetailSummary(sources, selector, options);
    if (!summary) {
      console.log(`No messages or events found for run ${runId || selector.run || selector.task || "unknown"}.`);
      return;
    }
    console.log("");
    console.log(chalk.dim(`── refresh ${new Date().toLocaleTimeString()} ──`));
    console.log(await renderTaskDetail(summary, options));
  };
  console.log(`Following inbox detail for ${selector.task ? `task ${selector.task}` : `run ${selector.run}`}... (Ctrl-C to stop)`);
  await renderSnapshot();
  const interval = setInterval(() => { void renderSnapshot().catch(() => undefined); }, 2000);
  process.on("SIGINT", () => {
    clearInterval(interval);
    process.exit(0);
  });
}

async function renderInboxTaskOrRunDetail(
  sources: InboxSources,
  selector: { task?: string; run?: string },
  options: InboxTaskDetailOptions,
): Promise<void> {
  const optionError = validateInboxDetailOptions(options);
  if (optionError) {
    console.error(optionError);
    process.exit(1);
    return;
  }
  if (options.follow) {
    await followInboxTaskOrRunDetail(sources, selector, options);
    return;
  }
  const { runId, summary } = await loadTaskDetailSummary(sources, selector, options);
  if (!runId) {
    console.error("No matching run found.");
    process.exit(1);
    return;
  }
  if (!summary) {
    console.log(`No messages or events found for run ${runId}.`);
    return;
  }
  if (options.selectReport) {
    await selectReportInteractive(summary);
    return;
  }
  console.log(await renderTaskDetail(summary, options));
}

export function adaptDaemonRun(row: DaemonRunRow): Run {
  return {
    id: row.id,
    project_id: "",
    task_id: row.task_id,
    agent_type: "daemon",
    session_key: null,
    worktree_path: row.worktree_path ?? null,
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
  return [...messages]
    .sort((a, b) => timestampMs(a.created_at) - timestampMs(b.created_at))
    .slice(Math.max(0, messages.length - limit));
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
        created_at: normalizedIso(row.created_at ?? new Date().toISOString()) ?? new Date().toISOString(),
        deleted_at: null,
      }))
      .filter((row) => (options.all || !options.runId || row.run_id === options.runId) && (!options.agent || row.recipient_agent_type === options.agent));
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

interface InboxSources {
  daemon: InboxClientContext | null;
  postgres: { adapter: BackendInboxAdapter; projectId: string } | null;
  store: ForemanStore | null;
}

async function resolveInboxSources(projectPath: string, projectSelector?: string): Promise<InboxSources> {
  const daemon = await resolveDaemonInboxContext(projectPath, projectSelector);
  const postgres = process.env.FOREMAN_ENABLE_INBOX_POSTGRES === "1"
    ? await resolvePostgresInboxProject(projectPath, projectSelector)
    : null;
  return {
    daemon,
    postgres,
    store: daemon || postgres ? null : ForemanStore.forProject(projectPath),
  };
}

async function listRunsForSources(sources: InboxSources, limit = 100): Promise<Run[]> {
  if (sources.postgres) return (await sources.postgres.adapter.listRuns(sources.postgres.projectId, { limit })).map(adaptPostgresRun);
  if (sources.daemon) return listDaemonRuns(sources.daemon);
  return sources.store ? getInboxStatusRuns(sources.store) : [];
}

async function fetchMessagesForSources(
  sources: InboxSources,
  options: { all?: boolean; runId?: string; agent?: string; unread?: boolean; limit: number },
): Promise<Message[]> {
  if (sources.postgres) {
    return fetchPostgresMessages(sources.postgres.adapter, sources.postgres.projectId, options);
  }
  if (sources.daemon) return fetchDaemonMessages(sources.daemon, options);
  if (!sources.store) return [];
  if (options.all) return sources.store.getAllMessagesGlobal(options.limit);
  if (!options.runId) return [];
  return fetchMessages(sources.store, options.runId, options.agent, options.unread ?? false, options.limit);
}

async function fetchEventsForSources(
  sources: InboxSources,
  options: { all?: boolean; runId?: string; limit: number },
): Promise<PipelineEvent[]> {
  if (sources.postgres) {
    return fetchPostgresEvents(sources.postgres.adapter, sources.postgres.projectId, options);
  }
  if (sources.daemon) return fetchDaemonEvents(sources.daemon, options);
  if (!sources.store) return [];
  if (options.all) return fetchEventsFromStore(sources.store, options.limit);
  return options.runId ? fetchEventsFromStoreForRun(sources.store, options.runId, options.limit) : [];
}

async function loadInboxOverview(
  sources: InboxSources,
  options: { scope: InboxScope; agent?: string; unread?: boolean; limit: number; eventsLimit: number },
): Promise<InboxTaskSummary[]> {
  const runs = await listRunsForSources(sources, Math.max(options.limit, 100));
  const messages = await fetchMessagesForSources(sources, {
    all: true,
    agent: options.agent,
    unread: options.unread,
    limit: Math.max(options.limit, 500),
  });
  let events: PipelineEvent[] = [];
  try {
    events = await fetchEventsForSources(sources, {
      all: true,
      limit: Math.max(options.eventsLimit, 500),
    });
  } catch {
    events = [];
  }
  const messageRunIds = new Set(messages.map((message) => message.run_id));
  const eventRunIds = new Set(events.map((event) => event.runId).filter((runId): runId is string => Boolean(runId)));
  const activeRuns = runs.filter((run) => isActiveRunStatus(runStatusText(run)));
  const missingActiveRuns = activeRuns.filter((run) => !messageRunIds.has(run.id) || !eventRunIds.has(run.id));
  const activeMessages = await Promise.all(
    missingActiveRuns
      .filter((run) => !messageRunIds.has(run.id))
      .map((run) => fetchMessagesForSources(sources, { runId: run.id, agent: options.agent, unread: options.unread, limit: 50 })),
  );
  const activeEvents = await Promise.all(
    missingActiveRuns
      .filter((run) => !eventRunIds.has(run.id))
      .map(async (run) => {
        try {
          return await fetchEventsForSources(sources, { runId: run.id, limit: 100 });
        } catch {
          return [];
        }
      }),
  );
  return buildInboxTaskSummaries({
    runs,
    messages: [...messages, ...activeMessages.flat()],
    events: [...events, ...activeEvents.flat()],
  }, options.scope);
}

function findSummaryForRunOrTask(summaries: InboxTaskSummary[], selector: { task?: string; run?: string }): InboxTaskSummary | undefined {
  return summaries.find((summary) => {
    if (selector.task && summary.taskId === selector.task) return true;
    return Boolean(selector.run && summary.runId === selector.run);
  });
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
        worktree_path: typeof run.worktree_path === "string" ? run.worktree_path : null,
        status: String(run.status ?? "running") as Run["status"],
        started_at: normalizedIso(run.started_at),
        completed_at: normalizedIso(run.completed_at),
        created_at: normalizedIso(run.created_at) ?? "1970-01-01T00:00:00.000Z",
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
        details: parseRecordPayload(row.details),
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
    details: parseRecordPayload(row.details),
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

export type InboxDetailCommandOptions = {
  agent?: string;
  unread?: boolean;
  limit?: string;
  project?: string;
  projectPath?: string;
  messages?: boolean;
  events?: boolean;
  logs?: boolean;
  reports?: boolean;
  selectReport?: boolean;
  files?: boolean;
  follow?: boolean;
  eventsLimit?: string;
  "events-limit"?: string;
  interactive?: boolean;
};

export type InboxDetailRoute = "cockpit" | "detail";

export function validateInboxDetailOptions(options: Pick<InboxDetailCommandOptions, "follow" | "selectReport">): string | null {
  const isReportSelectionFollowMode = options.follow === true && options.selectReport === true;
  if (!isReportSelectionFollowMode) return null;
  return "--follow and --select-report cannot be used together. Use --select-report without --follow to choose a report.";
}

export function resolveInboxDetailRoute(options: Pick<InboxDetailCommandOptions, "interactive">): InboxDetailRoute {
  return options.interactive === true ? "cockpit" : "detail";
}

export type InboxOverviewRoute = "cockpit" | "scriptable";

export interface InboxOverviewRouteOptions {
  run?: string;
  task?: string;
  all?: boolean;
  watch?: boolean;
  events?: boolean;
  compact?: boolean;
  full?: boolean;
  ack?: boolean;
  agent?: string;
  unread?: boolean;
  interactive?: boolean;
  nonInteractive?: boolean;
}

export function resolveInboxOverviewRoute(options: InboxOverviewRouteOptions, stdoutIsTTY: boolean | undefined): InboxOverviewRoute {
  const hasExplicitMode = Boolean(
    options.run || options.task || options.all || options.watch || options.events
    || options.compact || options.full || options.ack || options.agent || options.unread,
  );
  const isImplicitTtyOverview =
    stdoutIsTTY === true && options.nonInteractive !== true && !hasExplicitMode;
  return options.interactive === true || isImplicitTtyOverview
    ? "cockpit"
    : "scriptable";
}

async function resolveSourcesForCommand(options: { project?: string; projectPath?: string }): Promise<{ sources: InboxSources; projectPath: string }> {
  let projectPath: string;
  try {
    projectPath = await resolveRepoRootProjectPath({
      project: options.project,
      projectPath: options.projectPath,
    });
  } catch {
    projectPath = process.cwd();
  }
  return { sources: await resolveInboxSources(projectPath, options.project), projectPath };
}

function parsePositiveIntOption(value: string | undefined, fallback: number): number {
  const parsed = Number.parseInt(value ?? String(fallback), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

async function resolveInboxProjectPath(options: { project?: string; projectPath?: string }): Promise<string> {
  try {
    return await resolveRepoRootProjectPath({
      project: options.project,
      projectPath: options.projectPath,
    });
  } catch {
    return process.cwd();
  }
}

const inboxTaskCommand = new Command("task")
  .description("Show scriptable task inbox detail; add --interactive for the cockpit")
  .argument("<task-id>", "Task ID")
  .option("--agent <name>", "Filter messages to a specific recipient agent")
  .option("--unread", "Show only unread messages")
  .option("--limit <n>", "Max messages to show", "50")
  .option("--events", "Show recent pipeline events", true)
  .option("--messages", "Show recent inbox messages", true)
  .option("--events-limit <n>", "Max pipeline events to show", "50")
  .option("--logs", "Show log file paths, stats, and recent error log lines")
  .option("--reports", "Show report artifact directory and files")
  .option("--select-report", "Interactively select a report file to open in $EDITOR")
  .option("--files", "Show worktree path and changed files")
  .option("--follow", "Refresh task inbox detail every 2 seconds")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .option("--interactive", "Open the unified cockpit with this task selected")
  .action(async (taskId: string, options: InboxDetailCommandOptions) => {
    const optionError = validateInboxDetailOptions(options);
    if (optionError) {
      console.error(optionError);
      process.exit(1);
      return;
    }
    if (resolveInboxDetailRoute(options) === "cockpit") {
      const projectPath = await resolveInboxProjectPath(options);
      await runInboxSuperTuiForProject(projectPath, options.project ?? projectPath, {
        projectSelector: options.project,
        agent: options.agent,
        unread: options.unread,
        limit: parsePositiveIntOption(options.limit, 50),
        eventsLimit: parsePositiveIntOption(options.eventsLimit ?? options["events-limit"], 50),
        scope: "all",
        initialView: "inbox",
        initialTaskId: taskId,
      });
      return;
    }
    const { sources } = await resolveSourcesForCommand(options);
    await renderInboxTaskOrRunDetail(sources, { task: taskId }, {
      agent: options.agent,
      unread: options.unread,
      limit: parsePositiveIntOption(options.limit, 50),
      eventsLimit: parsePositiveIntOption(options.eventsLimit ?? options["events-limit"], 50),
      messages: options.messages ?? true,
      events: options.events ?? true,
      logs: options.logs ?? false,
      reports: options.reports ?? false,
      selectReport: options.selectReport ?? false,
      files: options.files ?? false,
      follow: options.follow ?? false,
    });
  });

const inboxRunCommand = new Command("run")
  .description("Show scriptable run inbox detail; add --interactive for the cockpit")
  .argument("<run-id>", "Run ID")
  .option("--agent <name>", "Filter messages to a specific recipient agent")
  .option("--unread", "Show only unread messages")
  .option("--limit <n>", "Max messages to show", "50")
  .option("--events", "Show recent pipeline events", true)
  .option("--messages", "Show recent inbox messages", true)
  .option("--events-limit <n>", "Max pipeline events to show", "50")
  .option("--logs", "Show log file paths, stats, and recent error log lines")
  .option("--reports", "Show report artifact directory and files")
  .option("--select-report", "Interactively select a report file to open in $EDITOR")
  .option("--files", "Show worktree path and changed files")
  .option("--follow", "Refresh run inbox detail every 2 seconds")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .option("--interactive", "Open the unified cockpit with this run selected")
  .action(async (runId: string, options: InboxDetailCommandOptions) => {
    const optionError = validateInboxDetailOptions(options);
    if (optionError) {
      console.error(optionError);
      process.exit(1);
      return;
    }
    if (resolveInboxDetailRoute(options) === "cockpit") {
      const projectPath = await resolveInboxProjectPath(options);
      await runInboxSuperTuiForProject(projectPath, options.project ?? projectPath, {
        projectSelector: options.project,
        agent: options.agent,
        unread: options.unread,
        limit: parsePositiveIntOption(options.limit, 50),
        eventsLimit: parsePositiveIntOption(options.eventsLimit ?? options["events-limit"], 50),
        scope: "all",
        initialView: "inbox",
        initialRunId: runId,
      });
      return;
    }
    const { sources } = await resolveSourcesForCommand(options);
    await renderInboxTaskOrRunDetail(sources, { run: runId }, {
      agent: options.agent,
      unread: options.unread,
      limit: parsePositiveIntOption(options.limit, 50),
      eventsLimit: parsePositiveIntOption(options.eventsLimit ?? options["events-limit"], 50),
      messages: options.messages ?? true,
      events: options.events ?? true,
      logs: options.logs ?? false,
      reports: options.reports ?? false,
      selectReport: options.selectReport ?? false,
      files: options.files ?? false,
      follow: options.follow ?? false,
    });
  });
export { formatMessage };

export const inboxCommand = new Command("inbox").enablePositionalOptions()
  .description("View Agent Mail; TTY opens the unified cockpit inbox view")
  .addCommand(inboxSendCommand)
  .addCommand(inboxTaskCommand)
  .addCommand(inboxRunCommand)
  .option("--agent <name>", "Filter to a specific agent/role (default: show all)")
  .option("--run <id>", "Filter to a specific run ID (default: latest run)")
  .option("--task <id>", "Resolve run by task ID (uses most recent run for that task)")
  .option("--all", "Show/watch task-first output across all runs (ignores --run and --task)")
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
  .option("--events-limit <n>", "Max pipeline events to show", "50")
  .option("--interactive", "Open the unified cockpit with the selected task/run/inbox view")
  .option("--non-interactive", "Force scriptable output even when stdout is a TTY")
  .option("--scope <scope>", "Task summary scope: active, attention, all, terminal", "attention")
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
    interactive?: boolean;
    nonInteractive?: boolean;
    scope?: string;
  }) => {
    const fullPayload = options.full ?? false;
    const limit = parseInt(options.limit ?? "50", 10);
    const eventsLimit = parseInt(options.eventsLimit ?? options["events-limit"] ?? "50", 10);
    const showEvents = options.events ?? false;
    const compactOutput = options.compact ?? false;
    const groupedEvents = options.grouped ?? false;
    const taskFilter = options.task;
    const scope: InboxScope = options.scope === "active" || options.scope === "all" || options.scope === "terminal"
      ? options.scope
      : "attention";

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

    const sources = await resolveInboxSources(projectPath, options.project);
    const { daemon, postgres, store } = sources;
    if (resolveInboxOverviewRoute(options, process.stdout.isTTY) === "cockpit") {
      await renderInteractiveInbox(sources, options.project ?? projectPath, {
        agent: options.agent,
        unread: options.unread,
        limit,
        eventsLimit,
        scope,
      });
      return;
    }

    try {
      // ── One-shot global mode (--all without --watch) ───────────────────────
      if (options.all && !options.watch) {
        let messages = await fetchMessagesForSources(sources, {
          all: true,
          agent: options.agent,
          unread: options.unread,
          limit,
        });

        // Store-backed fallback filtering mirrors daemon/postgres filtering.
        if (!daemon && !postgres && options.agent) {
          messages = messages.filter((m) => m.recipient_agent_type === options.agent);
        }
        if (!daemon && !postgres && options.unread) {
          messages = messages.filter((m) => m.read === 0);
        }

        const summaryRuns = await listRunsForSources(sources);
        const chronologicalMessages = [...messages].sort((a, b) => timestampMs(a.created_at) - timestampMs(b.created_at));
        const summaries = await loadInboxOverview(sources, {
          scope: "all",
          agent: options.agent,
          unread: options.unread,
          limit,
          eventsLimit,
        });

        if (messages.length === 0 && summaries.length === 0) {
          console.log(`No ${options.unread ? "unread " : ""}messages found across all runs${options.agent ? ` (agent: ${options.agent})` : ""}.`);
        } else {
          console.log(renderRunProgressSummary(chronologicalMessages, summaryRuns));
          if (chronologicalMessages.length > 0) {
            console.log("");
            console.log(renderRecentActivity(chronologicalMessages.slice(-Math.min(chronologicalMessages.length, 12))));
          }
          if (summaries.length > 0) {
            console.log("");
            console.log(renderInboxTaskSummaryTable(summaries));
          }
          console.log("");
          if (fullPayload && messages.length > 0) {
            console.log(`\nInbox — all runs${options.agent ? `  agent: ${options.agent}` : ""}\n${"─".repeat(70)}`);
            for (const msg of messages) {
              console.log(formatMessage(msg, true));
              console.log("");
            }
            console.log(`${"─".repeat(70)}\n${messages.length} message(s) shown.`);
          } else if (messages.length > 0) {
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
          const events = await fetchEventsForSources(sources, { all: true, limit: eventsLimit });

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
                console.log(renderFullMessageTableRows(rows));
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
            console.log(renderInboxMessagesTable(messages));
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
              console.log(renderFullMessageTableRows(rows));
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
