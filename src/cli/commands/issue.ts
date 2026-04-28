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
import chalk from "chalk";
import { resolveProjectPathFromOptions } from "./project-task-support.js";
import {
  GhCli,
  GhRateLimitError,
  GhNotFoundError,
  type GitHubIssue,
} from "../../lib/gh-cli.js";
import {
  PostgresAdapter,
  type UpsertGithubRepoInput,
} from "../../lib/db/postgres-adapter.js";

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

const COL_NUMBER = 6;
const COL_STATE = 10;
const COL_TITLE = 60;

async function resolveProject(opts: {
  project?: string;
  projectPath?: string;
}): Promise<{ projectId: string; projectPath: string }> {
  const projectPath = await resolveProjectPathFromOptions(opts);
  const adapter = new PostgresAdapter();
  const projects = await adapter.listProjects();
  const project = projects.find((p) => p.path === projectPath);
  if (!project) {
    throw new Error(`Project not found for path '${projectPath}'. Run 'foreman init' first.`);
  }
  return { projectId: project.id, projectPath };
}

function formatIssueRow(issue: GitHubIssue): string {
  const num = String(issue.number).padEnd(COL_NUMBER);
  const state = issue.state.padEnd(COL_STATE);
  const title = issue.title.substring(0, COL_TITLE);
  const labels = issue.labels
    .map((l) => l.name)
    .filter((n) => n.startsWith("foreman:") || n === "bug" || n === "enhancement")
    .join(", ");
  return `  ${chalk.dim(num)} ${state} ${title} ${chalk.dim(labels ? `(${labels})` : "")}`;
}

function printIssue(issue: GitHubIssue): void {
  console.log(chalk.bold(`\n  #${issue.number}: ${issue.title}\n`));
  console.log(`  ${chalk.dim("State:")} ${chalk.cyan(issue.state)}`);
  console.log(`  ${chalk.dim("Author:")} ${chalk.cyan(issue.user.login)}`);
  console.log(`  ${chalk.dim("Created:")} ${chalk.cyan(issue.created_at)}`);
  console.log(`  ${chalk.dim("Updated:")} ${chalk.cyan(issue.updated_at)}`);
  if (issue.milestone) {
    console.log(`  ${chalk.dim("Milestone:")} ${chalk.cyan(issue.milestone.title)}`);
  }
  if (issue.assignees.length > 0) {
    console.log(
      `  ${chalk.dim("Assignees:")} ${chalk.cyan(issue.assignees.map((a) => a.login).join(", "))}`,
    );
  }
  if (issue.labels.length > 0) {
    console.log(
      `  ${chalk.dim("Labels:")} ${chalk.yellow(issue.labels.map((l) => l.name).join(", "))}`,
    );
  }
  if (issue.body) {
    console.log(chalk.dim("\n  Description:"));
    console.log(`  ${issue.body.split("\n").join("\n  ")}`);
  }
  console.log();
  console.log(`  ${chalk.dim("URL:")} ${chalk.blue.underline(issue.html_url)}`);
  console.log();
}

function parseRepoKey(repoKey: string): { owner: string; repo: string } {
  const parts = repoKey.trim().split("/");
  if (parts.length < 2) {
    throw new Error(
      `Invalid repo key '${repoKey}'. Expected format: owner/repo (e.g. myorg/myrepo)`,
    );
  }
  return { owner: parts[0]!, repo: parts[1]! };
}

function handleGhError(err: unknown, action: string): void {
  if (err instanceof GhNotFoundError) {
    console.error(chalk.red(`Error: GitHub resource not found (404)`));
    process.exit(1);
  }
  if (err instanceof GhRateLimitError) {
    console.error(
      chalk.red(`Error: GitHub API rate limit exceeded. Retry after ${(err as GhRateLimitError).retryAfter} seconds.`),
    );
    process.exit(1);
  }
  if (err instanceof Error) {
    console.error(chalk.red(`Error ${action}: ${err.message}`));
    process.exit(1);
  }
  console.error(chalk.red(`Error ${action}: Unknown error`));
  process.exit(1);
}

// ---------------------------------------------------------------------------
// foreman issue view
// ---------------------------------------------------------------------------

