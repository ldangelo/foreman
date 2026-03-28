import { Command } from "commander";
import { execFileSync } from "node:child_process";
import { ForemanStore } from "../../lib/store.js";
/**
 * Options bag for initBackend — injectable for testing.
 */
export interface InitBackendOpts {
    /** Directory containing the project (.seeds / .beads live here). */
    projectDir: string;
    execSync?: typeof execFileSync;
    checkExists?: (path: string) => boolean;
}
/**
 * Initialize the task-tracking backend for the given project directory.
 *
 * TRD-024: sd backend removed. Always uses the br (beads_rust) backend.
 *   - Skips sd installation check and sd init entirely.
 *   - Runs `br init` if .beads/ does not already exist.
 *
 * Exported for unit testing.
 */
export declare function initBackend(opts: InitBackendOpts): Promise<void>;
/**
 * Register project and seed default sentinel config if not already present.
 * Exported for unit testing.
 */
export declare function initProjectStore(projectDir: string, projectName: string, store: ForemanStore): Promise<void>;
/**
 * Install bundled prompt templates to <projectDir>/.foreman/prompts/.
 * Exported for unit testing.
 *
 * @param projectDir - Absolute path to the project directory
 * @param force      - Overwrite existing prompt files
 */
export declare function installPrompts(projectDir: string, force?: boolean): {
    installed: string[];
    skipped: string[];
};
export declare const initCommand: Command;
//# sourceMappingURL=init.d.ts.map