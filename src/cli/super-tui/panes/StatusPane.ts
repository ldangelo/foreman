import { Box, Text } from "ink";
import { createElement, type ReactElement } from "react";
import type { InboxTaskSummary } from "../../commands/inbox.js";
import { buildWorkflowStatusSummary, type WorkflowPhaseNode, type WorkflowPhasesContext } from "../status-model.js";
import { Pane, truncate } from "./TaskListPane.js";

const h = createElement;

function phaseColor(node: WorkflowPhaseNode): string {
  switch (node.status) {
    case "completed": return "green";
    case "running": return "yellow";
    case "failed": return "red";
    case "retried": return "yellow";
    case "skipped": return "gray";
    case "pending": return "gray";
  }
}

function phaseIcon(node: WorkflowPhaseNode): string {
  switch (node.status) {
    case "completed": return "✓";
    case "running": return "▶";
    case "failed": return "✗";
    case "retried": return "↻";
    case "skipped": return "↷";
    case "pending": return "·";
  }
}

export function StatusPane({ summary, compact }: { summary: InboxTaskSummary | undefined; compact: boolean }): ReactElement {
  if (!summary) return h(Pane, { title: "Status workflow" }, h(Text, null, "No task selected."));

  // Build workflow phases context from summary if available
  // The workflowPhases are populated by buildInboxTaskSummaries
  const workflowPhases: WorkflowPhasesContext | undefined = summary.workflowPhases;

  const workflow = buildWorkflowStatusSummary(summary, workflowPhases);
  const maxPhases = compact ? 6 : 10;
  const visiblePhases = workflow.phases.slice(0, maxPhases);

  return h(Pane, { title: "Status workflow", minHeight: compact ? 7 : 14 },
    h(Text, null,
      h(Text, { bold: true }, workflow.taskId),
      ` run=${workflow.runId} status=${workflow.runStatus} current=${workflow.currentPhase} verdict=${workflow.verdict}`,
    ),
    h(Box, { flexDirection: "column" },
      ...visiblePhases.map((node, index) => h(Text, { key: `${node.phase}-${index}`, color: phaseColor(node) },
        `${phaseIcon(node)} ${node.phase} ${node.status}${node.attempt !== null ? ` attempt=${node.attempt}` : ""}${node.maxRetries !== null ? `/${node.maxRetries}` : ""}${node.verdict !== "unknown" ? ` verdict=${node.verdict}` : ""}${node.error ? ` error=${truncate(node.error, compact ? 42 : 88)}` : ""}`,
      )),
      workflow.phases.length > maxPhases ? h(Text, { dimColor: true }, `… ${workflow.phases.length - maxPhases} more phases`) : h(Text, { dimColor: true }, " "),
    ),
    workflow.retryEdges.length > 0
      ? h(Box, { flexDirection: "column" },
        h(Text, { bold: true, color: "yellow" }, "Retry path"),
        ...workflow.retryEdges.slice(0, compact ? 3 : 6).map((edge, index) => h(Text, { key: `retry-${index}`, color: "yellow" },
          `↻ ${edge.from} → ${edge.to}${edge.attempt !== null ? ` attempt=${edge.attempt}` : ""}${edge.maxRetries !== null ? `/${edge.maxRetries}` : ""}`,
        )),
      )
      : h(Text, { dimColor: true }, "Retry path: none"),
    workflow.failure ? h(Text, { color: "red" }, `Failure: ${truncate(workflow.failure, compact ? 56 : 112)}`) : h(Text, { dimColor: true }, "Failure: none"),
    workflow.activeAgent ? h(Text, { color: "cyan" }, `Active: ${workflow.activeAgent.phase} · ${truncate(workflow.activeAgent.lastActivity, compact ? 56 : 112)}`) : h(Text, { dimColor: true }, `Last: ${truncate(workflow.lastActivity, compact ? 64 : 120)}`),
    workflow.artifactPaths.length > 0 ? h(Text, { dimColor: true }, `Artifacts: ${truncate(workflow.artifactPaths.join(", "), compact ? 56 : 112)}`) : h(Text, { dimColor: true }, "Artifacts: —"),
  );
}