export const issueCommand = new Command("issue")
  .description("GitHub Issues integration commands")
  .addCommand(
    new Command("view")
      .description("View a GitHub issue")
      .requiredOption("--repo <owner/repo>", "Repository (owner/repo)")
      .requiredOption("--issue <number>", "Issue number", (val) => parseInt(val, 10))
      .option("--project <name>", "Foreman project name")
      .option("--project-path <path>", "Foreman project path")
      .action(
        async (
          opts: {
            repo: string;
            issue: number;
            project?: string;
            projectPath?: string;
          },
        ) => {
          await resolveProjectPathFromOptions(opts);
          const { owner, repo } = parseRepoKey(opts.repo);
          const gh = new GhCli();

          try {
            const issue = await gh.getIssue(owner, repo, opts.issue);
            printIssue(issue);
          } catch (err) {
            handleGhError(err, `viewing issue #${opts.issue}`);
          }
        },
      ),
  );

// ---------------------------------------------------------------------------
// foreman issue list
// ---------------------------------------------------------------------------

issueCommand.addCommand(
  new Command("list")
    .description("List GitHub issues for a repository")
    .requiredOption("--repo <owner/repo>", "Repository (owner/repo)")
    .option("--label <label>", "Filter by label")
    .option("--state <open|closed|all>", "Filter by state", "open")
    .option("--limit <n>", "Maximum number of issues", "50")
    .option("--project <name>", "Foreman project name")
    .option("--project-path <path>", "Foreman project path")
    .action(
      async (
        opts: {
          repo: string;
          label?: string;
          state?: string;
          limit?: string;
          project?: string;
          projectPath?: string;
        },
      ) => {
        await resolveProjectPathFromOptions(opts);
        const { owner, repo } = parseRepoKey(opts.repo);
        const gh = new GhCli();
        const limit = parseInt(opts.limit ?? "50", 10);

        try {
          const issues = await gh.listIssues(owner, repo, {
            labels: opts.label,
            state: opts.state as "open" | "closed" | "all",
          });
          const displayed = issues.slice(0, limit);
          console.log(
            chalk.bold(
              `\n  ${owner}/${repo} — ${displayed.length} issue${displayed.length !== 1 ? "s" : ""}\n`,
            ),
          );
          console.log(
            `  ${chalk.dim("Number".padEnd(COL_NUMBER))} ${chalk.dim("State".padEnd(COL_STATE))} Title`,
          );
          console.log(`  ${chalk.dim("-".repeat(COL_NUMBER + COL_STATE + COL_TITLE))}`);
          for (const issue of displayed) {
            console.log(formatIssueRow(issue));
          }
          console.log();
          if (issues.length > limit) {
            console.log(chalk.dim(`  Showing ${limit} of ${issues.length} issues. Use --limit to see more.`));
          }
        } catch (err) {
          handleGhError(err, "listing issues");
        }
      },
    ),
);

// ---------------------------------------------------------------------------
// foreman issue configure
// ---------------------------------------------------------------------------

issueCommand.addCommand(
  new Command("configure")
    .description("Configure a GitHub repository for sync")
    .requiredOption("--repo <owner/repo>", "Repository (owner/repo)")
    .option("--auto-import", "Enable auto-import for new issues", false)
    .option("--sync-strategy <strategy>", "Sync strategy", "github-wins")
    .option("--label <label>", "Default label to apply (can be repeated)", undefined)
    .option("--project <name>", "Foreman project name")
    .option("--project-path <path>", "Foreman project path")
    .action(
      async (
        opts: {
          repo: string;
          autoImport?: boolean;
          syncStrategy?: string;
          label?: string | string[];
          project?: string;
          projectPath?: string;
        },
      ) => {
        const { projectId } = await resolveProject(opts);
        const { owner, repo } = parseRepoKey(opts.repo);
        const adapter = new PostgresAdapter();

        const input: UpsertGithubRepoInput = {
          projectId,
          owner,
          repo,
          autoImport: opts.autoImport,
          syncStrategy: opts.syncStrategy as UpsertGithubRepoInput["syncStrategy"],
          defaultLabels: opts.label ? (Array.isArray(opts.label) ? opts.label : [opts.label]) : [],
        };

        try {
          const row = await adapter.upsertGithubRepo(input);
          console.log(
            chalk.green(`\n  Configured ${owner}/${repo} for project ${projectId}\n`),
          );
          console.log(`  ${chalk.dim("Sync strategy:")} ${chalk.cyan(row.sync_strategy)}`);
          console.log(`  ${chalk.dim("Auto-import:")} ${chalk.cyan(String(row.auto_import))}`);
          console.log(
            `  ${chalk.dim("Default labels:")} ${chalk.yellow(row.default_labels.join(", ") || "(none)")}`,
          );
          console.log();
        } catch (err) {
          console.error(chalk.red(`Error configuring repo: ${err instanceof Error ? err.message : String(err)}`));
          process.exit(1);
        }
      },
    ),
);

