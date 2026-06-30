/**
 * SandboxProvider interface definition.
 *
 * Mirrors the VcsBackend pattern for backend-agnostic abstraction.
 * Implementations: DockerSandboxProvider, PodmanSandboxProvider.
 *
 * @module src/lib/sandbox-provider
 */
/**
 * Container resource limits for sandbox isolation.
 */
export interface SandboxResourceLimits {
    /** Maximum CPU units (e.g., "1" for 1 CPU, "0.5" for half). */
    cpu?: string;
    /** Memory limit (e.g., "2g" for 2GB, "512m" for 512MB). */
    memory?: string;
    /** Optional: specific CPUs to allow (e.g., "0-1" for cores 0-1). */
    cpuset?: string;
    /** Maximum swap memory (e.g., "1g"). */
    memorySwap?: string;
    /**
     * Explicit list of Linux capabilities to grant.
     * If not provided, no additional capabilities are added (default Docker/Podman security).
     * Example: ["NET_ADMIN", "SYS_PTRACE"]
     */
    capabilities?: string[];
}
/**
 * Volume mount configuration for sandbox.
 */
export interface SandboxMount {
    /** Source path on the host. */
    source: string;
    /** Destination path inside the container. */
    destination: string;
    /** Mount type: 'bind' (default) or 'volume'. */
    type?: "bind" | "volume";
    /** Read-only mount. Default: false. */
    readOnly?: boolean;
}
/**
 * Port mapping for sandbox networking.
 */
export interface SandboxPortMapping {
    /** Host port. */
    host: number;
    /** Container port. */
    container: number;
    /** Protocol: 'tcp' (default) or 'udp'. */
    protocol?: "tcp" | "udp";
}
/**
 * Result of creating a sandbox.
 */
export interface SandboxResult {
    /** Unique sandbox identifier (container ID). */
    id: string;
    /** Working directory inside the container. */
    workdir: string;
    /** Mounted volumes mapping. */
    mounts: SandboxMount[];
}
/**
 * Result of running a command in a sandbox.
 */
export interface SandboxRunResult {
    /** Exit code from the command. */
    exitCode: number;
    /** Standard output from the command. */
    stdout: string;
    /** Standard error from the command. */
    stderr: string;
}
/**
 * Backend-agnostic interface for container sandbox operations.
 *
 * Both `DockerSandboxProvider` and `PodmanSandboxProvider` implement this interface
 * so that orchestration code is decoupled from the concrete container runtime.
 */
export interface SandboxProvider {
    /** Name identifier for this backend ('docker' or 'podman'). */
    readonly name: "docker" | "podman";
    /**
     * Create a new sandbox container.
     *
     * @param worktreePath - Host path to mount as the working directory.
     * @param image - Container image to use (e.g., 'ubuntu:22.04').
     * @param options - Optional sandbox configuration (limits, mounts, etc.).
     * @returns SandboxResult with container ID and working directory.
     */
    createSandbox(worktreePath: string, image: string, options?: {
        label?: string;
        limits?: SandboxResourceLimits;
        mounts?: SandboxMount[];
        ports?: SandboxPortMapping[];
        network?: boolean;
        user?: string;
        cleanup?: "remove" | "keep";
        labelPrefix?: string;
    }): Promise<SandboxResult>;
    /**
     * Run a command inside a sandbox container.
     *
     * @param sandboxId - The sandbox/container ID from createSandbox.
     * @param command - Command to execute (array of strings).
     * @param options - Optional run configuration (cwd, env, timeout).
     * @returns SandboxRunResult with exit code, stdout, and stderr.
     */
    runInSandbox(sandboxId: string, command: string[], options?: {
        cwd?: string;
        env?: Record<string, string>;
        timeoutMs?: number;
    }): Promise<SandboxRunResult>;
    /**
     * Destroy a sandbox container and clean up resources.
     *
     * @param sandboxId - The sandbox/container ID to destroy.
     */
    destroySandbox(sandboxId: string): Promise<void>;
    /**
     * Get information about a sandbox container.
     *
     * @param sandboxId - The sandbox/container ID.
     * @returns Sandbox info or null if not found.
     */
    getSandboxInfo(sandboxId: string): Promise<{
        id: string;
        status: string;
        created: string;
        image: string;
    } | null>;
    /**
     * List all active sandboxes matching a label prefix.
     *
     * @param labelPrefix - Label prefix to filter by (e.g., 'foreman-').
     * @returns Array of sandbox IDs.
     */
    listSandboxes(labelPrefix?: string): Promise<string[]>;
    /**
     * Check if the container runtime is available and responsive.
     *
     * @returns True if the runtime is available.
     */
    isAvailable(): Promise<boolean>;
}
/**
 * Sandbox provider configuration (from project config or workflow YAML).
 */
export interface SandboxProviderConfig {
    /**
     * Which sandbox backend to use.
     * - 'docker'  — always use Docker
     * - 'podman'  — always use Podman
     * - 'auto'    — detect from environment (default)
     */
    backend: "docker" | "podman" | "auto";
    /**
     * Container image to use for sandboxes.
     * Default: 'ubuntu:22.04'.
     */
    image?: string;
    /**
     * Resource limits for sandbox containers.
     */
    limits?: SandboxResourceLimits;
    /**
     * Additional volume mounts (beyond the worktree bind mount).
     */
    mounts?: SandboxMount[];
    /**
     * Port mappings for sandbox networking.
     */
    ports?: SandboxPortMapping[];
    /**
     * Enable networking in sandbox. Default: false.
     */
    network?: boolean;
    /**
     * Container user (uid:gid format or username).
     * Uses host user by default for permission alignment.
     */
    user?: string;
    /**
     * Cleanup policy when sandbox is destroyed.
     * - 'remove'  — remove container after destroy (default)
     * - 'keep'    — leave container stopped for debugging
     */
    cleanup?: "remove" | "keep";
}
/**
 * Resolved sandbox configuration with defaults applied.
 */
export interface ResolvedSandboxConfig {
    backend: "docker" | "podman";
    image: string;
    limits: SandboxResourceLimits | undefined;
    mounts: SandboxMount[];
    ports: SandboxPortMapping[];
    network: boolean;
    user: string | undefined;
    cleanup: "remove" | "keep";
}
//# sourceMappingURL=sandbox-provider.d.ts.map