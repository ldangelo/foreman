// CQRS dispatch helpers for worktree lifecycle events.
//
// All worktree mutations (create + remove) MUST emit a Foreman command so
// the projection's `[:worktrees, run_id]` index and audit trail stay in sync.
// The VcsOperation aggregate on the Elixir side folds these into
// `WorktreeCreated` / `WorktreeCleaned` events that drive the read models.
//
// Direct VCS calls (e.g. `vcs.createWorkspace()` / `vcs.removeWorkspace()`)
// are the actual on-disk mutation; these helpers wrap them so the projection
// reflects what happened.

import { randomUUID } from "node:crypto";

import type { ElixirServerClient } from "./elixir-server-client.js";

export interface WorktreeCreatedDispatch {
  projectId: string;
  runId: string;
  worktreePath: string;
  branchName: string;
  baseBranch?: string | null;
}

export interface WorktreeCleanedDispatch {
  projectId: string;
  runId: string;
  worktreePath: string;
  reason?: string;
}

interface CommandResult {
  ok: boolean;
  error?: { message: string };
}

async function sendCommand(
  client: ElixirServerClient,
  commandType: "vcs.worktree.create" | "vcs.worktree.clean",
  payload: Record<string, unknown>,
): Promise<CommandResult> {
  const response = await client.sendCommand({
    command_id: `${commandType}-${payload.run_id ?? "run"}-${randomUUID()}`,
    command_type: commandType,
    payload,
  });
  if (!response.ok) {
    return { ok: false, error: { message: response.error.message } };
  }
  return { ok: true };
}

/**
 * Emit a `vcs.worktree.create` command. Projection sees a `WorktreeCreated`
 * event and adds `[:worktrees, run_id]` + `[:vcs_operations, operation_id]`.
 *
 * Fire-and-record: never throws on failure (logs and continues). The on-disk
 * worktree is already created by the caller; failing to project it would
 * leave a CQRS gap we want to surface but not crash dispatch over.
 */
export async function emitWorktreeCreated(
  client: ElixirServerClient,
  input: WorktreeCreatedDispatch,
): Promise<CommandResult> {
  return sendCommand(client, "vcs.worktree.create", {
    project_id: input.projectId,
    run_id: input.runId,
    worktree_path: input.worktreePath,
    branch_name: input.branchName,
    base_branch: input.baseBranch ?? null,
    operation_id: `wt-create-${input.runId}-${randomUUID()}`,
  });
}

/**
 * Emit a `vcs.worktree.clean` command. Projection sees a `WorktreeCleaned`
 * event and drops `[:worktrees, run_id]` + records `[:vcs_operations, ...]`.
 */
export async function emitWorktreeCleaned(
  client: ElixirServerClient,
  input: WorktreeCleanedDispatch,
): Promise<CommandResult> {
  return sendCommand(client, "vcs.worktree.clean", {
    project_id: input.projectId,
    run_id: input.runId,
    worktree_path: input.worktreePath,
    reason: input.reason ?? "cleanup",
    operation_id: `wt-clean-${input.runId}-${randomUUID()}`,
  });
}