// ---------------------------------------------------------------------------
// foreman issue import (TRD-011)
// ---------------------------------------------------------------------------

issueCommand.addCommand(
  new Command("import")
    .description("Import GitHub issue(s) as Foreman tasks")
    .requiredOption("--repo <owner/repo>", "Repository (owner/repo)")
    .option("--issue <number>", "Import a single issue by number", (val) => parseInt(val, 10))
    .option("--label <label>", "Import all open issues with this label")
    .option("--milestone <title>", "Import all open issues in this milestone")
    .option("--assignee <username>", "Import all open issues assigned to this user")
    .option("--state <open|closed|all>", "Filter by state", "open")
    .option("--dry-run", "Preview what would be imported without creating tasks")
    .option("--sync", "Enable bi-directional sync for imported tasks")
    .option("--project <name>", "Foreman project name")
    .option("--project-path <path>", "Foreman project path")
    .action(
      async (
        opts: {
          repo: string;
          issue?: number;
          label?: string;
          milestone?: string;
          assignee?: string;
          state?: string;
          dryRun?: boolean;
          sync?: boolean;
          project?: string;
          projectPath?: string;
        },
      ) => {
        const { projectId } = await resolveProject(opts);
        const { owner, repo } = parseRepoKey(opts.repo);
        const gh = new GhCli();
        const adapter = new PostgresAdapter();

        // Upsert the repo config if it doesn't exist yet
        let repoConfig = await adapter.getGithubRepo(projectId, owner, repo);
        if (!repoConfig) {
          repoConfig = await adapter.upsertGithubRepo({ projectId, owner, repo });
        }

        try {
          // Determine which issues to import
          if (opts.issue) {
            // Single issue import
            const issue = await gh.getIssue(owner, repo, opts.issue);
            const imported = await importIssueAsTask(adapter, gh, projectId, issue, owner, repo, {
              dryRun: opts.dryRun ?? false,
              sync: opts.sync ?? false,
              repoConfig,
            });
            if (!opts.dryRun) {
              console.log(chalk.green(`  ✓ Imported #${issue.number} as task ${imported.taskId}`));
            }
          } else {
            // Bulk import
            const filterCount = [opts.label, opts.milestone, opts.assignee].filter(Boolean)
              .length;
            if (filterCount === 0) {
              console.error(
                chalk.red("Error: Specify --issue for single import, or --label/--milestone/--assignee for bulk import."),
              );
              process.exit(1);
            }

            const issues = await gh.listIssues(owner, repo, {
              labels: opts.label,
              milestone: opts.milestone,
              assignee: opts.assignee,
              state: (opts.state ?? "open") as "open" | "closed" | "all",
            });

            console.log(
              chalk.bold(`\n  ${owner}/${repo} — ${issues.length} issues to import\n`),
            );

            if (opts.dryRun) {
              console.log(chalk.dim("  [Dry-run mode — no tasks will be created]\n"));
              for (const issue of issues.slice(0, 10)) {
                console.log(`  ${formatIssueRow(issue)}`);
              }
              if (issues.length > 10) {
                console.log(chalk.dim(`  ... and ${issues.length - 10} more`));
              }
              console.log();
              return;
            }

            let imported = 0;
            let skipped = 0;
            for (const issue of issues) {
              try {
                const result = await importIssueAsTask(adapter, gh, projectId, issue, owner, repo, {
                  dryRun: false,
                  sync: opts.sync ?? false,
                  repoConfig,
                });
                if (result.created) {
                  imported++;
                } else {
                  skipped++;
                }
              } catch {
                skipped++;
              }
            }
            console.log(
              chalk.green(
                `\n  ✓ Imported ${imported} task${imported !== 1 ? "s" : ""} (${skipped} skipped: already exist)`,
              ),
            );
          }
        } catch (err) {
          handleGhError(err, "importing issue(s)");
        }
      },
    ),
);

// ---------------------------------------------------------------------------
// Import helper
// ---------------------------------------------------------------------------

interface ImportOptions {
  dryRun: boolean;
  sync: boolean;
  repoConfig: { id: string; default_labels: string[] };
}

