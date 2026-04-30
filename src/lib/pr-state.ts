/**
 * PR State Service — fetch and summarize GitHub PR state for a task.
 *
 * Provides a unified view of the current PR state by:
 * 1. Determining the branch name for a task (from branch field or foreman/<seedId>)
 * 2. Fetching the PR state from GitHub via `gh pr view`
 * 3. Getting the current branch HEAD SHA
 * 4. Comparing to detect staleness (merged PR but branch head changed)
 *
 * @module src/lib/pr-state
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type PrStateStatus = "none" | "open" | "merged" | "closed" | "error";

export interface PrState {
  /** Current PR state: none (no PR), open, merged, closed, or error */
  status: PrStateStatus;
  /** GitHub PR URL if a PR exists, null otherwise */
  url: string | null;
  /** PR number if a PR exists, null otherwise */
  number: number | null;
  /** PR head SHA at the time of PR creation/merge */
  headSha: string | null;
  /** Current branch HEAD SHA (null if branch doesn't exist locally) */
  currentHeadSha: string | null;
  /** True if PR was merged but branch head has since changed (stale) */
  isStale: boolean;
  /** Error message if status is "error" */
  error: string | null;
  /** Human-readable summary suitable for display */
  summary: string;
}

export interface GetPrStateOptions {
  /** Project path for running git/gh commands */
  projectPath: string;
  /** Branch name to check (e.g., "foreman/task-abc123"). Defaults to "foreman/<seedId>" */
  branchName?: string;
  /** Seed/task ID. Used to construct default branch name if branchName not provided */
  seedId?: string;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function gh(args: string[], cwd: string): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  try {
    const { stdout, stderr } = await execFileAsync("gh", args, {
      cwd,
      maxBuffer: 10 * 1024 * 1024, // 10 MB
      timeout: 30_000,
    });
    return { stdout: stdout.trim(), stderr: stderr.trim(), exitCode: 0 };
  } catch (err: unknown) {
    const execErr = err as { code?: number; stderr?: string; stdout?: string };
    return {
      stdout: (execErr.stdout ?? "").trim(),
      stderr: (execErr.stderr ?? "").trim(),
      exitCode: execErr.code ?? 1,
    };
  }
}

async function git(args: string[], cwd: string): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  try {
    const { stdout, stderr } = await execFileAsync("git", args, {
      cwd,
      maxBuffer: 10 * 1024 * 1024,
      timeout: 10_000,
    });
    return { stdout: stdout.trim(), stderr: stderr.trim(), exitCode: 0 };
  } catch (err: unknown) {
    const execErr = err as { code?: number; stderr?: string; stdout?: string };
    return {
      stdout: (execErr.stdout ?? "").trim(),
      stderr: (execErr.stderr ?? "").trim(),
      exitCode: execErr.code ?? 1,
    };
  }
}

/**
 * Resolve the branch name for a task.
 * If branchName is provided, use it directly.
 * Otherwise, construct "foreman/<seedId>" if seedId is provided.
 * Falls back to "foreman/<seedId>" if neither is provided.
 */
function resolveBranchName(branchName: string | undefined, seedId: string | undefined): string {
  if (branchName) return branchName;
  if (seedId) return `foreman/${seedId}`;
  throw new Error("Either branchName or seedId must be provided");
}

// ---------------------------------------------------------------------------
// Main API
// ---------------------------------------------------------------------------

/**
 * Get the current GitHub PR state for a branch.
 *
 * This function:
 * 1. Resolves the branch name
 * 2. Fetches PR info from GitHub via `gh pr view --json`
 * 3. Gets the current branch HEAD SHA via `git rev-parse`
 * 4. Determines if the PR is stale (merged but head changed)
 *
 * @param options - Options including projectPath, branchName, and seedId
 * @returns PrState object with current PR state and staleness info
 */
export async function getPrState(options: GetPrStateOptions): Promise<PrState> {
  const { projectPath, branchName: providedBranchName, seedId } = options;

  let branchName: string;
  try {
    branchName = resolveBranchName(providedBranchName, seedId);
  } catch {
    return {
      status: "error",
      url: null,
      number: null,
      headSha: null,
      currentHeadSha: null,
      isStale: false,
      error: "Neither branchName nor seedId provided",
      summary: "—",
    };
  }

  // Step 1: Get current branch HEAD SHA
  const headResult = await git(["rev-parse", branchName], projectPath);
  const currentHeadSha = headResult.exitCode === 0 ? headResult.stdout : null;

  // Step 2: Get PR info from GitHub
  const prResult = await gh(
    ["pr", "view", branchName, "--json", "state,number,headRefOid,url,isMerged", "--jq", "."],
    projectPath,
  );

  if (prResult.exitCode !== 0) {
    // No PR exists for this branch
    if (prResult.stderr.includes("no pull request") || prResult.stderr.includes("could not find")) {
      return {
        status: "none",
        url: null,
        number: null,
        headSha: null,
        currentHeadSha,
        isStale: false,
        error: null,
        summary: currentHeadSha ? "no PR" : "no PR (branch deleted)",
      };
    }
    // Some other error (gh not installed, not authenticated, etc.)
    return {
      status: "error",
      url: null,
      number: null,
      headSha: null,
      currentHeadSha,
      isStale: false,
      error: prResult.stderr || "Failed to fetch PR state",
      summary: "?",
    };
  }

  // Parse PR JSON
  let prData: {
    state?: string;
    number?: number;
    headRefOid?: string;
    url?: string;
    isMerged?: boolean;
  };
  try {
    prData = JSON.parse(prResult.stdout) as typeof prData;
  } catch {
    return {
      status: "error",
      url: null,
      number: null,
      headSha: null,
      currentHeadSha,
      isStale: false,
      error: "Failed to parse PR response",
      summary: "?",
    };
  }

  const state = prData.state ?? "UNKNOWN";
  const headSha = prData.headRefOid ?? null;
  const url = prData.url ?? null;
  const number = prData.number ?? null;
  const isMerged = prData.isMerged ?? false;

  // Determine status
  let status: PrStateStatus;
  if (isMerged || state === "MERGED") {
    status = "merged";
  } else if (state === "OPEN") {
    status = "open";
  } else if (state === "CLOSED") {
    status = "closed";
  } else {
    status = "error";
  }

  // Check staleness: PR is stale if it was merged but branch head changed
  const isStale = status === "merged" && headSha !== null && currentHeadSha !== null && headSha !== currentHeadSha;

  // Generate human-readable summary
  let summary: string;
  if (status === "open") {
    summary = `open (#${number})`;
  } else if (status === "merged") {
    if (isStale) {
      summary = `merged (#${number}, stale)`;
    } else {
      summary = `merged (#${number})`;
    }
  } else if (status === "closed") {
    summary = `closed (#${number})`;
  } else {
    summary = "?";
  }

  return {
    status,
    url,
    number,
    headSha,
    currentHeadSha,
    isStale,
    error: null,
    summary,
  };
}

