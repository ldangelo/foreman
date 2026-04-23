import chalk from "chalk";
import { resolveProjectPath } from "../../lib/project-path.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { ProjectRegistry } from "../../lib/project-registry.js";
import { createTrpcClient } from "../../lib/trpc-client.js";

export interface RegisteredProjectSummary {
  id: string;
  name: string;
  path: string;
  githubUrl?: string;
}

export async function listRegisteredProjects(): Promise<RegisteredProjectSummary[]> {
  try {
    const client = createTrpcClient();
    const projects = await client.projects.list() as Array<{
      id: string;
      name: string;
      path: string;
      githubUrl?: string;
    }>;
    return projects.map((project) => ({
      id: project.id,
      name: project.name,
      path: project.path,
      githubUrl: project.githubUrl,
    }));
  } catch {
    const registry = new ProjectRegistry();
    const records = await registry.list();
    return records.map((record) => ({
      id: record.id,
      name: record.name,
      path: record.path,
      githubUrl: record.githubUrl,
    }));
  }
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
    const projectsByUrl = new Map(
      projects
        .filter((p): p is RegisteredProjectSummary & { githubUrl: string } =>
          Boolean(p.githubUrl),
        )
        .map((p) => [p.githubUrl.replace(/\.git$/, ""), p]),
    );
    if (projectsByUrl.size > 0) {
      try {
        const rawUrl = await vcs.getRemoteUrl(repoRoot, "origin");
        if (rawUrl) {
          const normalizedUrl = rawUrl.trim().replace(/\.git$/, "");
          // Normalize SSH (git@github.com:owner/repo) to HTTPS (https://github.com/owner/repo)
          const remoteUrl = normalizedUrl.replace(/^git@([^:]+):/, "https://$1/");
          const registered = projectsByUrl.get(remoteUrl);
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