interface ImportResult {
  taskId: string;
  created: boolean;
}

async function importIssueAsTask(
  adapter: PostgresAdapter,
  gh: GhCli,
  projectId: string,
  issue: GitHubIssue,
  owner: string,
  repo: string,
  opts: ImportOptions,
): Promise<ImportResult> {
  const externalId = `github:${owner}/${repo}#${issue.number}`;
  const externalRepo = `${owner}/${repo}`;

  // Check if already imported
  const existingTasks = await adapter.listTasks(projectId, {
    externalId: externalId,
  });
  if (existingTasks.length > 0) {
    return { taskId: existingTasks[0]!.id, created: false };
  }

  if (opts.dryRun) {
    return { taskId: "(dry-run)", created: true };
  }

  // Map GitHub labels to Foreman labels
  const foremanLabels: string[] = [];
  for (const label of issue.labels) {
    foremanLabels.push(`github:${label.name}`);
  }
  // Apply default repo labels
  for (const label of opts.repoConfig.default_labels) {
    if (!foremanLabels.includes(label)) {
      foremanLabels.push(label);
    }
  }

  // Map GitHub milestone to Foreman
  const githubMilestone = issue.milestone?.title ?? null;

  // Map GitHub state to Foreman status
  let status = "backlog";
  if (issue.state === "open") {
    status = "backlog";
  }

  // Create the task
  const task = await adapter.createTask(projectId, {
    title: issue.title,
    description: issue.body ?? undefined,
    type: "task",
    priority: 2,
    status,
    externalId,
    labels: foremanLabels.length > 0 ? foremanLabels : undefined,
    milestone: githubMilestone,
    external_repo: externalRepo,
    github_issue_number: issue.number,
    sync_enabled: opts.sync,
  });

  return { taskId: task.id, created: true };
}

// ---------------------------------------------------------------------------
// foreman issue labels
// ---------------------------------------------------------------------------

issueCommand.addCommand(
  new Command("labels")
    .description("List labels for a GitHub repository")
    .requiredOption("--repo <owner/repo>", "Repository (owner/repo)")
    .option("--project <name>", "Foreman project name")
    .option("--project-path <path>", "Foreman project path")
    .action(
      async (opts: { repo: string; project?: string; projectPath?: string }) => {
        await resolveProjectPathFromOptions(opts);
        const { owner, repo } = parseRepoKey(opts.repo);
        const gh = new GhCli();

        try {
          const labels = await gh.listLabels(owner, repo);
          console.log(chalk.bold(`\n  ${owner}/${repo} — ${labels.length} labels\n`));
          for (const label of labels.sort((a, b) => a.name.localeCompare(b.name))) {
            const color = "#" + label.color;
            console.log(`  ${chalk.bgHex(color).bold("  ")} ${chalk.yellow(label.name)}`);
            if (label.description) {
              console.log(chalk.dim(`    ${label.description}`));
            }
          }
          console.log();
        } catch (err) {
          handleGhError(err, "listing labels");
        }
      },
    ),
);

// ---------------------------------------------------------------------------
// foreman issue milestones
// ---------------------------------------------------------------------------

issueCommand.addCommand(
  new Command("milestones")
    .description("List milestones for a GitHub repository")
    .requiredOption("--repo <owner/repo>", "Repository (owner/repo)")
    .option("--state <open|closed|all>", "Filter by state", "open")
    .option("--project <name>", "Foreman project name")
    .option("--project-path <path>", "Foreman project path")
    .action(
      async (opts: { repo: string; state?: string; project?: string; projectPath?: string }) => {
        await resolveProjectPathFromOptions(opts);
        const { owner, repo } = parseRepoKey(opts.repo);
        const gh = new GhCli();

        try {
          const milestones = await gh.listMilestones(owner, repo);
          const filtered = milestones.filter((m) => {
            if (opts.state === "closed") return m.state === "closed";
            if (opts.state === "open") return m.state === "open";
            return true;
          });
          console.log(chalk.bold(`\n  ${owner}/${repo} — ${filtered.length} milestones\n`));
          for (const ms of filtered.sort((a, b) => a.number - b.number)) {
            const badge = ms.state === "open" ? chalk.green("●") : chalk.dim("○");
            console.log(
              `  ${badge} ${chalk.cyan(String(ms.number).padStart(3))} ${chalk.bold(ms.title)} ${chalk.dim(`(${ms.open_issues} open, ${ms.closed_issues} closed)`)}`,
            );
          }
          console.log();
        } catch (err) {
          handleGhError(err, "listing milestones");
        }
      },
    ),
);

