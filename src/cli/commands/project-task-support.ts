import chalk from "chalk";
import { createHash, randomUUID } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { resolveProjectPath } from "../../lib/project-path.js";
import { ElixirServerClient, type ElixirProject } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { ProjectRegistry } from "../../lib/project-registry.js";
import { initPool, isPoolInitialised } from "../../lib/db/pool-manager.js";

export interface RegisteredProjectSummary {
  id: string;
  name: string;
  path: string;
  githubUrl?: string;
  defaultBranch?: string;
  status?: string;
}

function summaryFromElixirProject(project: ElixirProject): RegisteredProjectSummary {
  const path = resolve(project.path);
  const id = project.project_id ?? project.id ?? basename(path);
  const configuredName = typeof project.config?.name === "string" ? project.config.name : undefined;
  return {
    id,
    name: project.name ?? configuredName ?? basename(path),
    path,
    defaultBranch: project.default_branch,
    status: project.status,
  };
}

function elixirClient(): Promise<ElixirServerClient> {
  if (process.env.FOREMAN_SERVER_URL) {
    return Promise.resolve(new ElixirServerClient(process.env.FOREMAN_SERVER_URL, process.env.FOREMAN_WORKER_EVENT_TOKEN ?? process.env.FOREMAN_SERVER_AUTH_TOKEN));
  }

  const manager = new ElixirServerManager();
  return manager.ensureRunning().then((status) => new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN));
}

export async function listRegisteredProjects(opts: { includeArchived?: boolean } = {}): Promise<RegisteredProjectSummary[]> {
  const client = await elixirClient();
  const projects = await client.listProjects();
  return projects
    .map(summaryFromElixirProject)
    .filter((project) => opts.includeArchived || (project.status ?? "active") !== "archived");
}

function defaultElixirProjectId(projectPath: string, name: string): string {
  const normalizedName = name
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "") || "project";
  const suffix = createHash("sha1").update(resolve(projectPath)).digest("hex").slice(0, 5);
  return `${normalizedName}-${suffix}`;
}

export async function registerProjectInElixir(
  projectPath: string,
  opts: { name?: string; defaultBranch?: string; status?: "active" | "paused" | "archived" } = {},
): Promise<RegisteredProjectSummary> {
  const resolvedPath = resolve(projectPath);
  const registry = new ProjectRegistry();
  const records = await registry.list().catch(() => []);
  const existing = records.find((record) => resolve(record.path) === resolvedPath);

  const name = opts.name ?? existing?.name ?? basename(resolvedPath);
  const projectId = existing?.id ?? defaultElixirProjectId(resolvedPath, name);
  const defaultBranch = opts.defaultBranch ?? existing?.defaultBranch ?? "main";
  const projectStatus = opts.status ?? existing?.status ?? "active";

  const client = await elixirClient();
  const response = await client.sendCommand({
    command_id: `project-register-${projectId}-${randomUUID()}`,
    command_type: "project.register",
    payload: {
      project_id: projectId,
      path: resolvedPath,
      status: projectStatus,
      default_branch: defaultBranch,
      config: { name },
      health: { ok: true },
    },
  });

  if (!response.ok) {
    throw new Error(response.error.message);
  }

  return {
    id: projectId,
    name,
    path: resolvedPath,
    defaultBranch,
    status: projectStatus,
  };
}

export async function archiveProjectInElixir(projectId: string, opts: { force?: boolean } = {}): Promise<void> {
  const client = await elixirClient();
  const response = await client.sendCommand({
    command_id: `project-archive-${projectId}-${randomUUID()}`,
    command_type: "project.archive",
    payload: {
      project_id: projectId,
      force: Boolean(opts.force),
    },
  });

  if (!response.ok) {
    throw new Error(response.error.message);
  }
}

export async function updateProjectInElixir(
  projectId: string,
  updates: { name?: string; status?: string; defaultBranch?: string },
): Promise<void> {
  const payload: Record<string, unknown> = { project_id: projectId };
  if (updates.name) payload.name = updates.name;
  if (updates.status) payload.status = updates.status;
  if (updates.defaultBranch) payload.default_branch = updates.defaultBranch;

  const client = await elixirClient();
  const response = await client.sendCommand({
    command_id: `project-update-${projectId}-${randomUUID()}`,
    command_type: "project.update",
    payload,
  });

  if (!response.ok) {
    throw new Error(response.error.message);
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
    } catch {
      // Fall back to local resolver when the daemon is unavailable or the project
      // is not managed by the daemon-backed registry.
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
