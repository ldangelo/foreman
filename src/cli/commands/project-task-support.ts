import { resolveProjectPath } from "../../lib/project-path.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";

export function resolveProjectPathFromOptions(
  opts: { project?: string; projectPath?: string },
  jsonOutput = false,
 ): string {
  return resolveProjectPath(opts, jsonOutput);
}

export function resolveProjectPathFromOption(project?: string, jsonOutput = false): string {
  return resolveProjectPathFromOptions({ project }, jsonOutput);
}

export async function resolveRepoRootProjectPath(
  opts: { project?: string; projectPath?: string },
  jsonOutput = false,
 ): Promise<string> {
  if (opts.project || opts.projectPath) {
    return resolveProjectPathFromOptions(opts, jsonOutput);
  }

  const cwd = process.cwd();
  const vcs = await VcsBackendFactory.create({ backend: "auto" }, cwd);
  return vcs.getRepoRoot(cwd);
}
