import chalk from "chalk";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { resolveProjectPath } from "../../lib/project-path.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { ProjectRegistry } from "../../lib/project-registry.js";
import { createTrpcClient } from "../../lib/trpc-client.js";
import { initPool, isPoolInitialised } from "../../lib/db/pool-manager.js";
import { foremanBackendMode } from "../../lib/backend-mode.js";
import { ElixirServerClient } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";

export interface RegisteredProjectSummary {
  id: string;
  name: string;
  path: string;
  githubUrl?: string;
  defaultBranch?: string;
}

function legacyProjectFallbackAllowed(): boolean {
  return ["1", "true", "yes"].includes((process.env.FOREMAN_PROJECT_LEGACY_FALLBACK ?? "").toLowerCase());
}

export async function listRegisteredProjects(): Promise<RegisteredProjectSummary[]> {
  if (foremanBackendMode() === "elixir") {
    try {
      const manager = new ElixirServerManager();
      const status = await manager.ensureRunning();
      const client = new ElixirServerClient(status.url, manager.authToken);
      const projects = await client.listProjects();
      return projects.map((project) => ({
        id: String(project.project_id ?? project.id ?? project.name ?? project.path),
        name: String(project.name ?? project.project_id ?? project.id ?? project.path),
        path: project.path,
        githubUrl: project.github_url,
        defaultBranch: project.default_branch,
      }));
    } catch (err) {
      if (!legacyProjectFallbackAllowed()) {
        const message = err instanceof Error ? err.message : String(err);
        throw new Error(`Elixir project registry unavailable; refusing legacy daemon/local fallback in default Elixir mode. Set FOREMAN_BACKEND=node for legacy project registry access, or FOREMAN_PROJECT_LEGACY_FALLBACK=true to opt into mixed-cutover fallback. Cause: ${message}`);
      }
    }
  }

  try {
    const client = createTrpcClient();
    const projects = await client.projects.list() as Array<{
      id: string;
      name: string;
      path: string;
      githubUrl?: string;
      defaultBranch?: string;
    }>;
    return projects.map((project) => ({
      id: project.id,
      name: project.name,
      path: project.path,
      githubUrl: project.githubUrl,
      defaultBranch: project.defaultBranch,
    }));
  } catch {
    const registry = new ProjectRegistry();
    const records = await registry.list();
    return records.map((record) => ({
      id: record.id,
      name: record.name,
      path: record.path,
      githubUrl: record.githubUrl,
      defaultBranch: record.defaultBranch,
    }));
  }
}

