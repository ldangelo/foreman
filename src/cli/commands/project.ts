/**
 * `foreman project` CLI commands — manage projects via the Elixir backend.
 *
 * Sub-commands:
 *   foreman project add <path> [--name <name>] [--force]
 *   foreman project list [--status <active|paused|archived>]
 *   foreman project remove <id> [--force]
 *
 * @module src/cli/commands/project
 */
import chalk from "chalk";
import { basename, resolve } from "node:path";
import { Command } from "commander";

import { archiveProjectInElixir, listRegisteredProjects, registerProjectInElixir, updateProjectInElixir } from "./project-task-support.js";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Column widths for the project table. */
const COL_NAME = 24;
const COL_ID = 14;
const COL_STATUS = 12;

function pad(str: string, width: number): string {
  return str.length >= width ? str.slice(0, width - 1) + "…" : str.padEnd(width);
}

interface ProjectRow {
  id: string;
  name: string;
  path?: string | null;
  status?: string | null;
  addedAt?: string | null;
}

function printProjectTable(projects: ProjectRow[], label?: string): void {
  if (projects.length === 0) {
    if (label) {
      console.log(chalk.dim(`No ${label} projects found.`));
    } else {
      console.log(chalk.dim("No projects registered."));
    }
    return;
  }

  // Header
  console.log(
    chalk.bold(pad("NAME", COL_NAME)) +
      chalk.bold(pad("ID", COL_ID)) +
      chalk.bold(pad("STATUS", COL_STATUS)),
  );
  console.log("─".repeat(COL_NAME + COL_ID + COL_STATUS));

  for (const p of projects) {
    const name = p.name ?? "(unnamed)";
    const id = p.id ?? "(unknown)";
    const status = p.status ?? "unknown";
    const statusColor =
      status === "active"
        ? chalk.green(status)
        : status === "paused"
          ? chalk.yellow(status)
          : chalk.dim(status);

    console.log(
      chalk.cyan(pad(name, COL_NAME)) +
        chalk.dim(pad(id, COL_ID)) +
        statusColor,
    );
  }
}

function rejectRemovedProjectAdd(): never {
  console.error(chalk.red("Error: 'foreman project add' was removed after the Elixir backend cutover."));
  console.error(chalk.dim("  Clone the repository locally, then run: foreman project register <path>"));
  process.exit(1);
}

function collectErrorDetails(err: unknown): string[] {
  const seen = new Set<unknown>();
  const details = new Set<string>();

  const visit = (value: unknown): void => {
    if (value == null || seen.has(value)) return;
    if (typeof value === "object" || typeof value === "function") {
      seen.add(value);
    }

    if (value instanceof AggregateError) {
      const message = value.message?.trim();
      if (message) details.add(message);
      for (const nested of value.errors) {
        visit(nested);
      }
      return;
    }

    if (value instanceof Error) {
      const message = value.message?.trim();
      if (message) details.add(message);
      visit((value as Error & { cause?: unknown }).cause);
      return;
    }

    if (typeof value === "string") {
      const message = value.trim();
      if (message) details.add(message);
    }
  };

  visit(err);
  return [...details];
}

function handleDaemonError(err: unknown): never {
  const details = collectErrorDetails(err);
  const message = details[0] ?? (err instanceof Error ? err.message : String(err));
  const combined = details.join(" | ");
  if (
    combined.includes("ECONNREFUSED") ||
    combined.includes("ENOENT") ||
    combined.includes("EPERM") ||
    combined.includes("connect")
  ) {
    console.error(
      chalk.red("Error: Cannot connect to the Foreman Elixir server.") +
        chalk.dim("\n  Make sure the server is running: foreman server start") +
        (message
          ? chalk.dim(`\n  Underlying error: ${message}`)
          : ""),
    );
  } else {
    console.error(chalk.red(`Error: ${message}`));
  }
  process.exit(1);
}

// ---------------------------------------------------------------------------
// foreman project add
// ---------------------------------------------------------------------------

