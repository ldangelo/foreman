type SummaryMessage = {
  id: string;
  run_id: string;
  sender_agent_type: string;
  recipient_agent_type: string;
  subject: string;
  body: string;
  read: number;
  created_at: string;
};

type SummaryEvent = {
  id: string;
  runId: string | null;
  taskId?: string | null;
  projectId?: string | null;
  eventType: string;
  details: Record<string, unknown> | null;
  createdAt: string;
};

export interface InboxTimelineSummary {
  taskId: string;
  runId: string;
  runStatus: string;
  phase: string;
  lastActivityAt: string | null;
  lastActivitySource: string;
  statusText: string;
  attention: boolean;
  attentionReason: string | null;
  verdict: "pass" | "fail" | "retrying" | "blocked" | "unknown";
  projectId: string | null;
  worktreePath: string | null;
  messages: SummaryMessage[];
  events: SummaryEvent[];
}

export type InboxTimelineKind = "message" | "event";
export type InboxTimelineTone = "neutral" | "muted" | "info" | "success" | "warning" | "danger";

export interface InboxTimelineItem {
  id: string;
  kind: InboxTimelineKind;
  createdAt: string;
  taskId: string | null;
  phase: string | null;
  actor: string | null;
  target: string | null;
  label: string;
  detail: string | null;
  tone: InboxTimelineTone;
}

export interface BuildInboxTimelineOptions {
  limit?: number;
}

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
  argsPreview?: string;
  command?: string;
  path?: string;
  instructions?: string;
  traceFile?: string;
  commandHonored?: boolean;
  verdict?: string;
  body?: string;
}

export function buildInboxTimeline(
  summary: InboxTimelineSummary,
  options: BuildInboxTimelineOptions = {},
): InboxTimelineItem[] {
  const messages = summary.messages.map((message) => timelineItemFromMessage(summary, message));
  const events = summary.events.map((event) => timelineItemFromEvent(summary, event));
  const items = [...messages, ...events].sort(compareTimelineItemsOldestFirst);

  return typeof options.limit === "number" && options.limit >= 0
    ? items.slice(Math.max(items.length - options.limit, 0))
    : items;
}

export function toneForInboxVerdict(verdict: InboxTimelineSummary["verdict"]): InboxTimelineTone {
  switch (verdict) {
    case "pass":
      return "success";
    case "fail":
    case "blocked":
      return "danger";
    case "retrying":
      return "warning";
    case "unknown":
      return "muted";
  }
}

export function toneForRunStatus(status: string | null | undefined): InboxTimelineTone {
  switch ((status ?? "").toLowerCase()) {
    case "completed":
    case "merged":
    case "pr-created":
      return "success";
    case "failed":
    case "stuck":
    case "conflict":
    case "test-failed":
      return "danger";
    case "pending":
    case "running":
    case "in_progress":
    case "cooldown":
      return "info";
    case "reset":
      return "muted";
    default:
      return "neutral";
  }
}

function timelineItemFromMessage(summary: InboxTimelineSummary, message: SummaryMessage): InboxTimelineItem {
  const parsed = parseMessageBody(message.body);
  const phase = parsed.phase ?? phaseFromAgentId(message.sender_agent_type) ?? phaseFromAgentId(message.recipient_agent_type) ?? null;
  const taskId = parsed.taskId ?? projectedMessageTaskId(message) ?? summary.taskId ?? message.run_id;
  const activity = messageActivity(message, parsed, phase);
  const args = messageArgsPreview(parsed);
  const tool = parsed.tool ? ` ${parsed.tool}` : "";
  const kind = parsed.kind ? ` ${parsed.kind}` : "";
  const label = `Mail${kind}${tool}`;
  const route = `${displayAgent(message.sender_agent_type)} → ${displayAgent(message.recipient_agent_type)}`;
  const detail = args && args !== activity
    ? `${route}: ${activity} — ${truncate(args, 140)}`
    : `${route}: ${activity}`;

  return {
    id: `message:${message.id}`,
    kind: "message",
    createdAt: message.created_at,
    taskId,
    phase,
    actor: displayAgent(message.sender_agent_type),
    target: displayAgent(message.recipient_agent_type),
    label,
    detail,
    tone: toneForMessage(parsed, message),
  };
}

