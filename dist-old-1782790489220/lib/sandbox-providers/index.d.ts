/**
 * Sandbox Provider Abstraction Layer for Foreman.
 *
 * Exports the `SandboxProvider` interface and the `SandboxProviderFactory` for creating
 * provider instances. Both `DockerSandboxProvider` and `PodmanSandboxProvider` implement
 * `SandboxProvider`.
 *
 * @module src/lib/sandbox-providers
 */
import type { SandboxProvider, SandboxProviderConfig, ResolvedSandboxConfig } from "../sandbox-provider.js";
export type { SandboxProvider } from "../sandbox-provider.js";
export type { SandboxResourceLimits, SandboxMount, SandboxPortMapping, SandboxResult, SandboxRunResult, SandboxProviderConfig, ResolvedSandboxConfig, } from "../sandbox-provider.js";
export { DockerSandboxProvider } from "./docker.js";
export { PodmanSandboxProvider } from "./podman.js";
/**
 * Resolve sandbox backend from config, performing auto-detection if needed.
 *
 * @param config - Sandbox configuration.
 * @returns Resolved backend: 'docker' or 'podman'.
 * @throws Error if backend is 'auto' and neither docker nor podman is available.
 */
export declare function resolveSandboxBackend(config: SandboxProviderConfig): "docker" | "podman";
/**
 * Apply defaults to a sandbox config, returning a fully resolved config.
 */
export declare function resolveSandboxConfig(config: SandboxProviderConfig): ResolvedSandboxConfig;
/**
 * Factory for creating `SandboxProvider` instances.
 *
 * Resolves the backend type from the provided config, using auto-detection
 * if `backend === 'auto'`.
 */
export declare class SandboxProviderFactory {
    /**
     * Create a `SandboxProvider` instance (async, ESM-compatible).
     *
     * @param config - Sandbox configuration (from workflow YAML or project config).
     * @returns A `DockerSandboxProvider` or `PodmanSandboxProvider` instance.
     */
    static create(config: SandboxProviderConfig): Promise<SandboxProvider>;
    /**
     * Create a `SandboxProvider` instance synchronously using direct class instantiation.
     *
     * Prefer `create()` (async) in most contexts. Use `createSync()` only when an
     * async factory is not feasible.
     */
    static createSync(config: SandboxProviderConfig): SandboxProvider;
    /**
     * Resolve the backend type from config, performing auto-detection if needed.
     */
    static resolveBackend(config: SandboxProviderConfig): "docker" | "podman";
    /**
     * Check which sandbox backends are available in the current environment.
     *
     * @returns Object with availability flags for 'docker' and 'podman'.
     */
    static detectAvailable(): Promise<{
        docker: boolean;
        podman: boolean;
    }>;
}
//# sourceMappingURL=index.d.ts.map