const addCommand = new Command("add")
  .description("Removed: clone locally, then register the repository with Elixir")
  .argument("<github-url>", "GitHub repository URL or owner/repo shorthand")
  .description(`Examples:
    foreman project add owner/repo
    foreman project add https://github.com/owner/repo
    foreman project add git@github.com:owner/repo.git`)
  .option("--name <name>", "Project display name (default: repo name from GitHub)")
  .option("--default-branch <branch>", "Override the default git branch")
  .option("--status <status>", "Project status", "active")
  .option("--jira-url <url>", "Jira Cloud API URL (e.g., https://your-domain.atlassian.net)")
  .option("--jira-email <email>", "Jira account email")
  .option("--jira-token <token>", "Jira API token (will be encrypted)")
  .option("--jira-project <key>", "Jira project key", (val, prev) => { prev.push(val.toUpperCase()); return prev; }, [] as string[])
  .option("--jira-start-status <status>", "Status that triggers workflow", (val, prev) => { prev.push(val); return prev; }, [] as string[])
  .option("--jira-end-status <status>", "Status that completes workflow", (val, prev) => { prev.push(val); return prev; }, [] as string[])
  .option("--jira-issue-type <type=workflow>", "Map issue type to workflow", (val, prev) => { const [type, workflow] = val.split("="); prev.push({ type, workflow }); return prev; }, [] as JiraIssueTypeMapping[])
  .option("--jira-poll-interval <seconds>", "Poll interval in seconds (default: 60)")
  .option("--jira-webhook-enabled", "Enable webhook-based triggers")
  .option("--jira-webhook-secret-env <name>", "Environment variable for webhook secret")
  .action(async (githubUrl: string, opts) => {
    void githubUrl;
    void opts;
    rejectRemovedProjectAdd();
  });

// ---------------------------------------------------------------------------
// foreman project register
// ---------------------------------------------------------------------------

