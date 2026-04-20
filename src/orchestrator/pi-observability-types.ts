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
}

export interface PhaseTrace {
  version: 1;
  runId: string;
  seedId: string;
  phase: string;
  phaseType: PhaseExecutionType;
  model: string;
  worktreePath: string;
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
