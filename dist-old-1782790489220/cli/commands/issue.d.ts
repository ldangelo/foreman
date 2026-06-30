/**
 * `foreman issue` CLI commands — GitHub Issues integration.
 *
 * Sub-commands:
 *   foreman issue view --repo owner/repo --issue 142       View a GitHub issue
 *   foreman issue import --repo owner/repo --issue 142     Import a GitHub issue as a task
 *   foreman issue import --repo owner/repo --label bug     Bulk import by label
 *   foreman issue list --repo owner/repo                  List issues for a repo
 *   foreman issue configure --repo owner/repo             Configure a repo for sync
 *
 * TRD: TRD-2026-012 (GitHub Issues Integration), TRD-010, TRD-011
 */
import { Command } from "commander";
import { GhCli, type GitHubLabelDefinition } from "../../lib/gh-cli.js";
import { type GithubRepoRow, type UpsertGithubRepoInput } from "../../lib/db/postgres-adapter.js";
export declare const REQUIRED_FOREMAN_GITHUB_LABELS: GitHubLabelDefinition[];
export declare function ensureRequiredGithubLabels(gh: Pick<GhCli, "ensureLabels">, owner: string, repo: string): Promise<import("../../lib/gh-cli.js").EnsureLabelsResult>;
export declare function buildGithubRepoConfigInput(projectId: string, owner: string, repo: string, opts: {
    autoImport?: boolean;
    disableAutoImport?: boolean;
    syncStrategy?: string;
    label?: string | string[];
}, existing?: GithubRepoRow | null): UpsertGithubRepoInput;
export declare function mergeGithubRepoConfigInput(projectId: string, owner: string, repo: string, existing: GithubRepoRow | null | undefined, overrides: Partial<UpsertGithubRepoInput>): UpsertGithubRepoInput;
export declare const issueCommand: Command;
//# sourceMappingURL=issue.d.ts.map