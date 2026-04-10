const FOREMAN_BRANCH_PREFIX = "foreman/";

/**
 * Centralized branch naming for Foreman's per-seed work.
 * Keep all production branch-name construction here so naming changes cut over coherently.
 */
export function getForemanBranchName(seedId: string): string {
  return `${FOREMAN_BRANCH_PREFIX}${seedId}`;
}

export function isForemanBranchName(branchName: string): boolean {
  return branchName.startsWith(FOREMAN_BRANCH_PREFIX);
}

export function tryParseForemanSeedId(branchName: string): string | null {
  return isForemanBranchName(branchName)
    ? branchName.slice(FOREMAN_BRANCH_PREFIX.length)
    : null;
}