export function ensureCliPostgresPool(projectPath: string): void {
  if (isPoolInitialised()) return;
  const dotEnvPath = join(projectPath, ".env");
  const databaseUrl = existsSync(dotEnvPath)
    ? readFileSync(dotEnvPath, "utf8").match(/^\s*DATABASE_URL=(.+)\s*$/m)?.[1]?.trim().replace(/^['"]|['"]$/g, "")
    : undefined;
  initPool(databaseUrl ? { databaseUrl } : undefined);
}

export async function resolveProjectPathFromOptions(
  opts: { project?: string; projectPath?: string },
): Promise<string> {
  if (opts.project && !opts.projectPath) {
    try {
      const projects = await listRegisteredProjects();
      const match = projects.find((project) => project.id === opts.project || project.name === opts.project);
      if (match?.path) {
        return match.path;
      }
      if (foremanBackendMode() === "elixir" && !legacyProjectFallbackAllowed()) {
        throw new Error(`Project '${opts.project}' not found in Elixir project registry; refusing legacy local fallback. Set FOREMAN_BACKEND=node for legacy project resolution, or FOREMAN_PROJECT_LEGACY_FALLBACK=true to opt into mixed-cutover fallback.`);
      }
    } catch (err) {
      if (foremanBackendMode() === "elixir" && !legacyProjectFallbackAllowed()) {
        const message = err instanceof Error ? err.message : String(err);
        throw new Error(`Elixir project registry unavailable while resolving --project; refusing legacy local fallback. Set FOREMAN_BACKEND=node for legacy project resolution, or FOREMAN_PROJECT_LEGACY_FALLBACK=true to opt into mixed-cutover fallback. Cause: ${message}`);
      }
      // Fall back to local resolver when the legacy daemon is unavailable or the
      // project is not managed by the daemon-backed registry.
    }
  }

  return resolveProjectPath(opts);
}

export async function resolveProjectPathFromOption(project?: string): Promise<string> {
  return resolveProjectPathFromOptions({ project });
}

export async function resolveRepoRootProjectPath(
  opts: { project?: string; projectPath?: string },
): Promise<string> {
  if (opts.project || opts.projectPath) {
    return resolveProjectPathFromOptions(opts);
  }

  const cwd = process.cwd();
  const vcs = await VcsBackendFactory.create({ backend: "auto" }, cwd);
  const repoRoot = await vcs.getRepoRoot(cwd);

  // Check if the cwd's git origin URL matches a registered project by GitHub URL.
  // This ensures commands like `foreman run` use the project's multi-project store
  // when run from within a registered project's repo.
  try {
    const projects = await listRegisteredProjects();
    const projectsByRemoteKey = new Map<string, RegisteredProjectSummary>();
    for (const project of projects) {
      if (!project.githubUrl) continue;
      const value = project.githubUrl.trim().replace(/\.git$/, "");
      projectsByRemoteKey.set(value, project);
      projectsByRemoteKey.set(value.replace(/^https:\/\/github\.com\//, ""), project);
    }
    if (projectsByRemoteKey.size > 0) {
      try {
        const rawUrl = await vcs.getRemoteUrl(repoRoot, "origin");
        if (rawUrl) {
          const normalizedUrl = rawUrl.trim().replace(/\.git$/, "");
          const remoteUrl = normalizedUrl.replace(/^git@([^:]+):/, "https://$1/");
          const remoteKey = remoteUrl.replace(/^https:\/\/github\.com\//, "");
          const registered = projectsByRemoteKey.get(remoteUrl) ?? projectsByRemoteKey.get(remoteKey);
          if (registered) {
            return registered.path;
          }
        }
      } catch {
        // VCS unavailable or no origin remote — fall through
      }
    }
  } catch {
    // Registry unavailable — fall through to repo root
  }

  return repoRoot;
}

// ── Multi-project mode detection (TRD-041/042) ───────────────────────────────

/**
 * Detect whether the project registry has 2+ projects (multi-project mode).
 * In multi-project mode, commands should require --project flag.
 */
export async function isMultiProjectMode(): Promise<boolean> {
  try {
    const records = await listRegisteredProjects();
    return records.length >= 2;
  } catch {
    return false;
  }
}

/**
 * Require --project flag in multi-project mode.
 * Throws an error with guidance if --project is missing.
 *
 * @param projectFlag - The resolved project name/path, or undefined
 * @param allFlag - Whether --all was passed (acceptable alternative to --project)
 */
export async function requireProjectInMultiMode(
  projectFlag: string | undefined,
  allFlag: boolean,
): Promise<void> {
  if (projectFlag || allFlag) return;

  const multiMode = await isMultiProjectMode();
  if (!multiMode) return;

  console.error(
    chalk.red(
      "Error: Multiple projects registered. Please specify --project <name> or use --all.\n" +
      "  foreman inbox --project <name>\n" +
      "  foreman inbox --all\n\n" +
      "Projects: foreman project list"
    )
  );
  process.exit(1);
}

/**
 * Require --project or --all flag in multi-project mode.
 * For commands that default to single-project behavior.
 */
export async function requireProjectOrAllInMultiMode(
  projectFlag: string | undefined,
  allFlag: boolean,
): Promise<void> {
  if (projectFlag || allFlag) return;
  await requireProjectInMultiMode(projectFlag, allFlag);
}
