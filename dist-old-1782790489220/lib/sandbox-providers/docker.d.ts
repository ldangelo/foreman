/**
 * DockerSandboxProvider — Docker-specific sandbox implementation.
 *
 * Implements the SandboxProvider interface using the `docker` CLI.
 * Supports resource limits, bind mounts, port mapping, and custom user.
 *
 * @module src/lib/sandbox-providers/docker
 */
import type { SandboxProvider, SandboxResult, SandboxRunResult, SandboxResourceLimits, SandboxMount, SandboxPortMapping } from "../sandbox-provider.js";
export declare class DockerSandboxProvider implements SandboxProvider {
    readonly name: "docker";
    /**
     * Execute a docker command.
     * Returns trimmed stdout on success; throws with a formatted error on failure.
     */
    private docker;
    isAvailable(): Promise<boolean>;
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
    runInSandbox(sandboxId: string, command: string[], options?: {
        cwd?: string;
        env?: Record<string, string>;
        timeoutMs?: number;
    }): Promise<SandboxRunResult>;
    destroySandbox(sandboxId: string): Promise<void>;
    getSandboxInfo(sandboxId: string): Promise<{
        id: string;
        status: string;
        created: string;
        image: string;
    } | null>;
    listSandboxes(labelPrefix?: string): Promise<string[]>;
}
//# sourceMappingURL=docker.d.ts.map