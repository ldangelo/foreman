/**
 * Sandbox Provider Abstraction Layer for Foreman.
 *
 * Exports the `SandboxProvider` interface and the `SandboxProviderFactory` for creating
 * provider instances. Both `DockerSandboxProvider` and `PodmanSandboxProvider` implement
 * `SandboxProvider`.
 *
 * @module src/lib/sandbox-providers
 */

import { existsSync } from "node:fs";
import { execFileSync } from "node:child_process";

import type { SandboxProvider, SandboxProviderConfig, ResolvedSandboxConfig } from "../sandbox-provider.js";
import { DockerSandboxProvider } from "./docker.js";
import { PodmanSandboxProvider } from "./podman.js";

// Re-export types and classes for external consumption
export type { SandboxProvider } from "../sandbox-provider.js";
export type {
  SandboxResourceLimits,
  SandboxMount,
  SandboxPortMapping,
  SandboxResult,
  SandboxRunResult,
  SandboxProviderConfig,
  ResolvedSandboxConfig,
} from "../sandbox-provider.js";
export { DockerSandboxProvider } from "./docker.js";
export { PodmanSandboxProvider } from "./podman.js";

// ── SandboxProviderFactory ────────────────────────────────────────────────────

/**
 * Default container image for sandboxes.
 */
const DEFAULT_SANDBOX_IMAGE = "ubuntu:22.04";
const RUNTIME_PROBE_TIMEOUT_MS = 2_000;

function canRunContainerCli(binary: "docker" | "podman"): boolean {
  try {
    execFileSync(binary, ["version"], { stdio: "pipe", timeout: RUNTIME_PROBE_TIMEOUT_MS });
    return true;
  } catch {
    return false;
  }
}

/**
 * Resolve sandbox backend from config, performing auto-detection if needed.
 *
 * @param config - Sandbox configuration.
 * @returns Resolved backend: 'docker' or 'podman'.
 * @throws Error if backend is 'auto' and neither docker nor podman is available.
 */
export function resolveSandboxBackend(config: SandboxProviderConfig): "docker" | "podman" {
  if (config.backend !== "auto") {
    return config.backend;
  }

  // Auto-detect: prefer Docker when environment indicators exist, but only
  // after verifying the CLI is runnable. CLI probes use timeouts to avoid hangs.
  if ((existsSync("/var/run/docker.sock") || process.env.DOCKER_HOST) && canRunContainerCli("docker")) {
    return "docker";
  }

  if (canRunContainerCli("docker")) {
    return "docker";
  }

  if (canRunContainerCli("podman")) {
    return "podman";
  }

  throw new Error(
    "SandboxProviderFactory: auto-detection failed — neither docker nor podman found. " +
    "Install Docker or Podman, or explicitly set sandbox.backend to 'docker' or 'podman'."
  );
}

/**
 * Apply defaults to a sandbox config, returning a fully resolved config.
 */
export function resolveSandboxConfig(config: SandboxProviderConfig): ResolvedSandboxConfig {
  const resolved: ResolvedSandboxConfig = {
    backend: resolveSandboxBackend(config),
    image: config.image ?? DEFAULT_SANDBOX_IMAGE,
    limits: config.limits,
    mounts: config.mounts ?? [],
    ports: config.ports ?? [],
    network: config.network ?? false,
    user: config.user,
    cleanup: config.cleanup ?? "remove",
  };

  return resolved;
}

/**
 * Factory for creating `SandboxProvider` instances.
 *
 * Resolves the backend type from the provided config, using auto-detection
 * if `backend === 'auto'`.
 */
export class SandboxProviderFactory {
  /**
   * Create a `SandboxProvider` instance (async, ESM-compatible).
   *
   * @param config - Sandbox configuration (from workflow YAML or project config).
   * @returns A `DockerSandboxProvider` or `PodmanSandboxProvider` instance.
   */
  static async create(config: SandboxProviderConfig): Promise<SandboxProvider> {
    const resolved = resolveSandboxConfig(config);

    if (resolved.backend === "podman") {
      return new PodmanSandboxProvider();
    }

    return new DockerSandboxProvider();
  }

  /**
   * Create a `SandboxProvider` instance synchronously using direct class instantiation.
   *
   * Prefer `create()` (async) in most contexts. Use `createSync()` only when an
   * async factory is not feasible.
   */
  static createSync(config: SandboxProviderConfig): SandboxProvider {
    const resolved = resolveSandboxConfig(config);

    if (resolved.backend === "podman") {
      return new PodmanSandboxProvider();
    }

    return new DockerSandboxProvider();
  }

  /**
   * Resolve the backend type from config, performing auto-detection if needed.
   */
  static resolveBackend(config: SandboxProviderConfig): "docker" | "podman" {
    return resolveSandboxBackend(config);
  }

  /**
   * Check which sandbox backends are available in the current environment.
   *
   * @returns Object with availability flags for 'docker' and 'podman'.
   */
  static async detectAvailable(): Promise<{ docker: boolean; podman: boolean }> {
    const docker = new DockerSandboxProvider();
    const podman = new PodmanSandboxProvider();

    const [dockerAvailable, podmanAvailable] = await Promise.all([
      docker.isAvailable(),
      podman.isAvailable(),
    ]);

    return {
      docker: dockerAvailable,
      podman: podmanAvailable,
    };
  }
}