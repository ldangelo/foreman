/**
 * PodmanSandboxProvider — Podman-specific sandbox implementation.
 *
 * Implements the SandboxProvider interface using the `podman` CLI.
 * Supports resource limits, bind mounts, port mapping, and custom user.
 *
 * @module src/lib/sandbox-providers/podman
 */
import type { SandboxProvider, SandboxResult, SandboxRunResult, SandboxResourceLimits, SandboxMount, SandboxPortMapping } from "../sandbox-provider.js";
export declare class PodmanSandboxProvider implements SandboxProvider {
    readonly name: "podman";
    /**
     * Execute a podman command.
     * Returns trimmed stdout on success; throws with a formatted error on failure.
     */
    private podman;
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
//# sourceMappingURL=podman.d.ts.map