export type PhaseExecutionType = "prompt" | "command" | "bash" | "builtin";

export interface PhaseTraceToolCall {
  toolCallId: string;
  toolName: string;
  startedAt: string;
  completedAt?: string;
  argsPreview?: string;
  resultPreview?: string;
  isError?: boolean;
  updateCount: number;
}

export interface PhaseTraceMetadata {
  runId: string;
  seedId: string;
  phase: string;
  phaseType: PhaseExecutionType;
  model: string;
  worktreePath: string;
  rawPrompt: string;
  systemPrompt?: string;
  expectedArtifact?: string;
  resolvedCommand?: string;
  workflowName?: string;
  workflowPath?: string;
}

export interface PhaseTrace {
  version: 1;
  runId: string;
  seedId: string;
  phase: string;
  phaseType: PhaseExecutionType;
  model: string;
  worktreePath: string;
  workflowName?: string;
  workflowPath?: string;
  startedAt: string;
  completedAt?: string;
  rawPrompt: string;
  resolvedCommand?: string;
  systemPromptPreview?: string;
  expectedArtifact?: string;
  expectedSkill?: string;
  commandLooksLikeLegacySlash: boolean;
  artifactPresent?: boolean;
  commandHonored?: boolean;
  success?: boolean;
  error?: string;
  finalMessage?: string;
  warnings: string[];
  toolCalls: PhaseTraceToolCall[];
}

export interface FinalizePhaseTraceOptions {
  success: boolean;
  error?: string;
  finalMessage?: string;
}

export interface PhaseTraceWriteResult {
  jsonPath: string;
  markdownPath: string;
  relativeJsonPath: string;
  relativeMarkdownPath: string;
}

export interface PhaseTraceLiveEvent {
  kind: "start" | "update" | "warning" | "complete";
  phase: string;
  seedId: string;
  message: string;
  toolName?: string;
  argsPreview?: string;
  traceFile?: string;
  traceMarkdownFile?: string;
  commandHonored?: boolean;
}

/**
 * Sanitize a PhaseTrace by replacing absolute worktree paths with a stable placeholder.
 * This prevents host-specific absolute paths from leaking into committed trace artifacts.
 *
 * - Replaces `worktreePath` with `"$WORKTREE"`
 * - Replaces `workflowPath` with a repo-relative path if possible, otherwise `"$WORKTREE/workflows/..."`
 * - Scrubs absolute worktree paths from all `argsPreview` and `resultPreview` strings
 */
export function sanitizeTracePaths(trace: PhaseTrace): PhaseTrace {
  const worktreePath = trace.worktreePath;
  const placeholder = "$WORKTREE";

  // Build a regex that matches the absolute worktree path as a path segment
  // This handles cases where the path appears mid-string
  const escapedWorktree = worktreePath.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pathPattern = new RegExp(escapedWorktree, "g");

  // Replace all occurrences of the worktree path with the placeholder
  const replacePath = (s: string): string => s.replace(pathPattern, placeholder);

  // Sanitize a required string field (always present in PhaseTrace)
  const sanitizeRequired = (s: string): string => replacePath(s);

  // Sanitize an optional string field
  const sanitizeOptional = (s: string | undefined): string | undefined =>
    s ? replacePath(s) : undefined;

  const sanitizeToolCall = (tool: PhaseTraceToolCall): PhaseTraceToolCall => ({
    ...tool,
    argsPreview: sanitizeOptional(tool.argsPreview),
    resultPreview: sanitizeOptional(tool.resultPreview),
  });

  return {
    ...trace,
    worktreePath: placeholder,
    // Try to make workflowPath repo-relative if it contains the worktree path
    workflowPath: sanitizeOptional(trace.workflowPath),
    rawPrompt: sanitizeRequired(trace.rawPrompt),
    systemPromptPreview: sanitizeOptional(trace.systemPromptPreview),
    resolvedCommand: sanitizeOptional(trace.resolvedCommand),
    expectedArtifact: sanitizeOptional(trace.expectedArtifact),
    expectedSkill: sanitizeOptional(trace.expectedSkill),
    finalMessage: sanitizeOptional(trace.finalMessage),
    error: sanitizeOptional(trace.error),
    toolCalls: trace.toolCalls.map(sanitizeToolCall),
  };
}
