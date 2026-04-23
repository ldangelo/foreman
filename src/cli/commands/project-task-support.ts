import chalk from "chalk";
import { resolveProjectPath } from "../../lib/project-path.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { ProjectRegistry } from "../../lib/project-registry.js";
import { createTrpcClient } from "../../lib/trpc-client.js";

export interface RegisteredProjectSummary {
  id: string;
  name: string;
  path: string;
}

export async function listRegisteredProjects(): Promise<RegisteredProjectSummary[]> {
  try {
    const client = createTrpcClient();
    const projects = await client.projects.list() as Array<{ id: string; name: string; path: string }>;
    return projects.map((project) => ({
      id: project.id,
      name: project.name,
      path: project.path,
    }));
  } catch {
    const registry = new ProjectRegistry();
    const records = await registry.list();
    return records.map((record) => ({
      id: record.id,
      name: record.name,
      path: record.path,
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
  return vcs.getRepoRoot(cwd);
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
