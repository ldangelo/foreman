/**
 * VCS Backend Abstraction Layer for Foreman.
 *
 * Exports the `VcsBackend` interface and the `VcsBackendFactory` for creating
 * backend instances. Both `GitBackend` and `JujutsuBackend` implement `VcsBackend`.
 *
 * @module src/lib/vcs/index
 */
import { existsSync } from "node:fs";
import { join } from "node:path";
import { GitBackend } from "./git-backend.js";
import { JujutsuBackend } from "./jujutsu-backend.js";
export { GitBackend } from "./git-backend.js";
export { JujutsuBackend } from "./jujutsu-backend.js";
export class VcsBackendFactory {
    /**
     * Create a `VcsBackend` instance (async, ESM-compatible).
     *
     * @param config      - VCS configuration (from workflow YAML or project config).
     * @param projectPath - Absolute path to the project root (for auto-detection).
     * @returns A `GitBackend` or `JujutsuBackend` instance.
     */
    static async create(config, projectPath) {
        const resolved = VcsBackendFactory.resolveBackend(config, projectPath);
        if (resolved === 'jujutsu') {
            const { JujutsuBackend } = await import("./jujutsu-backend.js");
            return new JujutsuBackend(projectPath);
        }
        const { GitBackend } = await import("./git-backend.js");
        return new GitBackend(projectPath);
    }
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
    static createSync(config, projectPath) {
        const resolved = VcsBackendFactory.resolveBackend(config, projectPath);
        if (resolved === 'jujutsu') {
            return new JujutsuBackend(projectPath);
        }
        return new GitBackend(projectPath);
    }
    /**
     * Resolve the backend type from config, performing auto-detection if needed.
     *
     * @throws {Error} If `backend === 'auto'` and neither `.git/` nor `.jj/` exists.
     * @throws {Error} If `backend` is not a recognized value ('git', 'jujutsu', 'auto').
     */
    static resolveBackend(config, projectPath) {
        if (config.backend === 'auto') {
            // Auto-detect: presence of .jj/ directory indicates Jujutsu (takes precedence)
            if (existsSync(join(projectPath, '.jj'))) {
                return 'jujutsu';
            }
            // Fall back to git if .git/ exists
            if (existsSync(join(projectPath, '.git'))) {
                return 'git';
            }
            throw new Error(`VcsBackendFactory: auto-detection failed — neither .git/ nor .jj/ found in "${projectPath}". ` +
                `Initialize a git repository (git init) or jujutsu repository (jj git init) first.`);
        }
        if (config.backend === 'git' || config.backend === 'jujutsu') {
            return config.backend;
        }
        // Runtime guard for invalid backend values (e.g., when using 'as any' casts)
        throw new Error(`VcsBackendFactory: unrecognized backend "${String(config.backend)}". ` +
            `Valid values are: 'git', 'jujutsu', 'auto'.`);
    }
    /**
     * Create a VcsBackend from an environment variable string (async).
     *
     * Used by agent-worker to reconstruct the backend from `FOREMAN_VCS_BACKEND`.
     * Falls back to git if the env var is absent or unrecognized.
     */
    static async fromEnv(projectPath, envValue) {
        const backend = envValue === 'jujutsu' ? 'jujutsu' : 'git';
        return VcsBackendFactory.create({ backend }, projectPath);
    }
}
//# sourceMappingURL=index.js.map