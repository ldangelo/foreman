import type { InboxTaskSummary } from "../commands/inbox.js";

export type WorkflowPhaseStatus = "pending" | "running" | "completed" | "failed" | "retried" | "skipped";
export type WorkflowVerdict = "pass" | "fail" | "retrying" | "blocked" | "unknown";

export interface WorkflowPhaseNode {
  phase: string;
  status: WorkflowPhaseStatus;
  attempt: number | null;
  maxRetries: number | null;
  verdict: WorkflowVerdict;
  startedAt: string | null;
  completedAt: string | null;
  error: string | null;
  artifactPath: string | null;
}

export interface WorkflowRetryEdge {
  from: string;
  to: string;
  attempt: number | null;
  maxRetries: number | null;
  createdAt: string | null;
}

export interface WorkflowActiveAgentSummary {
  runId: string;
  taskId: string;
  status: string;
  phase: string;
  lastActivityAt: string | null;
  lastActivity: string;
}

export interface WorkflowStatusSummary {
  taskId: string;
  runId: string;
  runStatus: string;
  currentPhase: string;
  verdict: WorkflowVerdict;
  phases: WorkflowPhaseNode[];
  retryEdges: WorkflowRetryEdge[];
  activeAgent: WorkflowActiveAgentSummary | null;
  lastActivityAt: string | null;
  lastActivity: string;
  failure: string | null;
  artifactPaths: string[];
}

type SummaryEvent = InboxTaskSummary["events"][number];

type ActiveRunLike = {
  id?: string | null;
  runId?: string | null;
  run_id?: string | null;
  task_id?: string | null;
  taskId?: string | null;
  status?: string | null;
  created_at?: string | null;
  createdAt?: string | null;
  started_at?: string | null;
  startedAt?: string | null;
  queued_at?: string | null;
  queuedAt?: string | null;
};

const PHASE_START = new Set(["phasestarted", "phasestart", "dispatch", "claim"]);
const PHASE_COMPLETE = new Set(["phasecompleted", "phasecomplete", "complete"]);
const PHASE_FAIL = new Set(["phasefailed", "fail", "testfail", "conflict", "stuck"]);
const PHASE_RETRY = new Set(["phaseretried", "phaseretry"]);
const PHASE_SKIP = new Set(["phaseskipped", "phaseskip"]);
const PHASE_VERDICT = new Set(["phaseverdict"]);
const RUN_FAIL = new Set(["runfailed", "workerlaunchfailed"]);
const RUN_COMPLETE = new Set(["runcompleted", "merge", "prcreated"]);
const ACTIVITY_EVENT = new Set(["runprogress", "toolcallrequested", "toolcallapproved", "toolcalldenied", "toolcallfinished", "assistantmessage", "phasestarted", "phasecompleted", "phasefailed", "phaseretried", "phaseverdict"]);

