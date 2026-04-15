import { resolveProjectPath } from "../../lib/project-path.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";

export function resolveProjectPathFromOptions(
  opts: { project?: string; projectPath?: string },
): string {
  return resolveProjectPath(opts);
}

export function resolveProjectPathFromOption(project?: string): string {
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
