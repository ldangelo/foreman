import { spawnSync } from "node:child_process";
export declare const LEGACY_DELEGATABLE_COMMANDS: readonly ["run", "status", "watch", "reset", "retry", "stop", "merge", "pr", "attach", "inbox", "task", "plan", "sling", "doctor"];
export type LegacyDelegatableCommand = (typeof LEGACY_DELEGATABLE_COMMANDS)[number];
export type LegacyDelegationResult = {
    delegated: false;
    reason: "disabled" | "migration-complete" | "not-delegatable" | "missing-command";
} | {
    delegated: true;
    command: LegacyDelegatableCommand;
    bin: string;
    args: string[];
    status: number;
};
type Env = Record<string, string | undefined>;
type Spawn = typeof spawnSync;
export declare function shouldUseLegacyCompatibility(env?: Env): boolean;
export declare function delegatableCommand(argv: string[]): LegacyDelegatableCommand | undefined;
export declare function maybeDelegateToLegacyTs(argv?: string[], env?: Env, spawn?: Spawn): LegacyDelegationResult;
export {};
//# sourceMappingURL=legacy-coexistence.d.ts.map