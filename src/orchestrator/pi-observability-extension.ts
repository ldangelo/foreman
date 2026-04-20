import type {
  ExtensionAPI,
  ExtensionFactory,
} from "@mariozechner/pi-coding-agent";
import { existsSync } from "node:fs";
import { basename, join } from "node:path";

import type {
  FinalizePhaseTraceOptions,
  PhaseTrace,
  PhaseTraceMetadata,
} from "./pi-observability-types.js";

interface ToolExecutionEventLike {
  toolCallId: string;
  toolName: string;
  args?: unknown;
  partialResult?: unknown;
  result?: unknown;
  isError?: boolean;
}

interface ToolResultEventLike {
  toolCallId: string;
  isError: boolean;
  content?: unknown[];
}

interface MessageEndEventLike {
  message: unknown;
}

interface AgentEndEventLike {
  messages: unknown[];
}

interface ToolCallEventLike {
  toolName: string;
  input?: {
    command?: string;
  };
}

export function getForbiddenVcsAction(command: string | undefined, phase: string): "git commit" | "git push" | undefined {
  if (!command) return undefined;
  if (phase === "finalize") return undefined;
  const normalized = command.replace(/\s+/g, " ").trim().toLowerCase();
  if (/(^|[;&|]\s*|&&\s*|\|\|\s*)git commit\b/.test(normalized) || /\bgit commit\b/.test(normalized)) {
    return "git commit";
  }
  if (/(^|[;&|]\s*|&&\s*|\|\|\s*)git push\b/.test(normalized) || /\bgit push\b/.test(normalized)) {
    return "git push";
  }
  return undefined;
}

function truncate(value: string, max = 240): string {
  return value.length <= max ? value : `${value.slice(0, max - 1)}…`;
}

function summarizeUnknown(value: unknown): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value === "string") return truncate(value.replace(/\s+/g, " ").trim());
  try {
    return truncate(JSON.stringify(value));
  } catch {
    return truncate(String(value));
  }
}

function extractMessageText(message: unknown): string | undefined {
  if (!message || typeof message !== "object") return undefined;
  const candidate = message as { content?: unknown; text?: unknown };
  if (typeof candidate.text === "string") {
    return truncate(candidate.text);
  }
  if (Array.isArray(candidate.content)) {
    const text = candidate.content
      .map((part) => {
        if (!part || typeof part !== "object") return undefined;
        const maybeText = part as { type?: unknown; text?: unknown };
        if (maybeText.type === "text" && typeof maybeText.text === "string") {
          return maybeText.text;
        }
        return undefined;
      })
      .filter((part): part is string => Boolean(part))
      .join(" ")
      .trim();
    return text ? truncate(text) : undefined;
  }
  return undefined;
}

function deriveExpectedSkill(command?: string): { expectedSkill?: string; commandLooksLikeLegacySlash: boolean } {
  if (!command) return { commandLooksLikeLegacySlash: false };
  const trimmed = command.trim();
  const skillMatch = trimmed.match(/^\$([a-z0-9][a-z0-9-]*)\b/i);
  if (skillMatch) {
    return { expectedSkill: skillMatch[1], commandLooksLikeLegacySlash: false };
  }
  const slashMatch = trimmed.match(/^\/([a-z0-9_-]+):([a-z0-9_-]+)\b/i);
  if (slashMatch) {
    const namespace = slashMatch[1].replace(/_/g, "-");
    const command = slashMatch[2].replace(/_/g, "-");
    return {
      expectedSkill: namespace === "skill" ? command : `${namespace}-${command}`,
      commandLooksLikeLegacySlash: true,
    };
  }
  return { commandLooksLikeLegacySlash: false };
}

export function createPhaseTrace(metadata: PhaseTraceMetadata): PhaseTrace {
  const commandInfo = deriveExpectedSkill(metadata.resolvedCommand ?? metadata.rawPrompt);
  return {
    version: 1,
    runId: metadata.runId,
    seedId: metadata.seedId,
    phase: metadata.phase,
    phaseType: metadata.phaseType,
    model: metadata.model,
    worktreePath: metadata.worktreePath,
    workflowName: metadata.workflowName,
    workflowPath: metadata.workflowPath,
    startedAt: new Date().toISOString(),
    rawPrompt: metadata.rawPrompt,
    resolvedCommand: metadata.resolvedCommand,
    systemPromptPreview: metadata.systemPrompt ? truncate(metadata.systemPrompt) : undefined,
    expectedArtifact: metadata.expectedArtifact,
    expectedSkill: commandInfo.expectedSkill,
    commandLooksLikeLegacySlash: commandInfo.commandLooksLikeLegacySlash,
    warnings: [],
    toolCalls: [],
  };
}

function findTool(trace: PhaseTrace, toolCallId: string) {
  return trace.toolCalls.find((tool) => tool.toolCallId === toolCallId);
}

