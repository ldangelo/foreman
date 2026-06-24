import type { WorkflowPhaseConfig } from "../lib/workflow-loader.js";

export type PhaseActionKind = "dispatcher" | "prompt" | "command" | "bash" | "builtin";

export interface PhaseActionDescriptor {
  /** Reusable action implementation key used by workflow YAML. */
  type: string;
  /** Broad executor path used for observability and compatibility. */
  kind: PhaseActionKind;
  /** Human-readable description for docs/debug output. */
  description: string;
}

const BUILTIN_PHASE_ACTIONS = new Set([
  "cli-review",
  "finalize",
  "create-pr",
  "pr-wait",
  "prepare-pr-review",
  "merge",
]);

export const DISPATCHER_PHASE_ACTIONS = new Set([
  "prepare-worktree",
  "setup-workspace",
  "write-task-context",
]);

export const PHASE_ACTIONS: Record<string, PhaseActionDescriptor> = {
  "prepare-worktree": {
    type: "prepare-worktree",
    kind: "dispatcher",
    description: "Create or reuse the task worktree and branch",
  },
  "setup-workspace": {
    type: "setup-workspace",
    kind: "dispatcher",
    description: "Run workflow setup, dependency install, and afterCreate hook",
  },
  "write-task-context": {
    type: "write-task-context",
    kind: "dispatcher",
    description: "Write TASK.md/context files into the workspace",
  },
  "prompt-agent": {
    type: "prompt-agent",
    kind: "prompt",
    description: "Run a prompt-backed agent phase",
  },
  "command-agent": {
    type: "command-agent",
    kind: "command",
    description: "Run an inline command as an agent prompt",
  },
  bash: {
    type: "bash",
    kind: "bash",
    description: "Run a deterministic shell command phase",
  },
  builtin: {
    type: "builtin",
    kind: "builtin",
    description: "Run a built-in TypeScript phase",
  },
  "cli-review": {
    type: "cli-review",
    kind: "builtin",
    description: "Run the built-in CLI review integration",
  },
  finalize: {
    type: "finalize",
    kind: "builtin",
    description: "Finalize, validate, and commit the task branch",
  },
  "create-pr": {
    type: "create-pr",
    kind: "builtin",
    description: "Create or reuse a pull request for the task branch",
  },
  "pr-wait": {
    type: "pr-wait",
    kind: "builtin",
    description: "Wait for pull request checks and review signals",
  },
  "prepare-pr-review": {
    type: "prepare-pr-review",
    kind: "builtin",
    description: "Prepare pull request review context",
  },
  merge: {
    type: "merge",
    kind: "builtin",
    description: "Run the configured merge action",
  },
};

export function inferPhaseActionType(phase: WorkflowPhaseConfig): string {
  if (phase.action) return phase.action;
  if (phase.bash) return "bash";
  if (phase.command) return "command-agent";
  if (phase.builtin) return BUILTIN_PHASE_ACTIONS.has(phase.name) ? phase.name : "builtin";
  return "prompt-agent";
}

export function getPhaseActionDescriptor(phase: WorkflowPhaseConfig): PhaseActionDescriptor {
  const actionType = inferPhaseActionType(phase);
  return PHASE_ACTIONS[actionType] ?? {
    type: actionType,
    kind: DISPATCHER_PHASE_ACTIONS.has(actionType) ? "dispatcher" : phase.bash ? "bash" : phase.command ? "command" : phase.builtin ? "builtin" : "prompt",
    description: `Custom phase action: ${actionType}`,
  };
}

export function phaseActionKind(phase: WorkflowPhaseConfig): PhaseActionKind {
  return getPhaseActionDescriptor(phase).kind;
}

export function isDispatcherPhaseAction(phase: WorkflowPhaseConfig): boolean {
  return phaseActionKind(phase) === "dispatcher";
}

export function isBuiltinPhaseAction(phase: WorkflowPhaseConfig): boolean {
  return phaseActionKind(phase) === "builtin";
}

export function isBashPhaseAction(phase: WorkflowPhaseConfig): boolean {
  return phaseActionKind(phase) === "bash";
}

export function isCommandPhaseAction(phase: WorkflowPhaseConfig): boolean {
  return phaseActionKind(phase) === "command";
}