const registerCommand = new Command("register")
  .description("Register an existing local repository with Elixir project projections")
  .argument("[path]", "Repository path (default: current directory)")
  .option("--name <name>", "Project display name (default: directory name or existing registry name)")
  .option("--default-branch <branch>", "Default branch name")
  .option("--status <status>", "Project status", "active")
  .action(async (pathArg: string | undefined, opts) => {
    const projectPath = resolve(pathArg ?? process.cwd());
    const fallbackName = opts.name ?? basename(projectPath);
    try {
      const project = await registerProjectInElixir(projectPath, {
        name: opts.name,
        defaultBranch: opts.defaultBranch,
        status: opts.status as "active" | "paused" | "archived",
      });
      console.log(chalk.green(`✓ Project '${project.name ?? fallbackName}' registered with Elixir as '${project.id}'`));
      console.log(chalk.dim(`  Path: ${project.path}`));
      console.log(chalk.dim(`  Branch: ${project.defaultBranch ?? "main"}`));
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });

// ---------------------------------------------------------------------------
// foreman project list
// ---------------------------------------------------------------------------

const listCommand = new Command("list")
  .description("List all projects")
  .option("--status <status>", "Filter by status: active, paused, archived")
  .option("--search <term>", "Search by name")
  .option("--json", "Output as JSON")
  .action(async (opts) => {
    try {
      const projects = (await listRegisteredProjects({ includeArchived: Boolean(opts.status) })).filter((project) => {
        if (opts.status && project.status && project.status !== opts.status) return false;
        if (opts.status && !project.status && opts.status !== "active") return false;
        if (opts.search && !project.name.toLowerCase().includes(String(opts.search).toLowerCase())) return false;
        return true;
      }).map((project) => ({
        id: project.id,
        name: project.name,
        path: project.path,
        status: project.status ?? "active",
      }));

      if (opts.json) {
        console.log(JSON.stringify(projects, null, 2));
        return;
      }

      if (projects.length === 0) {
        console.log(chalk.dim("No projects found."));
        return;
      }

      console.log(chalk.bold(`\n  Projects (${projects.length})\n`));
      printProjectTable(projects);
      console.log();
    } catch (err) {
      handleDaemonError(err);
    }
  });

// ---------------------------------------------------------------------------
// foreman project remove
// ---------------------------------------------------------------------------

const removeCommand = new Command("remove")
  .description("Archive a project through Elixir projections")
  .argument("<id>", "Project ID to remove")
  .option("--force", "Force remove even if there are active agents")
  .action(async (projectId: string, opts) => {
    try {
      await archiveProjectInElixir(projectId, { force: Boolean(opts.force) });
      console.log(chalk.green(`✓ Project '${projectId}' archived.`));
    } catch (err) {
      handleDaemonError(err);
    }
  });
// ---------------------------------------------------------------------------
// foreman project edit
// ---------------------------------------------------------------------------

interface JiraIssueTypeMapping {
  type: string;
  workflow: string;
}
function hasJiraOptions(opts: Record<string, unknown>): boolean {
  return Boolean(
    opts.jiraUrl ||
    opts.jiraEmail ||
    opts.jiraToken ||
    opts.jiraPollInterval ||
    opts.jiraWebhookEnabled !== undefined ||
    opts.jiraWebhookSecretEnv ||
    ((opts.jiraProject as string[] | undefined) ?? []).length > 0 ||
    ((opts.jiraStartStatus as string[] | undefined) ?? []).length > 0 ||
    ((opts.jiraEndStatus as string[] | undefined) ?? []).length > 0 ||
    ((opts.jiraIssueType as JiraIssueTypeMapping[] | undefined) ?? []).length > 0
  );
}

const editCommand = new Command("edit")
  .description("Edit project settings")
  .argument("<id>", "Project ID to edit")
  .option("--name <name>", "Project display name")
  .option("--status <status>", "Project status: active, paused, archived")
  .option("--default-branch <branch>", "Default branch name")
  .option("--jira-url <url>", "Jira Cloud API URL (e.g., https://your-domain.atlassian.net)")
  .option("--jira-email <email>", "Jira account email")
  .option("--jira-token <token>", "Jira API token (will be encrypted)")
  .option("--jira-project <key>", "Jira project key", (val, prev) => { prev.push(val.toUpperCase()); return prev; }, [] as string[])
  .option("--jira-start-status <status>", "Status that triggers workflow", (val, prev) => { prev.push(val); return prev; }, [] as string[])
  .option("--jira-end-status <status>", "Status that completes workflow", (val, prev) => { prev.push(val); return prev; }, [] as string[])
  .option("--jira-issue-type <type=workflow>", "Map issue type to workflow", (val, prev) => { const [type, workflow] = val.split("="); prev.push({ type, workflow }); return prev; }, [] as JiraIssueTypeMapping[])
  .option("--jira-poll-interval <seconds>", "Poll interval in seconds (default: 60)")
  .option("--jira-webhook-enabled", "Enable webhook-based triggers")
  .option("--jira-webhook-secret-env <name>", "Environment variable for webhook secret")
  .action(async (projectId: string, opts) => {
    try {
      const jiraUpdates = hasJiraOptions(opts);
      const updates: Record<string, unknown> = {};
      if (opts.name) updates.name = opts.name;
      if (opts.status) updates.status = opts.status;
      if (opts.defaultBranch) updates.defaultBranch = opts.defaultBranch;
      if (jiraUpdates) updates.jira = true;
      if (Object.keys(updates).length === 0) {
        console.log(chalk.yellow("No updates provided. Use --help to see available options."));
        return;
      }

      if (jiraUpdates) {
        console.error(chalk.red("Error: Jira project settings are not part of the Elixir project edit surface."));
        console.error(chalk.dim("  Jira transition ingestion remains available through the Elixir ExternalTriggerCommand API."));
        process.exit(1);
      }
      await updateProjectInElixir(projectId, {
        name: opts.name,
        status: opts.status,
        defaultBranch: opts.defaultBranch,
      });
      console.log(chalk.green(`✓ Project '${projectId}' updated.`));
    } catch (err) {
      handleDaemonError(err);
    }
  });

// ---------------------------------------------------------------------------
// Parent command
// ---------------------------------------------------------------------------

export const projectCommand = new Command("project")
  .description("Manage Elixir-registered projects")
  .addCommand(addCommand)
  .addCommand(registerCommand)
  .addCommand(listCommand)
  .addCommand(removeCommand)
  .addCommand(editCommand);