export function buildWorkflowStatusSummary(summary: InboxTaskSummary): WorkflowStatusSummary {
  const nodes = new Map<string, WorkflowPhaseNode>();
  const retryEdges: WorkflowRetryEdge[] = [];
  const events = [...summary.events].sort((a, b) => timestampMs(eventCreatedAt(a)) - timestampMs(eventCreatedAt(b)));
  let failure: string | null = summary.attentionReason;
  let lastActivityAt = summary.lastActivityAt;
  let lastActivity = summary.statusText;

  for (const event of events) {
    const kind = normalizeWorkflowEventType(eventType(event));
    const details = eventDetails(event);
    const phase = phaseFromEvent(event, details) ?? summary.phase;
    const createdAt = eventCreatedAt(event);
    const node = ensureNode(nodes, phase);
    const attempt = numberDetail(details, ["attempt", "retry_attempt", "current_attempt"]);
    const maxRetries = numberDetail(details, ["maxRetries", "max_retries", "max_attempts"]);
    const error = stringDetail(details, ["error", "reason", "message"]);
    const artifactPath = stringDetail(details, ["artifactPath", "artifact_path", "reportPath", "report_path", "path"]);
    const verdict = verdictFromDetails(details);

    if (attempt !== null) node.attempt = attempt;
    if (maxRetries !== null) node.maxRetries = maxRetries;
    if (artifactPath) node.artifactPath = artifactPath;
    if (verdict !== "unknown") node.verdict = verdict;

    if (PHASE_START.has(kind)) {
      node.status = "running";
      node.startedAt = node.startedAt ?? createdAt;
    } else if (PHASE_COMPLETE.has(kind)) {
      node.status = "completed";
      node.completedAt = createdAt;
    } else if (PHASE_FAIL.has(kind)) {
      node.status = "failed";
      node.completedAt = createdAt;
      node.error = error ?? node.error;
      failure = error ?? failure ?? `${phase} failed`;
    } else if (PHASE_RETRY.has(kind)) {
      node.status = "retried";
      node.completedAt = createdAt;
      node.error = error ?? node.error;
      node.verdict = "retrying";
      const target = stringDetail(details, ["retryTarget", "retry_target", "target", "target_phase"]) ?? phase;
      retryEdges.push({ from: phase, to: target, attempt, maxRetries, createdAt });
    } else if (PHASE_SKIP.has(kind)) {
      node.status = "skipped";
      node.completedAt = createdAt;
    } else if (PHASE_VERDICT.has(kind)) {
      node.verdict = verdict;
      if (verdict === "fail" || verdict === "blocked") {
        node.status = "failed";
        node.error = error ?? node.error;
        failure = error ?? failure ?? `${phase} ${verdict}`;
      } else if (verdict === "pass" && node.status !== "failed") {
        node.status = "completed";
      }
    } else if (RUN_FAIL.has(kind)) {
      node.status = node.status === "pending" ? "failed" : node.status;
      failure = error ?? failure ?? summary.statusText;
    } else if (RUN_COMPLETE.has(kind) && node.status === "running") {
      node.status = "completed";
      node.completedAt = createdAt;
    }

    if (timestampMs(createdAt) > timestampMs(lastActivityAt) || (timestampMs(createdAt) === timestampMs(lastActivityAt) && ACTIVITY_EVENT.has(kind))) {
      lastActivityAt = createdAt;
      lastActivity = activityText(kind, details, phase, summary.statusText);
    }
  }

  if (nodes.size === 0) {
    ensureNode(nodes, summary.phase).status = isActiveRunStatus(summary.runStatus) ? "running" : "pending";
  }

  const phases = [...nodes.values()];
  const currentPhase = currentPhaseFromNodes(phases, summary.phase);
  const activeAgent = isActiveRunStatus(summary.runStatus)
    ? {
      runId: summary.runId,
      taskId: summary.taskId,
      status: summary.runStatus,
      phase: currentPhase,
      lastActivityAt,
      lastActivity,
    }
    : null;

  return {
    taskId: summary.taskId,
    runId: summary.runId,
    runStatus: summary.runStatus,
    currentPhase,
    verdict: summary.verdict,
    phases,
    retryEdges,
    activeAgent,
    lastActivityAt,
    lastActivity,
    failure,
    artifactPaths: [...new Set(phases.map((phase) => phase.artifactPath).filter((path): path is string => Boolean(path)))],
  };
}

export function normalizeWorkflowEventType(type: string | null | undefined): string {
  return String(type ?? "")
    .replace(/([a-z0-9])([A-Z])/g, "$1-$2")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "");
}

export function dedupeActiveRunsByRunId<T extends ActiveRunLike>(runs: T[]): T[] {
  const byRunId = new Map<string, T>();
  for (const run of runs) {
    const runId = runIdFromRun(run);
    if (!runId) continue;
    const current = byRunId.get(runId);
    if (!current || activeRunTimestamp(run) >= activeRunTimestamp(current)) {
      byRunId.set(runId, run);
    }
  }
  return [...byRunId.values()].sort((a, b) => activeRunTimestamp(b) - activeRunTimestamp(a));
}

