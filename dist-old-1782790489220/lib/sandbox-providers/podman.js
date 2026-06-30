/**
 * PodmanSandboxProvider — Podman-specific sandbox implementation.
 *
 * Implements the SandboxProvider interface using the `podman` CLI.
 * Supports resource limits, bind mounts, port mapping, and custom user.
 *
 * @module src/lib/sandbox-providers/podman
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";
const execFileAsync = promisify(execFile);
// ── PodmanSandboxProvider ─────────────────────────────────────────────────────
export class PodmanSandboxProvider {
    name = "podman";
    /**
     * Execute a podman command.
     * Returns trimmed stdout on success; throws with a formatted error on failure.
     */
    async podman(args, timeoutMs = 60_000) {
        try {
            const { stdout } = await execFileAsync("podman", args, {
                maxBuffer: 10 * 1024 * 1024,
                timeout: timeoutMs,
                env: {
                    ...process.env,
                },
            });
            return stdout.trim();
        }
        catch (err) {
            const e = err;
            const combined = [e.stdout, e.stderr]
                .map((s) => (s ?? "").trim())
                .filter(Boolean)
                .join("\n") || e.message || String(err);
            throw new Error(`podman ${args[0]} failed: ${combined}`);
        }
    }
    async isAvailable() {
        try {
            await this.podman(["version"], 10_000);
            return true;
        }
        catch {
            return false;
        }
    }
    async createSandbox(worktreePath, image, options) {
        const containerName = options?.label ?? `foreman-sandbox-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
        // Build podman run arguments
        const args = [
            "run",
            "--detach",
            "--name", containerName,
            "--init",
        ];
        // Add foreman-owned label so listSandboxes() can find these containers
        const labelKey = `${options?.labelPrefix ?? "foreman-"}owned`;
        args.push("--label", `${labelKey}=true`);
        // Resource limits
        if (options?.limits) {
            const { cpu, memory, cpuset, memorySwap, capabilities } = options.limits;
            if (cpu) {
                args.push("--cpus", cpu);
            }
            if (memory) {
                args.push("--memory", memory);
            }
            if (cpuset) {
                args.push("--cpuset-cpus", cpuset);
            }
            if (memorySwap) {
                args.push("--memory-swap", memorySwap);
            }
            // Security: add only explicitly requested capabilities (default Podman security stays in effect)
            if (capabilities && capabilities.length > 0) {
                for (const cap of capabilities) {
                    args.push("--cap-add", cap);
                }
            }
        }
        // Bind mount the worktree as working directory
        args.push("-v", `${worktreePath}:/workspace`);
        args.push("-w", "/workspace");
        // Additional mounts
        if (options?.mounts) {
            for (const mount of options.mounts) {
                const mountStr = `${mount.source}:${mount.destination}${mount.readOnly ? ":ro" : ""}`;
                args.push("-v", mountStr);
            }
        }
        // Port mappings
        if (options?.ports) {
            for (const port of options.ports) {
                const protocol = port.protocol ?? "tcp";
                args.push("-p", `${port.host}:${port.container}/${protocol}`);
            }
        }
        // Network mode: disabled by default; opt in with network: true.
        if (options?.network !== true) {
            args.push("--network", "none");
        }
        // User (uid:gid or username)
        if (options?.user) {
            args.push("--user", options.user);
        }
        // Security: use default SELinux labeling and minimal capabilities
        // Add specific capabilities via SandboxResourceLimits.capabilities if needed
        // Remove container on exit only if cleanup policy is 'remove'
        if (options?.cleanup !== "keep") {
            args.push("--rm");
        }
        // Image
        args.push(image);
        // Default command: sleep infinity to keep container running
        args.push("sleep", "infinity");
        const output = await this.podman(args);
        const containerId = output.slice(0, 12); // Podman returns short ID
        return {
            id: containerId,
            workdir: "/workspace",
            mounts: [
                { source: worktreePath, destination: "/workspace", type: "bind", readOnly: false },
                ...(options?.mounts ?? []),
            ],
        };
    }
    async runInSandbox(sandboxId, command, options) {
        // Build podman exec arguments
        const args = ["exec"];
        // Working directory
        if (options?.cwd) {
            args.push("-w", options.cwd);
        }
        // Environment variables
        if (options?.env) {
            for (const [key, value] of Object.entries(options.env)) {
                args.push("-e", `${key}=${value}`);
            }
        }
        // Interactive terminal (use -i only for programmatic execution)
        args.push("-i");
        // Container ID
        args.push(sandboxId);
        // Command to execute
        args.push(...command);
        try {
            const result = await execFileAsync("podman", args, {
                maxBuffer: 10 * 1024 * 1024,
                timeout: options?.timeoutMs ?? 300_000,
                env: {
                    ...process.env,
                    TERM: process.env.TERM ?? "xterm-256color",
                },
            });
            return {
                exitCode: 0,
                stdout: result.stdout.trim(),
                stderr: result.stderr.trim(),
            };
        }
        catch (err) {
            const e = err;
            const numericCode = typeof e.code === "number" ? e.code : typeof e.code === "string" ? Number.parseInt(e.code, 10) : NaN;
            const exitCode = Number.isFinite(numericCode) ? numericCode : 1;
            return {
                exitCode,
                stdout: e.stdout?.trim() ?? "",
                stderr: (e.stderr ?? e.message ?? String(err)).trim(),
            };
        }
    }
    async destroySandbox(sandboxId) {
        try {
            // Force remove the container (ignore errors if already removed)
            await this.podman(["rm", "-f", sandboxId], 30_000);
        }
        catch {
            // Container may already be removed — that's fine
        }
    }
    async getSandboxInfo(sandboxId) {
        try {
            const output = await this.podman([
                "inspect",
                "--format", "{{.Id}}|{{.State.Status}}|{{.Created}}|{{.Config.Image}}",
                sandboxId,
            ]);
            const [id, status, created, image] = output.split("|");
            if (!id)
                return null;
            return { id, status, created, image };
        }
        catch {
            return null;
        }
    }
    async listSandboxes(labelPrefix = "foreman-") {
        try {
            const output = await this.podman([
                "ps",
                "--filter", `label=${labelPrefix}owned=true`,
                "--format", "{{.ID}}",
            ]);
            if (!output.trim())
                return [];
            return output
                .split("\n")
                .map((id) => id.trim())
                .filter(Boolean);
        }
        catch {
            return [];
        }
    }
}
//# sourceMappingURL=podman.js.map