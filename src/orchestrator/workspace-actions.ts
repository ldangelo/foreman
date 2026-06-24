import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { WorktreeManager } from "../lib/worktree-manager.js";
import { installDependencies, runSetupWithCache, runWorkspaceHook } from "../lib/setup.js";
import type { WorkflowSetupCache, WorkflowSetupStep } from "../lib/workflow-loader.js";
import type { ProjectHooksConfig } from "../lib/project-config.js";
import type { ModelSelection, SeedInfo } from "./types.js";
import { workerAgentMd } from "./templates.js";
import { loadProjectAction } from "./action-loader.js";

export interface WorkspaceActionContext {
  projectId: string;
  seedId: string;
  repoPath: string;
  baseBranch?: string | null;
  defaultBranch?: string;
  worktreePath?: string;
  branchName?: string;
  workspaceWasCreated?: boolean;
  runtimeMode?: string;
  setupSteps?: WorkflowSetupStep[];
  setupCache?: WorkflowSetupCache;
  projectHooks?: ProjectHooksConfig;
  attemptNumber: number;
  seedInfo: SeedInfo;
  model: ModelSelection;
  log: (message: string) => void;
}

export async function runPrepareWorktreeAction(ctx: WorkspaceActionContext): Promise<WorkspaceActionContext> {
  const worktreeManager = new WorktreeManager();
  const worktreeInfo = await worktreeManager.createWorktree({
    projectId: ctx.projectId,
    beadId: ctx.seedId,
    repoPath: ctx.repoPath,
    baseBranch: ctx.baseBranch ?? ctx.defaultBranch,
  });
  return {
    ...ctx,
    worktreePath: worktreeInfo.path,
    branchName: worktreeInfo.branchName,
    workspaceWasCreated: worktreeInfo.created ?? !worktreeInfo.exists,
  };
}

export async function runSetupWorkspaceAction(ctx: WorkspaceActionContext): Promise<WorkspaceActionContext> {
  if (!ctx.worktreePath) throw new Error("setup-workspace requires worktreePath");
  if (ctx.runtimeMode === "test") {
    ctx.log(`[foreman] Skipping workflow setup/install for ${ctx.seedId} in test runtime`);
    return ctx;
  }
  if (ctx.setupSteps && ctx.setupSteps.length > 0) {
    await runSetupWithCache(ctx.worktreePath, ctx.repoPath, ctx.setupSteps, ctx.setupCache);
  } else {
    await installDependencies(ctx.worktreePath);
  }
  if (ctx.workspaceWasCreated && ctx.projectHooks?.afterCreate) {
    const hookEnv: Record<string, string> = {
      FOREMAN_WORKSPACE_PATH: ctx.worktreePath,
      FOREMAN_ISSUE_ID: ctx.seedId,
      FOREMAN_ISSUE_IDENTIFIER: ctx.seedId,
      FOREMAN_ATTEMPT: String(ctx.attemptNumber),
    };
    try {
      await runWorkspaceHook(ctx.projectHooks, "afterCreate", ctx.worktreePath, hookEnv);
    } catch (hookErr: unknown) {
      const hookMsg = hookErr instanceof Error ? hookErr.message : String(hookErr);
      throw new Error(`afterCreate hook failed for ${ctx.seedId}: ${hookMsg}`);
    }
  }
  return ctx;
}

export async function runWriteTaskContextAction(ctx: WorkspaceActionContext): Promise<WorkspaceActionContext> {
  if (!ctx.worktreePath) throw new Error("write-task-context requires worktreePath");
  const taskMd = workerAgentMd(ctx.seedInfo, ctx.worktreePath, ctx.model);
  await writeFile(join(ctx.worktreePath, "TASK.md"), taskMd, "utf-8");
  return ctx;
}

function assertWorkspaceActionResult(action: string, result: unknown): WorkspaceActionContext {
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    throw new Error(`Workspace action ${action} must return a workspace context object`);
  }
  const ctx = result as Partial<WorkspaceActionContext>;
  for (const key of ["projectId", "seedId", "repoPath", "attemptNumber", "seedInfo", "model", "log"] as const) {
    if (ctx[key] === undefined || ctx[key] === null) {
      throw new Error(`Workspace action ${action} returned invalid context: missing ${key}`);
    }
  }
  if (typeof ctx.log !== "function") {
    throw new Error(`Workspace action ${action} returned invalid context: log must be a function`);
  }
  return result as WorkspaceActionContext;
}

export async function runWorkspaceAction(action: string, ctx: WorkspaceActionContext): Promise<WorkspaceActionContext> {
  const externalAction = await loadProjectAction<WorkspaceActionContext & { actionType: string; internal: { runBuiltin: () => Promise<WorkspaceActionContext> } }, WorkspaceActionContext>(ctx.repoPath, action);
  const runBuiltin = async (): Promise<WorkspaceActionContext> => {
    switch (action) {
    case "prepare-worktree":
      return runPrepareWorktreeAction(ctx);
    case "setup-workspace":
      return runSetupWorkspaceAction(ctx);
    case "write-task-context":
      return runWriteTaskContextAction(ctx);
      default:
        throw new Error(`Unknown workspace action: ${action}`);
    }
  };
  const result = externalAction
    ? await externalAction({ ...ctx, actionType: action, internal: { runBuiltin } })
    : await runBuiltin();
  return assertWorkspaceActionResult(action, result);
}