function ensureNode(nodes: Map<string, WorkflowPhaseNode>, phase: string): WorkflowPhaseNode {
  const existing = nodes.get(phase);
  if (existing) return existing;
  const node: WorkflowPhaseNode = {
    phase,
    status: "pending",
    attempt: null,
    maxRetries: null,
    verdict: "unknown",
    startedAt: null,
    completedAt: null,
    error: null,
    artifactPath: null,
  };
  nodes.set(phase, node);
  return node;
}

function currentPhaseFromNodes(nodes: WorkflowPhaseNode[], fallback: string): string {
  return nodes.find((node) => node.status === "running")?.phase
    ?? [...nodes].reverse().find((node) => node.status === "failed" || node.status === "retried")?.phase
    ?? [...nodes].reverse().find((node) => node.status === "completed")?.phase
    ?? fallback;
}

function phaseFromEvent(event: SummaryEvent, details: Record<string, unknown>): string | null {
  return stringDetail(details, ["phase_id", "phase", "current_phase", "currentPhase", "phaseId"])
    ?? (typeof event === "object" && event && "phase" in event && typeof event.phase === "string" ? event.phase : null);
}

function eventType(event: SummaryEvent): string {
  return typeof event === "object" && event && "eventType" in event && typeof event.eventType === "string" ? event.eventType : "";
}

function eventCreatedAt(event: SummaryEvent): string | null {
  return typeof event === "object" && event && "createdAt" in event && typeof event.createdAt === "string" ? event.createdAt : null;
}

function eventDetails(event: SummaryEvent): Record<string, unknown> {
  if (typeof event === "object" && event && "details" in event && event.details && typeof event.details === "object") {
    return event.details as Record<string, unknown>;
  }
  return {};
}

function verdictFromDetails(details: Record<string, unknown>): WorkflowVerdict {
  const verdict = stringDetail(details, ["verdict", "status", "result"])?.toLowerCase();
  if (verdict === "pass" || verdict === "passed" || verdict === "success") return "pass";
  if (verdict === "fail" || verdict === "failed" || verdict === "failure") return "fail";
  if (verdict === "retry" || verdict === "retrying") return "retrying";
  if (verdict === "blocked") return "blocked";
  return "unknown";
}

function activityText(kind: string, details: Record<string, unknown>, phase: string, fallback: string): string {
  const tool = stringDetail(details, ["tool", "tool_name", "name"]);
  const message = stringDetail(details, ["message", "summary", "output", "text", "error", "reason"]);
  if (tool && message) return `${phase}: ${tool} ${message}`;
  if (tool) return `${phase}: ${tool}`;
  if (message) return `${phase}: ${message}`;
  if (kind) return `${phase}: ${kind}`;
  return fallback;
}

function stringDetail(details: Record<string, unknown>, keys: string[]): string | null {
  for (const key of keys) {
    const value = details[key];
    if (typeof value === "string" && value.length > 0) return value;
    if (typeof value === "number" && Number.isFinite(value)) return String(value);
  }
  return null;
}

function numberDetail(details: Record<string, unknown>, keys: string[]): number | null {
  for (const key of keys) {
    const value = details[key];
    if (typeof value === "number" && Number.isFinite(value)) return value;
    if (typeof value === "string" && value.trim().length > 0) {
      const parsed = Number(value);
      if (Number.isFinite(parsed)) return parsed;
    }
  }
  return null;
}

function isActiveRunStatus(status: string): boolean {
  return status === "pending" || status === "running" || status === "in_progress" || status === "cooldown";
}

function runIdFromRun(run: ActiveRunLike): string | null {
  return run.id ?? run.runId ?? run.run_id ?? null;
}

function activeRunTimestamp(run: ActiveRunLike): number {
  return Math.max(
    timestampMs(run.started_at ?? run.startedAt),
    timestampMs(run.queued_at ?? run.queuedAt),
    timestampMs(run.created_at ?? run.createdAt),
  );
}

function timestampMs(value: unknown): number {
  if (typeof value === "string" || typeof value === "number" || value instanceof Date) {
    const ms = new Date(value).getTime();
    return Number.isFinite(ms) ? ms : 0;
  }
  return 0;
}