function timelineItemFromEvent(summary: InboxTimelineSummary, event: SummaryEvent): InboxTimelineItem {
  const details = normalizedEventDetails(event);
  const taskId = eventTask(event, details) ?? summary.taskId ?? null;
  const phase = eventPhase(details) ?? null;
  const label = eventKind(event.eventType);
  const detail = formatEventSummary(event.eventType, details);

  return {
    id: `event:${event.id}`,
    kind: "event",
    createdAt: event.createdAt,
    taskId,
    phase,
    actor: eventActor(event.eventType, details),
    target: eventTarget(event, details) ?? taskId,
    label,
    detail: detail === event.eventType ? null : detail,
    tone: toneForEvent(event.eventType, details),
  };
}

function compareTimelineItemsOldestFirst(a: InboxTimelineItem, b: InboxTimelineItem): number {
  const delta = timestampMs(a.createdAt) - timestampMs(b.createdAt);
  if (delta !== 0) return delta;
  const kindOrder = a.kind.localeCompare(b.kind);
  if (kindOrder !== 0) return kindOrder;
  return a.id.localeCompare(b.id);
}

function timestampMs(value: unknown): number {
  if (typeof value === "string" || typeof value === "number" || value instanceof Date) {
    const ms = new Date(value).getTime();
    return Number.isFinite(ms) ? ms : 0;
  }
  return 0;
}

function parseMessageBody(body: string): ParsedMessageBody {
  if (!body) return {};
  try {
    const parsed = JSON.parse(body) as Record<string, unknown>;
    return {
      phase: stringField(parsed, "phase"),
      status: stringField(parsed, "status"),
      error: stringField(parsed, "error"),
      currentPhase: stringField(parsed, "currentPhase"),
      taskId: stringField(parsed, "taskId"),
      runId: stringField(parsed, "runId"),
      message: stringField(parsed, "message"),
      kind: stringField(parsed, "kind"),
      tool: stringField(parsed, "tool"),
      argsPreview: stringField(parsed, "argsPreview"),
      command: stringField(parsed, "command"),
      path: stringField(parsed, "path"),
      instructions: stringField(parsed, "instructions"),
      traceFile: stringField(parsed, "traceFile"),
      commandHonored: typeof parsed["commandHonored"] === "boolean" ? parsed["commandHonored"] : undefined,
      verdict: stringField(parsed, "verdict"),
      body: stringField(parsed, "body"),
    };
  } catch {
    return {};
  }
}

