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
export { GitBackend } from "./git-backend.js";
export { JujutsuBackend } from "./jujutsu-backend.js";
// ── VcsBackendFactory ────────────────────────────────────────────────────────
/**
 * Factory for creating `VcsBackend` instances.
 *
 * Resolves the backend type from the provided `VcsConfig`, using auto-detection
 * if `backend === 'auto'`.
 */
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
     * Create a `VcsBackend` instance synchronously.
     *
     * Note: In ESM modules, prefer `create()` (async). This sync variant works in
     * CommonJS contexts or when the backends have already been loaded.
     */
    static createSync(config, projectPath) {
        const resolved = VcsBackendFactory.resolveBackend(config, projectPath);
        if (resolved === 'jujutsu') {
            // Dynamic require for sync usage
            // eslint-disable-next-line @typescript-eslint/no-require-imports
            const mod = require("./jujutsu-backend.js");
            return new mod.JujutsuBackend(projectPath);
        }
        // eslint-disable-next-line @typescript-eslint/no-require-imports
        const mod = require("./git-backend.js");
        return new mod.GitBackend(projectPath);
    }
    /**
     * Resolve the backend type from config, performing auto-detection if needed.
     */
    static resolveBackend(config, projectPath) {
        if (config.backend !== 'auto') {
            return config.backend;
        }
        // Auto-detect: presence of .jj/ directory indicates Jujutsu
        if (existsSync(join(projectPath, '.jj'))) {
            return 'jujutsu';
        }
        // Default to git
        return 'git';
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