import { spawnSync, type SpawnSyncReturns } from "node:child_process";
import { resolve } from "node:path";

export const LEGACY_DELEGATABLE_COMMANDS = [
  "run",
  "status",
  "watch",
  "reset",
  "retry",
  "stop",
  "merge",
  "pr",
  "attach",
  "inbox",
  "task",
  "plan",
  "sling",
  "doctor",
] as const;

export type LegacyDelegatableCommand = (typeof LEGACY_DELEGATABLE_COMMANDS)[number];

export type LegacyDelegationResult =
  | { delegated: false; reason: "disabled" | "migration-complete" | "not-delegatable" | "missing-command" }
  | { delegated: true; command: LegacyDelegatableCommand; bin: string; args: string[]; status: number };

type Env = Record<string, string | undefined>;
type Spawn = typeof spawnSync;

const enabledValues = new Set(["1", "true", "yes", "legacy", "delegate"]);
const completeValues = new Set(["1", "true", "yes", "complete", "completed"]);

export function shouldUseLegacyCompatibility(env: Env = process.env): boolean {
  const value = (env.FOREMAN_LEGACY_COMPATIBILITY_MODE ?? env.FOREMAN_COMPATIBILITY_MODE ?? "").toLowerCase();
  const complete = (env.FOREMAN_MIGRATION_COMPLETE ?? "").toLowerCase();
  return enabledValues.has(value) && !completeValues.has(complete);
}

export function delegatableCommand(argv: string[]): LegacyDelegatableCommand | undefined {
  const command = argv.find((arg) => arg && !arg.startsWith("-"));
  if (!command) return undefined;
  return (LEGACY_DELEGATABLE_COMMANDS as readonly string[]).includes(command)
    ? (command as LegacyDelegatableCommand)
    : undefined;
}

export function maybeDelegateToLegacyTs(
  argv: string[] = process.argv.slice(2),
  env: Env = process.env,
  spawn: Spawn = spawnSync,
): LegacyDelegationResult {
  if (!shouldUseLegacyCompatibility(env)) {
    return {
      delegated: false,
      reason: completeValues.has((env.FOREMAN_MIGRATION_COMPLETE ?? "").toLowerCase())
        ? "migration-complete"
        : "disabled",
    };
  }

  const command = delegatableCommand(argv);
  if (!command) return { delegated: false, reason: argv.length === 0 ? "missing-command" : "not-delegatable" };

  const bin = env.FOREMAN_LEGACY_TS_BIN || env.FOREMAN_LEGACY_FOREMAN_BIN;
  if (!bin) {
    throw new Error(
      `legacy compatibility mode is enabled but FOREMAN_LEGACY_TS_BIN is not set for '${command}' delegation`,
    );
  }

  const currentEntrypoint = process.argv[1] ? resolve(process.argv[1]) : undefined;
  if (currentEntrypoint && resolve(bin) === currentEntrypoint) {
    throw new Error("FOREMAN_LEGACY_TS_BIN points to the active Foreman entrypoint; refusing recursive delegation");
  }

  const result = spawn(bin, argv, { stdio: "inherit", env: env as NodeJS.ProcessEnv }) as SpawnSyncReturns<Buffer>;
  if (result.error) throw result.error;

  return { delegated: true, command, bin, args: argv, status: result.status ?? 1 };
}
