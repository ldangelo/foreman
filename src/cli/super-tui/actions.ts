import type { InboxTaskSummary } from "../commands/inbox.js";

export type SuperTuiActionSafety = "copy" | "manual-command" | "confirmed-execution";

export interface SuperTuiPaletteAction {
  id: string;
  label: string;
  shortcut: string;
  description: string;
  command: string;
  safety: SuperTuiActionSafety;
  destructive: boolean;
  execution?: "reset-task";
}

function shellArg(value: string): string {
  return /^[A-Za-z0-9._/:-]+$/.test(value) ? value : `'${value.replace(/'/g, "'\\''")}'`;
}

function detailValue(summary: InboxTaskSummary, keys: string[]): string | null {
  for (const event of summary.events) {
    const details = event.details;
    if (!details) continue;
    for (const key of keys) {
      const value = details[key];
      if (typeof value === "string" && value.length > 0) return value;
    }
  }
  return null;
}

export function buildSuperTuiPaletteActions(summary: InboxTaskSummary | undefined, projectLabel: string): SuperTuiPaletteAction[] {
  if (!summary) return [];

  const taskId = shellArg(summary.taskId);
  const runId = shellArg(summary.runId);
  const project = shellArg(projectLabel);
  const actions: SuperTuiPaletteAction[] = [
    {
      id: "copy-task-id",
      label: "Copy task id",
      shortcut: "c",
      description: "Copy or manually reuse the selected task id.",
      command: summary.taskId,
      safety: "copy",
      destructive: false,
    },
    {
      id: "copy-run-id",
      label: "Copy run id",
      shortcut: "u",
      description: "Copy or manually reuse the selected run id.",
      command: summary.runId,
      safety: "copy",
      destructive: false,
    },
    {
      id: "drilldown",
      label: "Manual: open drilldown",
      shortcut: "d",
      description: "Show task mail, lifecycle events, logs, reports, and files.",
      command: `foreman inbox task ${taskId} --project ${project} --logs --reports --files`,
      safety: "manual-command",
      destructive: false,
    },
    {
      id: "logs",
      label: "Manual: tail logs",
      shortcut: "l",
      description: "Follow the selected task logs outside the cockpit.",
      command: `foreman logs ${taskId} --project ${project} --follow`,
      safety: "manual-command",
      destructive: false,
    },
    {
      id: "show-task",
      label: "Manual: show task",
      shortcut: "t",
      description: "Print the selected task record and current run summary.",
      command: `foreman task show ${taskId} --project ${project}`,
      safety: "manual-command",
      destructive: false,
    },
    {
      id: "run-detail",
      label: "Manual: open run detail",
      shortcut: "r",
      description: "Open the selected run drilldown directly.",
      command: `foreman inbox run ${runId} --project ${project} --logs --reports --files`,
      safety: "manual-command",
      destructive: false,
    },
    {
      id: "retry-task",
      label: "Manual: retry task",
      shortcut: "y",
      description: "Print a retry command only; the cockpit never retries without explicit external execution.",
      command: `foreman retry ${taskId} --project ${project}`,
      safety: "manual-command",
      destructive: true,
    },
    {
      id: "reset-task",
      label: "Reset task",
      shortcut: "x",
      description: "Reset the selected task after explicit confirmation.",
      command: `foreman reset ${taskId} --project ${project}`,
      safety: "confirmed-execution",
      destructive: true,
      execution: "reset-task",
    },
  ];

  const prUrl = detailValue(summary, ["prUrl", "pr_url", "pull_request_url"]);
  if (prUrl) {
    actions.push({
      id: "open-pr",
      label: "Manual: open PR",
      shortcut: "p",
      description: "Open the selected task pull request outside the cockpit.",
      command: `open ${shellArg(prUrl)}`,
      safety: "manual-command",
      destructive: false,
    });
  }

  if (summary.worktreePath) {
    actions.push({
      id: "open-worktree",
      label: "Manual: open worktree",
      shortcut: "w",
      description: "Open the selected task worktree path outside the cockpit.",
      command: `open ${shellArg(summary.worktreePath)}`,
      safety: "manual-command",
      destructive: false,
    });
  }

  return actions;
}

export function actionNotice(action: SuperTuiPaletteAction | undefined): string | null {
  if (!action) return null;
  if (action.safety === "confirmed-execution") return `confirm to execute: ${action.command}`;
  const prefix = action.safety === "copy" ? "copy text" : "manual command";
  const destructive = action.destructive ? "; destructive if executed externally" : "";
  return `${prefix}${destructive}: ${action.command}`;
}
