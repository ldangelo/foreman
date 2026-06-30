export interface RegisteredProjectSummary {
    id: string;
    name: string;
    path: string;
    githubUrl?: string;
    defaultBranch?: string;
    status?: string;
}
export declare function listRegisteredProjects(): Promise<RegisteredProjectSummary[]>;
export declare function registerProjectInElixir(projectPath: string, opts?: {
    name?: string;
    defaultBranch?: string;
    status?: "active" | "paused" | "archived";
}): Promise<RegisteredProjectSummary>;
export declare function ensureCliPostgresPool(projectPath: string): void;
export declare function resolveProjectPathFromOptions(opts: {
    project?: string;
    projectPath?: string;
}): Promise<string>;
export declare function resolveProjectPathFromOption(project?: string): Promise<string>;
export declare function resolveRepoRootProjectPath(opts: {
    project?: string;
    projectPath?: string;
}): Promise<string>;
/**
 * Detect whether the project registry has 2+ projects (multi-project mode).
 * In multi-project mode, commands should require --project flag.
 */
export declare function isMultiProjectMode(): Promise<boolean>;
/**
 * Require --project flag in multi-project mode.
 * Throws an error with guidance if --project is missing.
 *
 * @param projectFlag - The resolved project name/path, or undefined
 * @param allFlag - Whether --all was passed (acceptable alternative to --project)
 */
export declare function requireProjectInMultiMode(projectFlag: string | undefined, allFlag: boolean): Promise<void>;
/**
 * Require --project or --all flag in multi-project mode.
 * For commands that default to single-project behavior.
 */
export declare function requireProjectOrAllInMultiMode(projectFlag: string | undefined, allFlag: boolean): Promise<void>;
//# sourceMappingURL=project-task-support.d.ts.map