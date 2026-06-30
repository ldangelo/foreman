import { Command } from "commander";
/**
 * Legacy helper retained for backward-compatibility tests.
 *
 * Historically sling defaulted to --br-only. Native task migration now ignores
 * the backend-targeting flags, but this helper is retained so older callers and
 * tests do not break while the flag surface remains accepted.
 */
export declare function resolveDefaultBrOnly(opts: {
    sdOnly?: boolean;
    brOnly?: boolean;
}): void;
export declare function applySdOnlyDeprecation(opts: {
    sdOnly?: boolean;
    brOnly?: boolean;
}): boolean;
export declare function getSlingLegacyBackendFlagNotice(): string;
export declare function parsePrdReadinessScore(content: string): number | null;
export declare const slingCommand: Command;
//# sourceMappingURL=sling.d.ts.map