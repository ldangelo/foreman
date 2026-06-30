import { spawnSync } from "node:child_process";
import { resolve } from "node:path";
import { foremanBackendMode, migrationComplete } from "../lib/backend-mode.js";
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
];
const enabledValues = new Set(["1", "true", "yes", "legacy", "delegate"]);
const completeValues = new Set(["1", "true", "yes", "complete", "completed"]);
export function shouldUseLegacyCompatibility(env = process.env) {
    const value = (env.FOREMAN_LEGACY_COMPATIBILITY_MODE ?? env.FOREMAN_COMPATIBILITY_MODE ?? "").toLowerCase();
    return enabledValues.has(value) && !migrationComplete(env) && foremanBackendMode(env) !== "elixir";
}
export function delegatableCommand(argv) {
    const command = argv.find((arg) => arg && !arg.startsWith("-"));
    if (!command)
        return undefined;
    return LEGACY_DELEGATABLE_COMMANDS.includes(command)
        ? command
        : undefined;
}
export function maybeDelegateToLegacyTs(argv = process.argv.slice(2), env = process.env, spawn = spawnSync) {
    if (!shouldUseLegacyCompatibility(env)) {
        return {
            delegated: false,
            reason: completeValues.has((env.FOREMAN_MIGRATION_COMPLETE ?? "").toLowerCase()) || foremanBackendMode(env) === "elixir"
                ? "migration-complete"
                : "disabled",
        };
    }
    const command = delegatableCommand(argv);
    if (!command)
        return { delegated: false, reason: argv.length === 0 ? "missing-command" : "not-delegatable" };
    const bin = env.FOREMAN_LEGACY_TS_BIN || env.FOREMAN_LEGACY_FOREMAN_BIN;
    if (!bin) {
        throw new Error(`legacy compatibility mode is enabled but FOREMAN_LEGACY_TS_BIN is not set for '${command}' delegation`);
    }
    const currentEntrypoint = process.argv[1] ? resolve(process.argv[1]) : undefined;
    if (currentEntrypoint && resolve(bin) === currentEntrypoint) {
        throw new Error("FOREMAN_LEGACY_TS_BIN points to the active Foreman entrypoint; refusing recursive delegation");
    }
    const result = spawn(bin, argv, { stdio: "inherit", env: env });
    if (result.error)
        throw result.error;
    return { delegated: true, command, bin, args: argv, status: result.status ?? 1 };
}
//# sourceMappingURL=legacy-coexistence.js.map