export function createPiObservabilityExtension(trace: PhaseTrace): ExtensionFactory {
  return (pi: ExtensionAPI) => {
    pi.on("before_agent_start", async (event) => {
      trace.rawPrompt = event.prompt;
      trace.systemPromptPreview = truncate(event.systemPrompt);
    });

    (pi as ExtensionAPI & { on: (event: "tool_call", handler: (event: ToolCallEventLike) => unknown) => void }).on("tool_call", async (event: ToolCallEventLike) => {
      if (event.toolName !== "bash") return;
      const forbidden = getForbiddenVcsAction(event.input?.command, trace.phase);
      if (!forbidden) return;
      trace.warnings.push(`Blocked ${forbidden} during non-finalize phase`);
      return {
        block: true,
        reason: `${forbidden} is only allowed during finalize`,
      };
    });

    pi.on("tool_execution_start", async (event: ToolExecutionEventLike) => {
      trace.toolCalls.push({
        toolCallId: event.toolCallId,
        toolName: event.toolName,
        startedAt: new Date().toISOString(),
        argsPreview: summarizeUnknown(event.args),
        updateCount: 0,
      });
    });

    pi.on("tool_execution_update", async (event: ToolExecutionEventLike) => {
      const tool = findTool(trace, event.toolCallId);
      if (!tool) return;
      tool.updateCount += 1;
      const partial = summarizeUnknown(event.partialResult);
      if (partial) tool.resultPreview = partial;
    });

    pi.on("tool_result", async (event: ToolResultEventLike) => {
      const tool = findTool(trace, event.toolCallId);
      if (!tool) return;
      tool.isError = event.isError;
      const contentPreview = summarizeUnknown(
        event.content
          ?.map((part: unknown) => (part && typeof part === "object" && "text" in part ? (part as { text?: unknown }).text : part))
          .filter(Boolean),
      );
      if (contentPreview) tool.resultPreview = contentPreview;
    });

    pi.on("tool_execution_end", async (event: ToolExecutionEventLike) => {
      const tool = findTool(trace, event.toolCallId);
      if (!tool) return;
      tool.completedAt = new Date().toISOString();
      tool.isError = event.isError;
      const result = summarizeUnknown(event.result);
      if (result) tool.resultPreview = result;
    });

    pi.on("message_end", async (event: MessageEndEventLike) => {
      const text = extractMessageText(event.message);
      if (text) trace.finalMessage = text;
    });

    pi.on("agent_end", async (event: AgentEndEventLike) => {
      trace.completedAt = new Date().toISOString();
      if (!trace.finalMessage) {
        const assistantMessages = event.messages
          .filter((message: unknown) => typeof message === "object" && message && "role" in message)
          .filter((message: unknown) => (message as { role?: unknown }).role === "assistant");
        const lastAssistant = assistantMessages[assistantMessages.length - 1];
        const text = extractMessageText(lastAssistant);
        if (text) trace.finalMessage = text;
      }
    });
  };
}

export function finalizePhaseTrace(trace: PhaseTrace, options: FinalizePhaseTraceOptions): PhaseTrace {
  trace.completedAt ??= new Date().toISOString();
  trace.success = options.success;
  trace.error = options.error;
  if (options.finalMessage) {
    trace.finalMessage = truncate(options.finalMessage, 500);
  }

  trace.artifactPresent = trace.expectedArtifact
    ? existsSync(join(trace.worktreePath, trace.expectedArtifact))
    : undefined;

  const wroteExpectedArtifact = trace.expectedArtifact
    ? trace.toolCalls.some((tool) => {
        if (tool.toolName.toLowerCase() !== "write" && tool.toolName.toLowerCase() !== "edit") return false;
        const preview = `${tool.argsPreview ?? ""} ${tool.resultPreview ?? ""}`;
        return preview.includes(trace.expectedArtifact!) || preview.includes(basename(trace.expectedArtifact!));
      })
    : false;

  const finalMessageMentionsExpectedSkill = Boolean(
    trace.expectedSkill && trace.finalMessage?.includes(trace.expectedSkill),
  );
  const finalMessageMentionsArtifact = Boolean(
    trace.expectedArtifact && trace.finalMessage?.includes(basename(trace.expectedArtifact)),
  );

  if (trace.phaseType === "command") {
    if (trace.expectedArtifact && trace.artifactPresent === false) {
      trace.warnings.push(`Expected artifact missing: ${trace.expectedArtifact}`);
    }
    if (trace.commandLooksLikeLegacySlash) {
      trace.warnings.push("Command uses legacy slash syntax; runtime may treat it as plain prompt text");
    }
    if (trace.expectedArtifact) {
      trace.commandHonored = trace.artifactPresent === true
        || wroteExpectedArtifact
        || finalMessageMentionsArtifact
        || finalMessageMentionsExpectedSkill;
      if (trace.commandHonored === false) {
        trace.warnings.push("No strong evidence that the command-phase workflow was honored");
      }
    }
  }

  if (options.error) {
    trace.warnings.push(`Phase error: ${options.error}`);
  }

  return trace;
}