// ---------------------------------------------------------------------------
// foreman issue webhook (TRD-037, TRD-038)
// ---------------------------------------------------------------------------

issueCommand.addCommand(
  new Command("webhook")
    .description("Manage GitHub webhooks for a repository")
    .requiredOption("--repo <owner/repo>", "Repository (owner/repo)")
    .option("--enable", "Enable webhook for issues and PR events")
    .option("--disable", "Disable webhook for the repository")
    .option("--url <url>", "Webhook endpoint URL (default: http://localhost:3847/webhook)")
    .option("--project <name>", "Foreman project name")
    .option("--project-path <path>", "Foreman project path")
    .action(
      async (opts: {
        repo: string;
        enable?: boolean;
        disable?: boolean;
        url?: string;
        project?: string;
        projectPath?: string;
      }) => {
        if (!opts.enable && !opts.disable) {
          console.error(
            chalk.red("Error: specify --enable or --disable"),
          );
          process.exit(1);
        }

        const { projectId } = await resolveProject(opts);
        const { owner, repo } = parseRepoKey(opts.repo);
        const gh = new GhCli();
        const adapter = new PostgresAdapter();

        const webhookUrl =
          opts.url ?? `http://localhost:3847/webhook`;

        try {
          if (opts.disable) {
            // List webhooks and remove any pointing to our endpoint
            const webhooks = await gh.listWebhooks(owner, repo);
            let disabled = 0;
            for (const wh of webhooks) {
              if (wh.url?.includes("/webhook") || wh.url === webhookUrl) {
                await gh.deleteWebhook(owner, repo, wh.id);
                disabled++;
              }
            }

            // Update repo config
            const repoConfig = await adapter.getGithubRepo(projectId, owner, repo);
            if (repoConfig) {
              await adapter.upsertGithubRepo({
                projectId,
                owner,
                repo,
                webhookSecret: null,
                webhookEnabled: false,
              });
            }

            console.log(
              chalk.green(
                `\n  Disabled ${disabled} webhook(s) for ${owner}/${repo}\n`,
              ),
            );
            return;
          }

          if (opts.enable) {
            // Generate or use existing secret
            const repoConfig = await adapter.getGithubRepo(projectId, owner, repo);
            const secret = repoConfig?.webhook_secret ?? null;

            if (!secret) {
              const { generateWebhookSecret } = await import(
                "../../daemon/webhook-handler.js"
              );
              const newSecret = generateWebhookSecret();

              const webhook = await gh.createWebhook(
                owner,
                repo,
                webhookUrl,
                newSecret,
              );

              // Store secret in database
              await adapter.upsertGithubRepo({
                projectId,
                owner,
                repo,
                webhookSecret: newSecret,
                webhookEnabled: true,
              });

              console.log(
                chalk.green(`\n  Enabled webhook for ${owner}/${repo}\n`),
              );
              console.log(
                `  ${chalk.dim("Webhook URL:")} ${chalk.cyan(webhookUrl)}`,
              );
              console.log(
                `  ${chalk.dim("Webhook ID:")} ${chalk.cyan(String(webhook.id))}`,
              );
              console.log(
                chalk.yellow(
                  `\n  ⚠️  Save this secret — it will not be shown again:\n\n    ${newSecret}\n`,
                ),
              );
              console.log(
                chalk.dim(
                  "  Configure your GitHub repository webhook URL to:\n" +
                    `    ${webhookUrl}\n\n` +
                    "  And paste the secret above when prompted by GitHub.\n",
                ),
              );
              return;
            }

            // Re-use existing secret
            const webhook = await gh.createWebhook(
              owner,
              repo,
              webhookUrl,
              secret,
            );

            await adapter.upsertGithubRepo({
              projectId,
              owner,
              repo,
              webhookSecret: secret,
              webhookEnabled: true,
            });

            console.log(
              chalk.green(`\n  Enabled webhook for ${owner}/${repo}\n`),
            );
            console.log(
              `  ${chalk.dim("Webhook URL:")} ${chalk.cyan(webhookUrl)}`,
            );
            console.log(
              `  ${chalk.dim("Webhook ID:")} ${chalk.cyan(String(webhook.id))}`,
            );
            return;
          }
        } catch (err) {
          if (err instanceof GhNotFoundError) {
            console.error(
              chalk.red(
                `Error: Repository ${owner}/${repo} not found or no admin access`,
              ),
            );
          } else {
            console.error(
              chalk.red(
                `Error: ${err instanceof Error ? err.message : String(err)}`,
              ),
            );
          }
          process.exit(1);
        }
      },
    ),
);

