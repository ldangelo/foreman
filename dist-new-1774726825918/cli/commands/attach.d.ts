import { Command } from "commander";
import { ForemanStore } from "../../lib/store.js";
export interface AttachOpts {
    list?: boolean;
    follow?: boolean;
    kill?: boolean;
    worktree?: boolean;
    stream?: boolean;
    /** Internal: AbortSignal for follow/stream mode (used by tests) */
    _signal?: AbortSignal;
    /** Internal: poll interval ms for stream mode (used by tests) */
    _pollIntervalMs?: number;
}
/**
 * Core attach logic extracted for testability.
 * Returns the exit code (0 = success, 1 = error).
 * When called from the CLI command, `projectPath` is `process.cwd()`.
 */
export declare function attachAction(id: string, opts: AttachOpts, store: ForemanStore, projectPath: string): Promise<number>;
/**
 * Enhanced session listing with richer columns.
 */
export declare function listSessionsEnhanced(store: ForemanStore, projectPath: string): void;
export declare const attachCommand: Command;
//# sourceMappingURL=attach.d.ts.map