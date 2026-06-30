import { resolve } from "node:path";
import { ensureCliPostgresPool, listRegisteredProjects, resolveRepoRootProjectPath, } from "./project-task-support.js";
/** Find the registered project whose path matches `projectPath`. */
export async function findRegisteredProjectByPath(projectPath, options = {}) {
    const projects = await listRegisteredProjects();
    const registered = options.normalizePaths
        ? projects.find((project) => resolve(project.path) === resolve(projectPath))
        : projects.find((project) => project.path === projectPath);
    if (registered && (options.initPool ?? true)) {
        ensureCliPostgresPool(projectPath);
    }
    return registered;
}
/**
 * Resolve the project path (repo root / --project / --project-path) and look
 * up the matching registered project, initialising the CLI Postgres pool when
 * one is found.
 */
export async function resolveProjectContext(opts = {}, options = {}) {
    const projectPath = await resolveRepoRootProjectPath(opts);
    if (options.matchProjectFlagByIdOrName && opts.project) {
        const projects = await listRegisteredProjects();
        const registered = projects.find((project) => project.id === opts.project || project.name === opts.project);
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
export async function findRegisteredProjectByFlagOrCwd(projectFlag) {
    if (projectFlag) {
        const projects = await listRegisteredProjects();
        return (projects.find((project) => project.id === projectFlag || project.name === projectFlag) ??
            null);
    }
    const projectPath = await resolveRepoRootProjectPath({});
    const projects = await listRegisteredProjects();
    return projects.find((project) => project.path === projectPath) ?? null;
}
//# sourceMappingURL=project-context.js.map