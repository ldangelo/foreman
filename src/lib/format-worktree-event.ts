/**
 * Shared worktree event summary formatter.
 * Used by both the inbox CLI and the TUI timeline to render WorktreeCreated /
 * WorktreeCleaned / worktree-cleaned / worktree-removed events consistently.
 */

function detailString(details: Record<string, unknown>, keys: string[]): string | undefined {
  for (const key of keys) {
    const value = details[key];
    if (typeof value === "string" && value.length > 0) return value;
  }
  return undefined;
}

export interface WorktreeEventContext {
  target?: string | null;
  details: Record<string, unknown> | null;
}

export function formatWorktreeEvent(eventType: string, ctx: WorktreeEventContext): string {
  const { target, details } = ctx;
  if (!details) return eventType;

  if (eventType === "WorktreeCreated" || eventType === "worktree-created") {
    const branch = detailString(details, ["branchName", "branch_name"]);
    const path = detailString(details, ["worktreePath", "worktree_path"]);
    return `Worktree created${target ? ` for ${target}` : ""}${branch ? ` (${branch})` : ""}${path ? ` at ${path}` : ""}`;
  }

  if (eventType === "WorktreeCleaned" || eventType === "worktree-cleaned" || eventType === "worktree-removed") {
    const path = detailString(details, ["worktreePath", "worktree_path"]);
    const reason = detailString(details, ["reason"]);
    return `Worktree removed${target ? ` for ${target}` : ""}${path ? ` (${path})` : ""}${reason ? ` — ${reason}` : ""}`;
  }

  return eventType;
}