// ---------------------------------------------------------------------------
// foreman issue status (TRD-045)
// ---------------------------------------------------------------------------

issueCommand.addCommand(
  new Command("status")
    .description("Show sync status for a GitHub repository")
    .requiredOption("--repo <owner/repo>", "Repository (owner/repo)")
    .option("--project <name>", "Foreman project name")
    .option("--project-path <path>", "Foreman project path")
    .action(
      async (opts: {
        repo: string;
        project?: string;
        projectPath?: string;
      }) => {
        const { projectId } = await resolveProject(opts);
        const { owner, repo } = parseRepoKey(opts.repo);
        const adapter = new PostgresAdapter();

        try {
          const repoConfig = await adapter.getGithubRepo(projectId, owner, repo);
          if (!repoConfig) {
            console.log(
              chalk.yellow(
                `  ${chalk.bold(owner)}/${chalk.bold(repo)} is not configured for Foreman.\n  Run: foreman issue configure --repo ${owner}/${repo}`,
              ),
            );
            return;
          }

          const syncEvents = await adapter.listGithubSyncEvents(projectId, undefined, 10);

          console.log(chalk.bold(`\n  GitHub sync status: ${owner}/${repo}\n`));
          console.log(`  ${chalk.dim("Sync strategy:")} ${chalk.cyan(repoConfig.sync_strategy)}`);
          console.log(`  ${chalk.dim("Auto-import:")} ${chalk.cyan(String(repoConfig.auto_import))}`);
          console.log(`  ${chalk.dim("Webhook:")} ${repoConfig.webhook_enabled ? chalk.green("enabled") : chalk.dim("disabled")}`);
          console.log(
            `  ${chalk.dim("Last sync:")} ${repoConfig.last_sync_at ? chalk.cyan(repoConfig.last_sync_at) : chalk.dim("never")}`,
          );

          if (syncEvents.length > 0) {
            console.log(chalk.bold(`\n  Recent sync events:\n`));
            for (const event of syncEvents) {
              const dir = event.direction === "from_github" ? chalk.blue("←") : chalk.green("→");
              console.log(
                `  ${dir} ${chalk.cyan(event.event_type.padEnd(20))} ${chalk.dim(event.processed_at)}`,
              );
            }
          }
          console.log();
        } catch (err) {
          handleGhError(err, "fetching sync status");
        }
      },
    ),
);

// ---------------------------------------------------------------------------
// foreman issue link (TRD-046)
// ---------------------------------------------------------------------------

issueCommand.addCommand(
  new Command("link")
    .description("Link a GitHub pull request to an issue (or unlink)")
    .requiredOption("--repo <owner/repo>", "Repository (owner/repo)")
    .requiredOption("--issue <number>", "Issue number to link", (val) => parseInt(val, 10))
    .requiredOption("--pr <number>", "Pull request number to link", (val) => parseInt(val, 10))
    .option("--unlink", "Remove the link instead of creating it")
    .option("--project <name>", "Foreman project name")
    .option("--project-path <path>", "Foreman project path")
    .action(
      async (opts: {
        repo: string;
        issue: number;
        pr: number;
        unlink?: boolean;
        project?: string;
        projectPath?: string;
      }) => {
        const { owner, repo } = parseRepoKey(opts.repo);
        const gh = new GhCli();

        try {
          if (opts.unlink) {
            await gh.unlinkIssueFromPullRequest(owner, repo, opts.issue, String(opts.pr));
            console.log(
              chalk.green(`\n  Unlinked PR #${opts.pr} from issue #${opts.issue} on ${owner}/${repo}\n`),
            );
          } else {
            await gh.linkIssueToPullRequest(owner, repo, opts.issue, opts.pr);
            console.log(
              chalk.green(`\n  Linked PR #${opts.pr} to issue #${opts.issue} on ${owner}/${repo}\n`),
            );
          }
        } catch (err) {
          handleGhError(err, "linking issue to PR");
        }
      },
    ),
);
