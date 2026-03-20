import { execFileSync } from "node:child_process";

// ── Pi Binary Detection ──────────────────────────────────────────────────

/** Valid values for the FOREMAN_SPAWN_STRATEGY environment variable. */
export type SpawnStrategyOverride = "pi-rpc" | "tmux" | "detached";

/**
 * Module-level cache for the pi binary availability check.
 * `null` means "not yet checked". Set to true/false after first check.
 */
let piAvailableCache: boolean | null = null;

/**
 * Reset the module-level cache. Exported for use in unit tests only.
 * Not intended for production use.
 */
export function _resetCache(): void {
  piAvailableCache = null;
}

/**
 * Check if the `pi` binary is available on PATH.
 *
 * Uses `which pi` on unix-like systems or `where pi` on Windows.
 * The result is cached for the lifetime of the process — the binary
 * check is only performed once, regardless of how many times this
 * function is called.
 *
 * @returns `true` if `pi` is found on PATH, `false` otherwise.
 */
export function isPiAvailable(): boolean {
  if (piAvailableCache !== null) {
    return piAvailableCache;
  }

  const cmd = process.platform === "win32" ? "where" : "which";

  try {
    execFileSync(cmd, ["pi"], { stdio: "pipe" });
    piAvailableCache = true;
  } catch {
    piAvailableCache = false;
  }

  return piAvailableCache;
}

/**
 * Select the best spawn strategy for the current environment.
 *
 * Priority:
 * 1. `FOREMAN_SPAWN_STRATEGY` environment variable, when set to a known value
 *    (`"pi-rpc"`, `"tmux"`, `"detached"`).
 * 2. Auto-detection: if `pi` is on PATH → `"pi-rpc"`, otherwise `"detached"`.
 *
 * Unknown values for `FOREMAN_SPAWN_STRATEGY` are ignored and fall through
 * to auto-detection.
 *
 * @returns The strategy name string.
 */
export function selectSpawnStrategy(): SpawnStrategyOverride {
  const override = process.env.FOREMAN_SPAWN_STRATEGY;

  if (override === "pi-rpc" || override === "tmux" || override === "detached") {
    return override;
  }

  // Auto-detect based on pi binary presence
  return isPiAvailable() ? "pi-rpc" : "detached";
}

// ── PiRpcSpawnStrategy stub ──────────────────────────────────────────────

/**
 * Stub placeholder for the Pi RPC spawn strategy.
 *
 * The full implementation (SpawnStrategy interface, `spawn()` method,
 * Pi IPC protocol) will be completed in TRD-012.
 */
export class PiRpcSpawnStrategy {}
