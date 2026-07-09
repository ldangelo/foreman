import { randomUUID } from "node:crypto";
import type { Project, Run, SentinelConfigRow, SentinelRunRow } from "../../lib/store.js";
import type { ElixirRun } from "../../lib/elixir-server-client.js";
import { elixirClient, type RegisteredProjectSummary } from "./project-task-support.js";

function terminalRunCommand(status: string | undefined): "run.complete" | "run.fail" | "run.block" | null {
  switch (status) {
    case "completed":
    case "merged":
      return "run.complete";
    case "failed":
      return "run.fail";
    case "blocked":
      return "run.block";
    default:
      return null;
  }
}

function adaptRun(run: ElixirRun): Run {
  const runId = String(run.run_id ?? run.id ?? "");
  return {
    id: runId,
    project_id: String(run.project_id ?? ""),
    task_id: String(run.task_id ?? ""),
    status: (run.status as Run["status"]) ?? "running",
    started_at: (run.started_at as string | null | undefined) ?? null,
    completed_at: (run.completed_at as string | null | undefined) ?? null,
    created_at: (run.created_at as string | undefined) ?? (run.started_at as string | undefined) ?? new Date(Date.now() - 86400000).toISOString(),
    progress: (run.progress as string | null | undefined) ?? null,
    agent_type: (run.agent_type as string | null | undefined) ?? null,
    session_key: (run.session_key as string | null | undefined) ?? null,
    tmux_session: (run.tmux_session as string | null | undefined) ?? null,
    worktree_path: (run.worktree_path as string | null | undefined) ?? null,
    branch_name: (run.branch_name as string | null | undefined) ?? null,
    agent_name: (run.agent_name as string | null | undefined) ?? null,
    model: (run.model as string | null | undefined) ?? null,
    error: (run.error as string | null | undefined) ?? null,
    base_branch: (run.base_branch as string | null | undefined) ?? null,
    merge_strategy: (run.merge_strategy as Run["merge_strategy"] | undefined) ?? null,
    commit_sha: (run.commit_sha as string | null | undefined) ?? null,
    pr_url: (run.pr_url as string | null | undefined) ?? null,
    pr_state: (run.pr_state as Run["pr_state"] | undefined) ?? null,
    pr_head_sha: (run.pr_head_sha as string | null | undefined) ?? null,
    cooldown_until: (run.cooldown_until as string | null | undefined) ?? null,
  } as unknown as Run;
}

export class ElixirCliStore {
  constructor(private readonly project: RegisteredProjectSummary) {}

  static forProject(project: RegisteredProjectSummary): ElixirCliStore {
    return new ElixirCliStore(project);
  }

  close(): void {}
  isOpen(): boolean { return true; }

  async getProjectByPath(projectPath: string): Promise<Project | null> {
    if (this.project.path !== projectPath) return null;
    const now = new Date(0).toISOString();
    return {
      id: this.project.id,
      name: this.project.name,
      path: this.project.path,
      status: (this.project.status as Project["status"] | undefined) ?? "active",
      created_at: now,
      updated_at: now,
    };
  }

  async getRun(runId: string): Promise<Run | null> {
    const client = await elixirClient();
    const runs = await client.listRuns({ projectId: this.project.id });
    const run = runs.find((candidate) => (candidate.run_id ?? candidate.id) === runId);
    return run ? adaptRun(run) : null;
  }

  async getRunsForTask(taskId: string): Promise<Run[]> {
    const client = await elixirClient();
    const runs = await client.listRuns({ projectId: this.project.id });
    return runs.filter((run) => run.task_id === taskId).map(adaptRun);
  }

  async getRunsByStatus(status: Run["status"], _projectId?: string): Promise<Run[]> {
    const client = await elixirClient();
    const runs = await client.listRuns({ projectId: this.project.id });
    return runs.filter((run) => run.status === status).map(adaptRun);
  }

  async getRunProgress(_runId: string): Promise<null> {
    return null;
  }