function stringField(input: Record<string, unknown>, key: string): string | undefined {
  const value = input[key];
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function phaseFromAgentId(agent: string): string | undefined {
  const known = agent.match(/^(explorer|developer|documentation|repair|qa|reviewer|cli-review|finalize|refinery)(?:-|$)/);
  if (known?.[1]) return known[1];

  const taskSuffixed = agent.match(/^(.+)-foreman-[a-z0-9]+$/i);
  if (taskSuffixed?.[1] && taskSuffixed[1] !== "overwatch") return taskSuffixed[1];

  return undefined;
}

function displayAgent(agent: string): string {
  return phaseFromAgentId(agent) ?? agent;
}

function projectedMessageTaskId(message: SummaryMessage): string | undefined {
  const value: object = message;
  if ("task_id" in value && typeof value.task_id === "string") return value.task_id;
  return undefined;
}

function messageActivity(message: SummaryMessage, parsed: ParsedMessageBody, phase: string | null): string {
  const parts: string[] = [];
  const subject = singleLine(message.subject);
  if (parsed.message && !parsed.error) {
    parts.push(truncate(parsed.message, 120));
  } else if (subject) {
    parts.push(subject);
  }
  if (phase) parts.push(`phase=${phase}`);
  if (parsed.kind) parts.push(`kind=${parsed.kind}`);
  if (parsed.status) parts.push(`status=${parsed.status}`);
  if (parsed.verdict) parts.push(`verdict=${parsed.verdict}`);
  if (parsed.tool) parts.push(`tool=${parsed.tool}`);
  if (parsed.commandHonored !== undefined) parts.push(`honored=${parsed.commandHonored ? "yes" : "no"}`);
  if (parsed.error) parts.push(`error=${truncate(parsed.error, 120)}`);
  return parts.length > 0 ? parts.join(" ") : message.subject;
}

function messageArgsPreview(parsed: ParsedMessageBody): string | undefined {
  const candidate = parsed.argsPreview
    ?? parsed.command
    ?? parsed.path
    ?? parsed.instructions
    ?? parsed.message
    ?? parsed.body;
  return candidate ? singleLine(displayArgsPayload(candidate)) : undefined;
}

function displayArgsPayload(value: string): string {
  try {
    const parsed = JSON.parse(value) as Record<string, unknown>;
    const args = parsed["args"];
    if (args && typeof args === "object" && !Array.isArray(args)) {
      const nested = args as Record<string, unknown>;
      const command = stringField(nested, "command");
      if (command) return command;
      const path = stringField(nested, "path");
      if (path) return path;
    }
    return stringField(parsed, "command")
      ?? stringField(parsed, "path")
      ?? stringField(parsed, "instructions")
      ?? stringField(parsed, "message")
      ?? stringField(parsed, "body")
      ?? value;
  } catch {
    return value;
  }
}

function singleLine(value: string): string {
  return value.replace(/[\r\n\t]+/g, " ").replace(/\s{2,}/g, " ").trim();
}

function normalizedEventDetails(event: SummaryEvent): Record<string, unknown> | null {
  return event.details ? {
    ...event.details,
    task_id: event.details.task_id ?? event.taskId,
    run_id: event.details.run_id ?? event.runId,
    project_id: event.details.project_id ?? event.projectId,
  } : null;
}

function detailString(details: Record<string, unknown>, keys: string[]): string | undefined {
  for (const key of keys) {
    const value = details[key];
    if (typeof value === "string" && value.length > 0) return value;
    if (typeof value === "number") return String(value);
  }
  return undefined;
}

function eventPhase(details: Record<string, unknown> | null): string | undefined {
  return details ? detailString(details, ["phase_id", "phase", "current_phase"]) : undefined;
}

function eventTask(event: SummaryEvent, details: Record<string, unknown> | null): string | undefined {
  return details ? detailString(details, ["task_id", "taskId"]) : event.taskId ?? undefined;
}

function eventTarget(event: SummaryEvent, details: Record<string, unknown> | null): string | undefined {
  if (!details) return event.runId ?? undefined;
  const taskId = detailString(details, ["task_id", "taskId"]);
  if (taskId) return `task ${taskId}`;
  const runId = detailString(details, ["run_id", "runId"]);
  return runId ? `run ${runId}` : event.runId ?? undefined;
}

function eventActor(eventType: string, details: Record<string, unknown> | null): string | null {
  if (eventType === "PhaseNudged" || eventType === "phase-nudge") return "overwatch";
  if (eventType.startsWith("Worker")) return "worker";
  if (eventType.startsWith("ToolCall")) return detailString(details ?? {}, ["tool_name", "toolName"]) ?? "tool";
  if (eventType === "AssistantMessage") return "assistant";
  return null;
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

function toneForMessage(parsed: ParsedMessageBody, message: SummaryMessage): InboxTimelineTone {
  const verdict = parsed.verdict?.toLowerCase();
  const status = parsed.status?.toLowerCase();
  const kind = parsed.kind?.toLowerCase();
  const subject = message.subject.toLowerCase();
  if (parsed.error || verdict === "fail" || status === "fail" || kind === "denied" || kind === "error") return "danger";
  if (verdict === "pass" || status === "pass" || kind === "approved") return "success";
  if (subject.includes("retry")) return "warning";
  return message.read === 1 ? "muted" : "info";
}

function toneForEvent(eventType: string, details: Record<string, unknown> | null): InboxTimelineTone {
  const status = details ? detailString(details, ["status", "outcome", "verdict"])?.toLowerCase() : undefined;
  if (
    eventType === "RunFailed"
    || eventType === "WorkerLaunchFailed"
    || eventType === "PhaseFailed"
    || eventType === "ToolCallDenied"
    || eventType === "fail"
    || eventType === "test-fail"
    || eventType === "conflict"
    || eventType === "stuck"
    || status === "fail"
    || status === "failed"
    || status === "error"
  ) return "danger";
  if (eventType === "PhaseRetried") return "warning";
  if (eventType === "PhaseSkipped") return "muted";
  if (
    eventType === "PhaseCompleted"
    || eventType === "phase-complete"
    || eventType === "PhaseVerdict"
    || eventType === "PhaseReportProduced"
    || eventType === "complete"
    || eventType === "merge"
    || eventType === "Merge"
    || eventType === "pr-created"
    || status === "pass"
    || status === "passed"
    || status === "success"
  ) return "success";
  if (eventType.startsWith("ToolCall")) return "info";
  return "neutral";
}

function formatEventSummary(eventType: string, details: Record<string, unknown> | null): string {
  if (!details) return eventType;

  const taskId = detailString(details, ["task_id", "taskId"]);
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
      return phase ? `PhaseVerdict ${phase}${verdict ? `: ${verdict}` : ""}${target ? ` for ${target}` : ""}` : eventType;
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
      const body = detailString(details, ["message", "output"]);
      return `Assistant message${phase ? ` in ${phase}` : ""}${body ? `: ${truncate(body, 120)}` : ""}`;
    }
    case "ToolCallRequested": {
      const tool = detailString(details, ["tool_name", "toolName"]) || "tool";
      const path = detailString(details, ["path", "file_path", "filePath"]);
      const args = details.args && typeof details.args === "object" && !Array.isArray(details.args) ? details.args as Record<string, unknown> : undefined;
      const argPath = args ? detailString(args, ["path", "file_path", "filePath", "command", "query"]) : undefined;
      return `Tool ${tool} requested${phase ? ` in ${phase}` : ""}${path || argPath ? `: ${truncate(path || argPath || "", 80)}` : ""}`;
    }
    case "ToolCallApproved": {
      const tool = detailString(details, ["tool_name", "toolName"]) || "tool";
      return `Tool ${tool} approved${phase ? ` in ${phase}` : ""}`;
    }
    case "ToolCallDenied": {
      const tool = detailString(details, ["tool_name", "toolName"]) || "tool";
      return `Tool ${tool} denied${phase ? ` in ${phase}` : ""}${error ? `: ${error}` : ""}`;
    }
    case "ToolCallFinished": {
      const tool = detailString(details, ["tool_name", "toolName"]) || "tool";
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
      return `${eventType}${target ? ` for ${target}` : ""}${error ? `: ${error}` : ""}`;
    default:
      return eventType;
  }
}

function truncate(str: string, maxLen: number): string {
  if (maxLen <= 0) return "";
  if (str.length <= maxLen) return str;
  if (maxLen === 1 || maxLen <= 3) return "…";

  const slice = str.slice(0, maxLen);
  const lastSpace = slice.lastIndexOf(" ");
  if (lastSpace >= maxLen - 4) return str.slice(0, lastSpace) + "…";

  return str.slice(0, maxLen - 1) + "…";
}
