import { accessSync, constants as fsConstants } from "node:fs";
import { isAbsolute, resolve } from "node:path";
import { ProjectNotFoundError, ProjectRegistry } from "./project-registry.js";

export const LEGACY_PROJECT_PATH_WARNING =
  "`--project` with an absolute path is deprecated; use `--project-path` instead.";

export type ProjectTargetSource =
  | "cwd"
  | "project-name"
  | "project-path"
  | "legacy-project-path";

export type ProjectTargetingErrorCode =
  | "project-and-project-path-conflict"
  | "project-name-not-found"
  | "project-path-must-be-absolute"
  | "project-path-not-accessible";

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

export class ProjectTargetingError extends Error {
  constructor(
    public readonly code: ProjectTargetingErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "ProjectTargetingError";
  }
}

function defaultIsAccessible(projectPath: string): boolean {
  try {
    accessSync(projectPath, fsConstants.R_OK);
    return true;
  } catch {
    return false;
  }
}

function normalizeOption(value?: string): string | undefined {
  if (value === undefined) {
    return undefined;
  }

  return value.trim() === "" ? undefined : value;
}

function assertAccessible(
  projectPath: string,
  message: string,
  isAccessible: (projectPath: string) => boolean,
): void {
  if (!isAccessible(projectPath)) {
    throw new ProjectTargetingError("project-path-not-accessible", message);
  }
}

export function resolveProjectTarget(
  opts: ProjectTargetOptions,
  deps: ProjectTargetingDeps = {},
): ProjectTargetResolution {
  const project = normalizeOption(opts.project);
  const projectPath = normalizeOption(opts.projectPath);
  const resolvePath = deps.resolvePath ?? resolve;
  const isAbsolutePath = deps.isAbsolutePath ?? isAbsolute;
  const isAccessible = deps.isAccessible ?? defaultIsAccessible;
  const cwd = resolvePath(deps.cwd ?? opts.cwd ?? process.cwd());

  if (project !== undefined && projectPath !== undefined) {
    throw new ProjectTargetingError(
      "project-and-project-path-conflict",
      "Specify either `--project <name>` or `--project-path <absolute-path>`, not both.",
    );
  }

  if (projectPath !== undefined) {
    if (!isAbsolutePath(projectPath)) {
      throw new ProjectTargetingError(
        "project-path-must-be-absolute",
        "`--project-path` must be an absolute path.",
      );
    }

    const resolvedProjectPath = resolvePath(projectPath);
    assertAccessible(
      resolvedProjectPath,
      `Project path '${resolvedProjectPath}' does not exist or is not accessible.`,
      isAccessible,
    );

    return {
      projectPath: resolvedProjectPath,
      source: "project-path",
    };
  }

  if (project === undefined) {
    assertAccessible(
      cwd,
      `Current working directory '${cwd}' does not exist or is not accessible.`,
      isAccessible,
    );

    return {
      projectPath: cwd,
      source: "cwd",
    };
  }

  const registry = deps.registry ?? new ProjectRegistry();

  if (isAbsolutePath(project)) {
    const resolvedProjectPath = (() => {
      try {
        return registry.resolve(project);
      } catch (error) {
        if (error instanceof ProjectNotFoundError) {
          return resolvePath(project);
        }
        throw error;
      }
    })();

    assertAccessible(
      resolvedProjectPath,
      `Project path '${resolvedProjectPath}' does not exist or is not accessible.`,
      isAccessible,
    );

    return {
      projectPath: resolvedProjectPath,
      source: "legacy-project-path",
      warning: LEGACY_PROJECT_PATH_WARNING,
    };
  }

  try {
    const resolvedProjectPath = registry.resolve(project);
    assertAccessible(
      resolvedProjectPath,
      `Registered project '${project}' points to '${resolvedProjectPath}', but that path does not exist or is not accessible.`,
      isAccessible,
    );

    return {
      projectPath: resolvedProjectPath,
      source: "project-name",
    };
  } catch (error) {
    if (error instanceof ProjectNotFoundError) {
      throw new ProjectTargetingError(
        "project-name-not-found",
        `Project '${project}' not found. Run 'foreman project list' to see registered projects.`,
      );
    }

    throw error;
  }
}
