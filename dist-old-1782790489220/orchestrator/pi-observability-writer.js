import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { getForemanHomePath } from "../lib/foreman-paths.js";
const WORKTREE_PLACEHOLDER = "<worktree>";
/**
 * Sanitize a PhaseTrace for safe commit/publication by replacing
 * host-specific absolute worktree paths with a stable placeholder.
 *
 * This ensures trace artifacts do not leak user-specific paths like
 * `/Users/.../.foreman/worktrees/...` into committed artifacts.
 */
function sanitizeTrace(trace) {
    const originalPath = trace.worktreePath;
    if (!originalPath)
        return trace;
    const sanitizeString = (s) => {
        if (!s)
            return s;
        return s.split(originalPath).join(WORKTREE_PLACEHOLDER);
    };
    return {
        ...trace,
        worktreePath: WORKTREE_PLACEHOLDER,
        toolCalls: trace.toolCalls.map((tool) => ({
            ...tool,
            argsPreview: sanitizeString(tool.argsPreview),
            resultPreview: sanitizeString(tool.resultPreview),
        })),
    };
}
function traceBaseName(phase) {
    return `${phase.toUpperCase()}_TRACE`;
}
export function getPhaseTracePaths(worktreePath, seedId, phase, runId) {
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
function renderTraceMarkdown(trace, relativeJsonPath) {
    const lines = [
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
    }
    else {
        for (const tool of trace.toolCalls) {
            lines.push(`### ${tool.toolName} (\`${tool.toolCallId}\`)`, "");
            lines.push(`- Started: ${tool.startedAt}`);
            lines.push(`- Completed: ${tool.completedAt ?? "—"}`);
            lines.push(`- Error: ${tool.isError ? "yes" : "no"}`);
            lines.push(`- Updates: ${tool.updateCount}`);
            if (tool.argsPreview)
                lines.push(`- Args: \`${tool.argsPreview}\``);
            if (tool.resultPreview)
                lines.push(`- Result: \`${tool.resultPreview}\``);
            lines.push("");
        }
    }
    return lines.join("\n");
}
export async function writePhaseTrace(trace) {
    const paths = getPhaseTracePaths(trace.worktreePath, trace.seedId, trace.phase, trace.runId);
    const sanitized = sanitizeTrace(trace);
    await mkdir(join(paths.jsonPath, ".."), { recursive: true });
    await writeFile(paths.jsonPath, `${JSON.stringify(sanitized, null, 2)}\n`, "utf-8");
    await writeFile(paths.markdownPath, `${renderTraceMarkdown(sanitized, paths.relativeJsonPath)}\n`, "utf-8");
    return paths;
}
//# sourceMappingURL=pi-observability-writer.js.map