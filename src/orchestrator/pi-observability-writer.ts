import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { getForemanHomePath } from "../lib/foreman-paths.js";

import type { PhaseTrace, PhaseTraceWriteResult } from "./pi-observability-types.js";

/**
 * Stable placeholder used in place of host-specific absolute worktree paths
 * in committed trace artifacts.
 */
export const WORKTREE_PLACEHOLDER = "{worktree}";

/**
 * Stable placeholder used in place of the host-specific Foreman home directory
 * (e.g. ~/.foreman) in committed trace artifact paths.
 */
export const FOREMAN_HOME_PLACEHOLDER = "{foremanHome}";

/**
 * Sanitize a phase trace for safe commit.
 *
 * Replaces host-specific absolute worktree path prefixes and any occurrences
 * in tool call argsPreview/resultPreview fields with a stable placeholder so that
 * committed artifacts do not leak local filesystem structure.
 *
 * Handles both Unix-style (/Users/...) and Windows-style (\Users\...) paths.
 */
export function sanitizeTrace(trace: PhaseTrace): PhaseTrace {
  const unixPattern = "/Users/";
  const winPattern = "\\Users\\";
  return {
    ...trace,
    worktreePath: WORKTREE_PLACEHOLDER,
    toolCalls: trace.toolCalls.map((tc) => ({
      ...tc,
      argsPreview: tc.argsPreview
        ? tc.argsPreview.replace(new RegExp(winPattern + "[^\\\\]+|" + unixPattern + "[^/]+", "g"), WORKTREE_PLACEHOLDER)
        : tc.argsPreview,
      resultPreview: tc.resultPreview
        ? tc.resultPreview.replace(new RegExp(winPattern + "[^\\\\]+|" + unixPattern + "[^/]+", "g"), WORKTREE_PLACEHOLDER)
        : tc.resultPreview,
    })),
  };
}

/**
 * Replace host-specific Foreman home directory prefix in a path with a stable
 * placeholder so artifact paths in committed traces are portable.
 */
export function sanitizeForemanHomePath(path: string): string {
  const foremanHome = getForemanHomePath().replace(/\\/g, "/");
  return path.replace(foremanHome, FOREMAN_HOME_PLACEHOLDER);
}

function traceBaseName(phase: string): string {
  return `${phase.toUpperCase()}_TRACE`;
}

export function getPhaseTracePaths(worktreePath: string, seedId: string, phase: string, runId?: string): PhaseTraceWriteResult {
  const reportsDir = runId
    ? getForemanHomePath("reports", "runs", runId, seedId)
    : join(worktreePath, "docs", "reports", seedId);
  const base = traceBaseName(phase);
  const relativeJsonPath = join(reportsDir, `${base}.json`);
  const relativeMarkdownPath = join(reportsDir, `${base}.md`);
  return {
    jsonPath: join(reportsDir, `${base}.json`),
    markdownPath: join(reportsDir, `${base}.md`),
    relativeJsonPath,
    relativeMarkdownPath,
  };
}

function renderTraceMarkdown(trace: PhaseTrace, relativeJsonPath: string): string {
  const lines: string[] = [
    `# ${trace.phase.toUpperCase()} Trace — ${trace.seedId}`,
    "",
    `- Run ID: \`${trace.runId}\``,
    `- Phase type: \`${trace.phaseType}\``,
    `- Model: \`${trace.model}\``,
    `- Workflow: ${trace.workflowName ? `\`${trace.workflowName}\`` : "—"}`,
    `- Workflow path: ${trace.workflowPath ? `\`${trace.workflowPath}\`` : "—"}`,
    `- Started: ${trace.startedAt}`,
    `- Completed: ${trace.completedAt ?? "—"}`,
    `- Success: ${trace.success === undefined ? "unknown" : trace.success ? "yes" : "no"}`,
    `- Expected artifact: ${trace.expectedArtifact ? `\`${trace.expectedArtifact}\`` : "—"}`,
    `- Artifact present: ${trace.artifactPresent === undefined ? "unknown" : trace.artifactPresent ? "yes" : "no"}`,
    `- Expected skill: ${trace.expectedSkill ? `\`${trace.expectedSkill}\`` : "—"}`,
    `- Command honored: ${trace.commandHonored === undefined ? "unknown" : trace.commandHonored ? "yes" : "no"}`,
    `- JSON trace: \`${relativeJsonPath}\``,
    "",
    "## Prompt",
    "",
    "```text",
    trace.rawPrompt,
    "```",
  ];

  if (trace.resolvedCommand) {
    lines.push("", "## Resolved Command", "", "```text", trace.resolvedCommand, "```");
  }

  if (trace.finalMessage) {
    lines.push("", "## Final Assistant Output", "", "```text", trace.finalMessage, "```");
  }

  if (trace.warnings.length > 0) {
    lines.push("", "## Warnings", "", ...trace.warnings.map((warning) => `- ${warning}`));
  }

  lines.push("", "## Tool Calls", "");
  if (trace.toolCalls.length === 0) {
    lines.push("_No tool calls captured_");
  } else {
    for (const tool of trace.toolCalls) {
      lines.push(`### ${tool.toolName} (\`${tool.toolCallId}\`)`, "");
      lines.push(`- Started: ${tool.startedAt}`);
      lines.push(`- Completed: ${tool.completedAt ?? "—"}`);
      lines.push(`- Error: ${tool.isError ? "yes" : "no"}`);
      lines.push(`- Updates: ${tool.updateCount}`);
      if (tool.argsPreview) lines.push(`- Args: \`${tool.argsPreview}\``);
      if (tool.resultPreview) lines.push(`- Result: \`${tool.resultPreview}\``);
      lines.push("");
    }
  }

  return lines.join("\n");
}

export async function writePhaseTrace(trace: PhaseTrace): Promise<PhaseTraceWriteResult> {
  const paths = getPhaseTracePaths(trace.worktreePath, trace.seedId, trace.phase, trace.runId);
  await mkdir(join(paths.jsonPath, ".."), { recursive: true });
  // Sanitize BEFORE writing so committed artifacts contain no host-specific paths
  const sanitized = sanitizeTrace(trace);
  // Sanitize the Foreman home prefix in artifact paths so markdown references are also portable
  const sanitizedRelativeJsonPath = sanitizeForemanHomePath(paths.relativeJsonPath);
  const sanitizedRelativeMarkdownPath = sanitizeForemanHomePath(paths.relativeMarkdownPath);
  await writeFile(paths.jsonPath, `${JSON.stringify(sanitized, null, 2)}\n`, "utf-8");
  await writeFile(paths.markdownPath, `${renderTraceMarkdown(sanitized, sanitizedRelativeJsonPath)}\n`, "utf-8");
  return { ...paths, relativeJsonPath: sanitizedRelativeJsonPath, relativeMarkdownPath: sanitizedRelativeMarkdownPath };
}
