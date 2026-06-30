import { Command } from "commander";
import { execFileSync } from "node:child_process";
import { ForemanStore } from "../../lib/store.js";
type Awaitable<T> = T | Promise<T>;
interface InitProjectStore {
    getProjectByPath: (path: string) => Awaitable<{
        id: string;
    } | null>;
    registerProject: (name: string, path: string) => Awaitable<{
        id: string;
    }>;
    getSentinelConfig: (projectId: string) => Awaitable<ReturnType<ForemanStore["getSentinelConfig"]>>;
    upsertSentinelConfig: (projectId: string, config: Parameters<ForemanStore["upsertSentinelConfig"]>[1]) => Awaitable<void>;
}
/**
 * Options bag for initBackend — injectable for testing.
 */
export interface InitBackendOpts {
    /** Directory containing the project (.seeds / .beads live here). */
    projectDir: string;
    /** The issue tracker selected in the wizard (beads/jira/github). */
    issueTracker: "beads" | "jira" | "github";
    execSync?: typeof execFileSync;
    checkExists?: (path: string) => boolean;
}
/**
 * Initialize the task-tracking backend for the given project directory.
 *
 * TRD-024: Native Postgres task store is the only supported backend.
 * Foreman no longer uses beads (br) for task tracking — it writes directly
 * to the native Postgres store. The .beads/ directory is initialized here for
 * backwards compatibility (operators may still use br directly outside foreman).
 *
 * br init is only run when the user selected "beads" as their issue tracker.
 * For jira/github, beads is not used and initialization is skipped.
 *
 * Exported for unit testing.
 */
export declare function initBackend(opts: InitBackendOpts): Promise<void>;
/**
 * Register project and seed default sentinel config if not already present.
 * Exported for unit testing.
 */
export declare function initProjectStore(projectDir: string, projectName: string, store: InitProjectStore): Promise<void>;
export interface JiraWizardConfig {
    apiUrl: string;
    email: string;
    apiToken: string;
    projectKey: string;
    startStatus: string[];
}
export interface GitHubWizardConfig {
    apiUrl: string;
    token: string;
    owner: string;
    repo: string;
    triggerLabels: string[];
}
export interface InitWizardAnswers {
    vcsBackend: "git" | "jujutsu" | "auto";
    workflowTemplate: string;
    issueTracker: "beads" | "jira" | "github";
    jira?: JiraWizardConfig;
    github?: GitHubWizardConfig;
}
export declare function buildInitWizardConfig(answers: InitWizardAnswers): string;
export declare function maybeRegisterInitializedProjectInElixir(projectDir: string, projectName: string): Promise<void>;
export declare function formatInitDatabaseError(err: unknown, projectDir: string): string;
/**
 * Install bundled prompt templates to ~/.foreman/prompts/.
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
export {};
//# sourceMappingURL=init.d.ts.map