export declare const LEGACY_PROJECT_PATH_WARNING = "`--project` with an absolute path is deprecated; use `--project-path` instead.";
export type ProjectTargetSource = "cwd" | "project-name" | "project-path" | "legacy-project-path";
export type ProjectTargetingErrorCode = "project-and-project-path-conflict" | "project-name-not-found" | "project-path-must-be-absolute" | "project-path-not-accessible";
export interface ProjectTargetResolution {
    projectPath: string;
    source: ProjectTargetSource;
    warning?: string;
}
export interface ProjectTargetOptions {
    project?: string;
    projectPath?: string;
    cwd?: string;
}
interface ProjectRegistryLike {
    resolve(nameOrPath: string): string;
}
export interface ProjectTargetingDeps {
    registry?: ProjectRegistryLike;
    cwd?: string;
    isAccessible?: (projectPath: string) => boolean;
    isAbsolutePath?: (projectPath: string) => boolean;
    resolvePath?: (projectPath: string) => string;
}
export declare class ProjectTargetingError extends Error {
    readonly code: ProjectTargetingErrorCode;
    constructor(code: ProjectTargetingErrorCode, message: string);
}
export declare function resolveProjectTarget(opts: ProjectTargetOptions, deps?: ProjectTargetingDeps): ProjectTargetResolution;
export {};
//# sourceMappingURL=project-targeting.d.ts.map