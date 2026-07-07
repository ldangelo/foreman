import type { RunStatus } from "../orchestrator/read-models.js";
import type { NativeTaskStatus } from "../orchestrator/types.js";
import type { TaskClientBackend } from "./task-client-factory.js";

export interface StateMismatch {
  taskId: string;
  runId: string;
  runStatus: RunStatus;
  actualTaskStatus: string;
  expectedTaskStatus: string;
}

const RETRYABLE_PIPELINE_TASK_STATUSES: ReadonlySet<string> = new Set([
  "backlog",
  "ready",
  "in-progress",
  "blocked",
  "conflict",
  "failed",
  "stuck",
  "explorer",
  "developer",
  "qa",
  "reviewer",
  "finalize",
]);

export type TaskRetryTargetOptions =
  | { command: "reset" }
  | { command: "retry"; backendType: TaskClientBackend };

export function getTaskRetryTargetStatus(
  currentStatus: string,
  options: TaskRetryTargetOptions,
): "ready" | null {
  const isTerminal =
    currentStatus === "closed" || currentStatus === "completed" || currentStatus === "merged";

  if (isTerminal) {
    return null;
  }

  if (currentStatus === "ready") {
    return "ready";
  }

  if (options.command === "reset") {
    return RETRYABLE_PIPELINE_TASK_STATUSES.has(currentStatus) ? "ready" : null;
  }

  return RETRYABLE_PIPELINE_TASK_STATUSES.has(currentStatus) ? "ready" : null;
}

export function mapRunStatusToNativeTaskStatus(runStatus: RunStatus): NativeTaskStatus {
  switch (runStatus) {
    case "pending":
    case "running":
      return "in-progress";
    case "completed":
      return "review";
    case "stuck":
      return "ready";
    case "cooldown":
      return "cooldown";
    case "merged":
    case "pr-created":
      return "closed";
    case "conflict":
    case "test-failed":
      return "blocked";
    case "failed":
      return "failed";
    case "reset":
      return "ready";
  }
}
