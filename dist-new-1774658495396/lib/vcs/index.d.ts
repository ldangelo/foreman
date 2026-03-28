/**
 * VCS Backend Abstraction Layer for Foreman.
 *
 * Exports the `VcsBackend` interface and the `VcsBackendFactory` for creating
 * backend instances. Both `GitBackend` and `JujutsuBackend` implement `VcsBackend`.
 *
 * @module src/lib/vcs/index
 */
export type { VcsBackend } from "./interface.js";
export type { Workspace, WorkspaceResult, MergeResult, RebaseResult, DeleteBranchOptions, DeleteBranchResult, PushOptions, FinalizeTemplateVars, FinalizeCommands, VcsConfig, } from "./types.js";
export { GitBackend } from "./git-backend.js";
export { JujutsuBackend } from "./jujutsu-backend.js";
import type { VcsBackend } from "./interface.js";
import type { VcsConfig } from "./types.js";
/**
 * Factory for creating `VcsBackend` instances.
 *
 * Resolves the backend type from the provided `VcsConfig`, using auto-detection
 * if `backend === 'auto'`.
 */
export declare class VcsBackendFactory {
    /**
     * Create a `VcsBackend` instance (async, ESM-compatible).
     *
     * @param config      - VCS configuration (from workflow YAML or project config).
     * @param projectPath - Absolute path to the project root (for auto-detection).
     * @returns A `GitBackend` or `JujutsuBackend` instance.
     */
    static create(config: VcsConfig, projectPath: string): Promise<VcsBackend>;
    /**
     * Create a `VcsBackend` instance synchronously.
     *
     * Note: In ESM modules, prefer `create()` (async). This sync variant works in
     * CommonJS contexts or when the backends have already been loaded.
     */
    static createSync(config: VcsConfig, projectPath: string): VcsBackend;
    /**
     * Resolve the backend type from config, performing auto-detection if needed.
     */
    static resolveBackend(config: VcsConfig, projectPath: string): 'git' | 'jujutsu';
    /**
     * Create a VcsBackend from an environment variable string (async).
     *
     * Used by agent-worker to reconstruct the backend from `FOREMAN_VCS_BACKEND`.
     * Falls back to git if the env var is absent or unrecognized.
     */
    static fromEnv(projectPath: string, envValue?: string): Promise<VcsBackend>;
}
//# sourceMappingURL=index.d.ts.map