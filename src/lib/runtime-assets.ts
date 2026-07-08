import { findMissingPrompts, findStalePrompts } from "./prompt-loader.js";
import { loadProjectConfig, type ProjectConfig } from "./project-config.js";
import {
  ensureBundledWorkflowsInstalled,
  findStaleWorkflows,
} from "./workflow-loader.js";

/**
 * Validate runtime assets that are copied into Foreman's runtime home before
 * any task dispatch or worker phase execution can depend on them.
 *
 * Missing bundled workflows are installed opportunistically so newly added
 * defaults do not strand existing installs. Stale prompts/workflows still block
 * dispatch because they mean the runtime copy can render obsolete instructions.
 */
export function collectRuntimeAssetIssues(
  projectPath: string,
  projectCfg?: ProjectConfig | null,
): string[] {
  const issues: string[] = [];

  try {
    if (projectCfg === undefined) {
      loadProjectConfig(projectPath);
    }
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    issues.push(`project config invalid: ${msg}`);
    return issues;
  }

  const missingPrompts = findMissingPrompts(projectPath);
  const stalePrompts = findStalePrompts(projectPath);
  // Auto-install any missing bundled workflows (e.g. newly added bundled
  // workflows like quick.yaml on existing installs) instead of blocking
  // dispatch. Only workflows still missing after the install attempt are
  // reported as preflight issues.
  const missingWorkflows = ensureBundledWorkflowsInstalled(projectPath);
  const staleWorkflows = findStaleWorkflows(projectPath);

  if (missingPrompts.length > 0) {
    issues.push(`missing prompts: ${missingPrompts.join(", ")}`);
  }
  if (stalePrompts.length > 0) {
    issues.push(`stale prompts: ${stalePrompts.join(", ")}`);
  }
  if (missingWorkflows.length > 0) {
    issues.push(`missing workflows: ${missingWorkflows.map((name) => `${name}.yaml`).join(", ")}`);
  }
  if (staleWorkflows.length > 0) {
    issues.push(`stale workflows: ${staleWorkflows.map((name) => `${name}.yaml`).join(", ")}`);
  }

  return issues;
}

export function runtimeAssetIssueMessage(issues: string[]): string {
  return [
    "Foreman runtime assets are out of date.",
    ...issues.map((issue) => `  - ${issue}`),
    "Run 'foreman doctor --fix' (or reinstall prompts/workflows) before dispatching agents.",
  ].join("\n");
}
