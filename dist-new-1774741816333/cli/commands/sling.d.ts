import { Command } from "commander";
/**
 * Checks if --sd-only is set; if so, prints a deprecation warning to stderr
 * and clears the flag so the command behaves as br-only.
 *
 * Returns true if the warning was emitted (flag was set), false otherwise.
 */
/**
 * TRD-022: br-only is now the default write target.
 * When neither --sd-only nor --br-only is specified, br-only is used.
 * --br-only flag is retained but is now a no-op (already the default).
 *
 * Exported for testing.
 */
export declare function resolveDefaultBrOnly(opts: {
    sdOnly?: boolean;
    brOnly?: boolean;
}): void;
export declare function applySdOnlyDeprecation(opts: {
    sdOnly?: boolean;
    brOnly?: boolean;
}): boolean;
export declare const slingCommand: Command;
//# sourceMappingURL=sling.d.ts.map