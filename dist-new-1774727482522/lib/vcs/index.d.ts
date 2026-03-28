/**
 * VCS Backend Abstraction Layer for Foreman.
 *
 * Exports the `VcsBackend` interface and the `VcsBackendFactory` for creating
 * backend instances. Both `GitBackend` and `JujutsuBackend` implement `VcsBackend`.
 *
 * @module src/lib/vcs/index
 */
import type { VcsBackend } from "./interface.js";
import type { VcsConfig } from "./types.js";
export type { VcsBackend } from "./interface.js";
export type { Workspace, WorkspaceResult, MergeResult, RebaseResult, DeleteBranchOptions, DeleteBranchResult, PushOptions, FinalizeTemplateVars, FinalizeCommands, VcsConfig, } from "./types.js";
export { GitBackend } from "./git-backend.js";
export { JujutsuBackend } from "./jujutsu-backend.js";
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
  <<<<<<< Updated upstream
     * Create a `VcsBackend` instance synchronously using direct class instantiation.
  ||||||| Stash base
     * Create a `VcsBackend` instance synchronously.
  =======
     * Create a `VcsBackend` instance synchronously using the statically imported
     * backend classes.
  >>>>>>> Stashed changes
     *
  <<<<<<< Updated upstream
     * This method avoids `require()` (which is not available in ESM) by importing the
     * concrete backend classes at the top of the file. Both `GitBackend` and
     * `JujutsuBackend` are exported above and available synchronously.
     *
     * Prefer `create()` (async) in most contexts. Use `createSync()` only when an
     * async factory is not feasible (e.g., inside constructors or synchronous init code).
  ||||||| Stash base
     * Note: In ESM modules, prefer `create()` (async). This sync variant works in
     * CommonJS contexts or when the backends have already been loaded.
  =======
     * Both `GitBackend` and `JujutsuBackend` are imported at the top of this module
     * (since they are also re-exported), so both are always available synchronously.
     * Prefer `create()` (async) when lazy-loading is important; use `createSync()`
     * when an async factory is not feasible (e.g. inside constructors or sync init).
  >>>>>>> Stashed changes
     */
    static createSync(config: VcsConfig, projectPath: string): VcsBackend;
    /**
     * Resolve the backend type from config, performing auto-detection if needed.
     *
     * @throws {Error} If `backend === 'auto'` and neither `.git/` nor `.jj/` exists.
     * @throws {Error} If `backend` is not a recognized value ('git', 'jujutsu', 'auto').
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