import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

import type { PhaseTrace, PhaseTraceWriteResult } from "./pi-observability-types.js";

function traceBaseName(phase: string): string {
  return `${phase.toUpperCase()}_TRACE`;
}

export function getPhaseTracePaths(worktreePath: string, seedId: string, phase: string): PhaseTraceWriteResult {
  const reportsDir = join(worktreePath, "docs", "reports", seedId);
  const base = traceBaseName(phase);
  const relativeJsonPath = join("docs", "reports", seedId, `${base}.json`);
  const relativeMarkdownPath = join("docs", "reports", seedId, `${base}.md`);
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
  const paths = getPhaseTracePaths(trace.worktreePath, trace.seedId, trace.phase);
  await mkdir(join(trace.worktreePath, "docs", "reports", trace.seedId), { recursive: true });
  await writeFile(paths.jsonPath, `${JSON.stringify(trace, null, 2)}\n`, "utf-8");
  await writeFile(paths.markdownPath, `${renderTraceMarkdown(trace, paths.relativeJsonPath)}\n`, "utf-8");
  return paths;
}
