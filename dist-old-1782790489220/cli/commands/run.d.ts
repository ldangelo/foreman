import { Command } from "commander";
import type { ITaskClient } from "../../lib/task-client.js";
import type { ProjectConfig } from "../../lib/project-config.js";
import type { VcsBackend } from "../../lib/vcs/interface.js";
export { autoMerge } from "../../orchestrator/auto-merge.js";
export type { AutoMergeOpts, AutoMergeResult } from "../../orchestrator/auto-merge.js";
/**
 * Result returned by createTaskClients.
 * Contains the task client to pass to Dispatcher.
 * The native Postgres task store is the only supported backend (TRD-024).
 */
export interface TaskClientResult {
    taskClient: ITaskClient;
    bvClient: null;
    backendType: "native";
}
export type RuntimeMode = "normal" | "test";
export declare function resolveRuntimeMode(value?: string): RuntimeMode;
/**
 * Instantiate the br task-tracking client(s).
 *
 * TRD-024: sd backend removed. Always returns a BeadsRustClient after verifying
 * plus a BvClient for graph-aware triage.
 */
export declare function createTaskClients(projectPath: string, _runtimeMode?: RuntimeMode, registeredProjectId?: string): Promise<TaskClientResult>;
export { isIgnorableControllerPath } from "../../lib/controller-paths.js";
export interface OwnedBranchResolution {
    currentBranch: string;
    defaultBranch: string;
    targetBranch?: string;
    usedOwnedBranch: boolean;
}
export declare function resolveOwnedControllerBranch(vcs: VcsBackend, projectPath: string, preferredDefaultBranch?: string): Promise<OwnedBranchResolution>;
export declare function collectRuntimeAssetIssues(projectPath: string, projectCfg?: ProjectConfig | null): string[];
export declare function checkBranchMismatch(taskClient: ITaskClient, projectPath: string): Promise<boolean>;
/**
 * Validate a `--workflow <name>` override before dispatch.
 *
 * Fails fast when the named workflow cannot be loaded (not bundled, not in
 * ~/.foreman/workflows/, not a valid YAML path), returning an error message
 * that lists the available workflow names.
 */
export declare function validateWorkflowOverride(workflowName: string, projectPath: string): {
    ok: true;
} | {
    ok: false;
    message: string;
};
export declare const runCommand: Command;
//# sourceMappingURL=run.d.ts.map