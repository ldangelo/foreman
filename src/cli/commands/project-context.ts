import { resolve } from "node:path";
import {
  ensureCliPostgresPool,
  listRegisteredProjects,
  resolveRepoRootProjectPath,
  type RegisteredProjectSummary,
} from "./project-task-support.js";

/**
 * Consolidated project-resolution helpers for CLI commands.
 *
 * These replace the per-command copies of the "resolve project path → find the
 * registered project → initialise the CLI Postgres pool" sequence that was
 * duplicated across reset, retry, stop, purge-logs, purge-zombie-runs,
 * sentinel, worktree, and task commands. Per-command differences (path
 * normalization, id/name matching for --project, pool initialisation) are
 * preserved via options.
 */

export interface FindRegisteredProjectOptions {
  /**
   * Compare registry paths using node:path resolve() normalization
   * (retry.ts / task.ts behavior). Default: exact string equality.
   */
  normalizePaths?: boolean;
  /**
   * Initialise the CLI Postgres pool when a registered project is found.
   * Default: true.
   */
  initPool?: boolean;
}

/** Find the registered project whose path matches `projectPath`. */
export async function findRegisteredProjectByPath(
  projectPath: string,
  options: FindRegisteredProjectOptions = {},
): Promise<RegisteredProjectSummary | undefined> {
  const projects = await listRegisteredProjects();
  const registered = options.normalizePaths
    ? projects.find((project) => resolve(project.path) === resolve(projectPath))
    : projects.find((project) => project.path === projectPath);
  if (registered && (options.initPool ?? true)) {
    ensureCliPostgresPool(projectPath);
  }
  return registered;
}

export interface ProjectContext {
  projectPath: string;
  registered: RegisteredProjectSummary | undefined;
}

export interface ResolveProjectContextOptions extends FindRegisteredProjectOptions {
  /**
   * When `opts.project` is provided, match the registered project by id or
   * name instead of by resolved path (reset.ts behavior).
   */
  matchProjectFlagByIdOrName?: boolean;
}

/**
 * Resolve the project path (repo root / --project / --project-path) and look
 * up the matching registered project, initialising the CLI Postgres pool when
 * one is found.
 */
export async function resolveProjectContext(
  opts: { project?: string; projectPath?: string } = {},
  options: ResolveProjectContextOptions = {},
): Promise<ProjectContext> {
  const projectPath = await resolveRepoRootProjectPath(opts);

  if (options.matchProjectFlagByIdOrName && opts.project) {
    const projects = await listRegisteredProjects();
    const registered = projects.find(
      (project) => project.id === opts.project || project.name === opts.project,
    );
    if (registered && (options.initPool ?? true)) {
      ensureCliPostgresPool(projectPath);
    }
    return { projectPath, registered };
  }

  const registered = await findRegisteredProjectByPath(projectPath, options);
  return { projectPath, registered };
}

/**
 * Sentinel-style resolution: a --project flag matches by id or name only
 * (never resolving a path, so unknown names return null instead of exiting);
 * without a flag, the current repo root must match a registered project.
 *
 * Never initialises the Postgres pool — callers decide.
 */
export async function findRegisteredProjectByFlagOrCwd(
  projectFlag?: string,
): Promise<RegisteredProjectSummary | null> {
  if (projectFlag) {
    const projects = await listRegisteredProjects();
    return (
      projects.find((project) => project.id === projectFlag || project.name === projectFlag) ??
      null
    );
  }

  const projectPath = await resolveRepoRootProjectPath({});
  const projects = await listRegisteredProjects();
  return projects.find((project) => project.path === projectPath) ?? null;
}