  async getSuccessRate(_projectId: string): Promise<{ rate: number | null; merged: number; failed: number }> {
    return { rate: null, merged: 0, failed: 0 };
  }

  async getActiveRuns(_projectId?: string): Promise<Run[]> {
    const client = await elixirClient();
    const runs = await client.listRuns({ projectId: this.project.id });
    return runs.filter((run) => run.status === "pending" || run.status === "running" || run.status === "in_progress").map(adaptRun);
  }

  async getRunsByBaseBranch(baseBranch: string): Promise<Run[]> {
    const client = await elixirClient();
    const runs = await client.listRuns({ projectId: this.project.id });
    return runs.filter((run) => run.base_branch === baseBranch).map(adaptRun);
  }

  async getRunsByStatuses(statuses: Run["status"][]): Promise<Run[]> {
    const allowed = new Set(statuses);
    const client = await elixirClient();
    const runs = await client.listRuns({ projectId: this.project.id });
    return runs.filter((run) => allowed.has(run.status as Run["status"])).map(adaptRun);
  }

  async updateRun(runId: string, updates: Partial<Run>): Promise<void> {
    const client = await elixirClient();
    const terminalCommand = terminalRunCommand(updates.status);
    const commandType = terminalCommand ?? "run.update";
    const commandPrefix = terminalCommand ? terminalCommand.replace(".", "-") : "run-update";
    const response = await client.sendCommand({
      command_id: `${commandPrefix}-${runId}-${randomUUID()}`,
      command_type: commandType,
      payload: { run_id: runId, project_id: this.project.id, ...updates },
    });
    if (!response.ok) throw new Error(response.error.message);
  }

  async deleteRun(runId: string): Promise<boolean> {
    const client = await elixirClient();
    const response = await client.sendCommand({
      command_id: `run-delete-${runId}-${randomUUID()}`,
      command_type: "run.delete",
      payload: { run_id: runId, project_id: this.project.id },
    });
    if (!response.ok) throw new Error(response.error.message);
    return true;
  }

  async updateTaskStatus(taskId: string, status: string): Promise<void> {
    const client = await elixirClient();
    const response = await client.sendCommand({
      command_id: `task-update-${taskId}-${randomUUID()}`,
      command_type: "task.update",
      payload: { task_id: taskId, project_id: this.project.id, status },
    });
    if (!response.ok) throw new Error(response.error.message);
  }

  async getSentinelConfig(_projectId: string): Promise<SentinelConfigRow | null> {
    return null;
  }

  async getSentinelRuns(_projectId: string, _limit?: number): Promise<SentinelRunRow[]> {
    return [];
  }

  async upsertSentinelConfig(projectId: string, config: Partial<SentinelConfigRow>): Promise<void> {
    const client = await elixirClient();
    const response = await client.sendCommand({
      command_id: `sentinel-config-upsert-${projectId}-${randomUUID()}`,
      command_type: "sentinel.config.upsert",
      payload: { project_id: projectId, ...config },
    });
    if (!response.ok) throw new Error(response.error.message);
  }

  async recordSentinelRun(run: Partial<SentinelRunRow> & { project_id: string }): Promise<void> {
    await this.logEvent(run.project_id, "sentinel-run", run as Record<string, unknown>);
  }

  async updateSentinelRun(id: string, updates: Partial<SentinelRunRow>): Promise<void> {
    await this.logEvent(this.project.id, "sentinel-run-update", { id, ...updates });
  }

  async logEvent(projectId: string, eventType: string, details: Record<string, unknown>, runId?: string | null): Promise<void> {
    const client = await elixirClient();
    const response = await client.sendCommand({
      command_id: `event-log-${eventType}-${randomUUID()}`,
      command_type: "event.log",
      payload: { project_id: projectId, run_id: runId ?? null, event_type: eventType, details },
    });
    if (!response.ok) throw new Error(response.error.message);
  }
}