/**
 * Get PR states for multiple tasks efficiently.
 *
 * @param tasks - Array of task objects with id, branch, and seedId fields
 * @param projectPath - Project path for running git/gh commands
 * @returns Map of taskId -> PrState
 */
export async function getPrStatesForTasks(
  tasks: Array<{ id: string; branch?: string | null; run_id?: string | null }>,
  projectPath: string,
): Promise<Map<string, PrState>> {
  const results = new Map<string, PrState>();

  // Batch fetch: first get all PR states for foreman/* branches
  const foremanBranches = new Set<string>();

  // Collect all branch names we need to check
  const branchesToCheck: Array<{ taskId: string; branchName: string }> = [];

  for (const task of tasks) {
    const branchName = task.branch ?? `foreman/${task.id}`;
    branchesToCheck.push({ taskId: task.id, branchName });
    foremanBranches.add(branchName);
  }

  // Run git and gh commands in parallel for all branches
  const gitResults = new Map<string, string | null>();
  const prResults = new Map<string, { prData: GitHubPrData | null; error: string | null }>();

  // Batch git rev-parse
  await Promise.all(
    branchesToCheck.map(async ({ taskId, branchName }) => {
      const result = await git(["rev-parse", branchName], projectPath);
      gitResults.set(branchName, result.exitCode === 0 ? result.stdout : null);
    })
  );

  // Batch gh pr view
  await Promise.all(
    branchesToCheck.map(async ({ taskId, branchName }) => {
      const prResult = await gh(
        ["pr", "view", branchName, "--json", "state,number,headRefOid,url,isMerged", "--jq", "."],
        projectPath,
      );

      if (prResult.exitCode !== 0) {
        prResults.set(branchName, {
          prData: null,
          error: prResult.stderr.includes("no pull request") || prResult.stderr.includes("could not find")
            ? null // Not an error, just no PR
            : prResult.stderr,
        });
        return;
      }

      try {
        const parsed = JSON.parse(prResult.stdout) as GitHubPrData;
        prResults.set(branchName, { prData: parsed, error: null });
      } catch {
        prResults.set(branchName, { prData: null, error: "Failed to parse PR response" });
      }
    })
  );

  // Build results
  for (const task of tasks) {
    const branchName = task.branch ?? `foreman/${task.id}`;
    const currentHeadSha = gitResults.get(branchName) ?? null;
    const prResult = prResults.get(branchName);

    if (!prResult || !prResult.prData) {
      results.set(task.id, {
        status: prResult?.error ? "error" : "none",
        url: null,
        number: null,
        headSha: null,
        currentHeadSha,
        isStale: false,
        error: prResult?.error ?? null,
        summary: currentHeadSha ? "no PR" : "no PR (branch deleted)",
      });
      continue;
    }

    const { prData } = prResult;
    const state = prData.state ?? "UNKNOWN";
    const headSha = prData.headRefOid ?? null;
    const url = prData.url ?? null;
    const number = prData.number ?? null;
    const isMerged = prData.isMerged ?? false;

    let status: PrStateStatus;
    if (isMerged || state === "MERGED") {
      status = "merged";
    } else if (state === "OPEN") {
      status = "open";
    } else if (state === "CLOSED") {
      status = "closed";
    } else {
      status = "error";
    }

    const isStale = status === "merged" && headSha !== null && currentHeadSha !== null && headSha !== currentHeadSha;

    let summary: string;
    if (status === "open") {
      summary = `open (#${number})`;
    } else if (status === "merged") {
      summary = isStale ? `merged (#${number}, stale)` : `merged (#${number})`;
    } else if (status === "closed") {
      summary = `closed (#${number})`;
    } else {
      summary = "?";
    }

    results.set(task.id, {
      status,
      url,
      number,
      headSha,
      currentHeadSha,
      isStale,
      error: null,
      summary,
    });
  }

  return results;
}

/** GitHub PR data parsed from `gh pr view --json` */
interface GitHubPrData {
  state?: string;
  number?: number;
  headRefOid?: string;
  url?: string;
  isMerged?: boolean;
}
