import { loadProjectConfig, type BranchPolicyConfig, type ProjectConfig } from "./project-config.js";
import type { VcsBackend } from "./vcs/interface.js";

export interface ResolvedBranchPolicy {
  defaultBranch: string;
  integrationBranch: string;
  requireValidation: boolean;
  autoPromote: boolean;
}

function normalizeBranchName(branch: string | undefined): string | undefined {
  const normalized = branch?.trim();
  return normalized && normalized.length > 0 ? normalized : undefined;
}

export async function resolveProjectBranchPolicy(
  projectPath: string,
  vcs: Pick<VcsBackend, "detectDefaultBranch">,
  projectConfig?: ProjectConfig | null,
): Promise<ResolvedBranchPolicy> {
  const config = projectConfig ?? loadProjectConfig(projectPath);
  const branchPolicy: BranchPolicyConfig | undefined = config?.branchPolicy;

  const defaultBranch = normalizeBranchName(branchPolicy?.defaultBranch)
    ?? normalizeBranchName(await vcs.detectDefaultBranch(projectPath))
    ?? "main";
  const integrationBranch = normalizeBranchName(branchPolicy?.integrationBranch) ?? defaultBranch;

  return {
    defaultBranch,
    integrationBranch,
    requireValidation: branchPolicy?.requireValidation ?? integrationBranch !== defaultBranch,
    autoPromote: branchPolicy?.autoPromote ?? false,
  };
}
