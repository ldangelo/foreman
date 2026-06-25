/**
 * `foreman project` CLI commands — manage projects via ForemanDaemon.
 *
 * Sub-commands:
 *   foreman project add <path> [--name <name>] [--force]
 *   foreman project list [--status <active|paused|archived>]
 *   foreman project remove <id> [--force]
 *
 * All commands connect to the daemon via TrpcClient (Unix socket).
 *
 * @module src/cli/commands/project
 */
import chalk from "chalk";
import { basename, join } from "node:path";
import { homedir } from "node:os";
import { mkdir } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { Command } from "commander";
import { createTrpcClient } from "../../lib/trpc-client.js";
import { encrypt } from "../../lib/encryption.js";
import { foremanBackendMode } from "../../lib/backend-mode.js";
import { ElixirServerClient, type ElixirProject } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import {
  GhCli,
  GhError,
  GhNotAuthenticatedError,
  GhNotInstalledError,
} from "../../lib/gh-cli.js";

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
  default_branch?: string | null;
  github_url?: string | null;
}

interface ProjectAddInput {
  githubUrl: string;
  name?: string;
  defaultBranch?: string;
  status?: "active" | "paused" | "archived";
}

interface ProjectAddResult extends ProjectRow {
  default_branch?: string | null;
}

interface ProjectCommandClient {
  backend: "node" | "elixir";
  add(input: ProjectAddInput): Promise<ProjectAddResult>;
  list(input?: { status?: "active" | "paused" | "archived"; search?: string }): Promise<ProjectRow[]>;
  update(id: string, updates: Record<string, unknown>): Promise<void>;
  remove(id: string, force?: boolean): Promise<void>;
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

function generateProjectId(name: string): string {
  const normalized = name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-+/g, "-");

  const hex5 = randomBytes(3).toString("hex").slice(0, 5);
  return `${normalized || "project"}-${hex5}`;
}

function parseGitHubUrl(url: string): { owner: string; repo: string } {
  const httpsMatch = url.match(/^https?:\/\/github\.com\/([^/]+)\/([^/.]+)/i);
  if (httpsMatch) {
    return { owner: httpsMatch[1]!, repo: httpsMatch[2]!.replace(/\.git$/, "") };
  }

  const sshMatch = url.match(/^git@github\.com:([^/]+)\/(.+?)(?:\.git)?$/i);
  if (sshMatch) {
    return { owner: sshMatch[1]!, repo: sshMatch[2]! };
  }

  const shortcutMatch = url.match(/^([^/]+)\/(.+)$/);
  if (shortcutMatch) {
    return { owner: shortcutMatch[1]!, repo: shortcutMatch[2]! };
  }

  throw new Error(
    `Invalid GitHub URL '${url}'. Expected formats: "owner/repo", "https://github.com/owner/repo", or "git@github.com:owner/repo"`,
  );
}

function toRepoKey(owner: string, repo: string): string {
  return `${owner}/${repo}`.toLowerCase();
}

async function addElixirProject(
  client: ElixirServerClient,
  input: ProjectAddInput,
): Promise<ProjectAddResult> {
  const gh = new GhCli();

  try {
    await gh.checkAuth();
  } catch (err) {
    if (err instanceof GhNotInstalledError) {
      throw new Error("GitHub CLI (gh) is required but not installed. Install it from https://cli.github.com");
    }
    if (err instanceof GhNotAuthenticatedError) {
      throw new Error(`${err.message}. Run 'gh auth login' first.`);
    }
    throw err;
  }

  const parsed = parseGitHubUrl(input.githubUrl);
  const repoKey = toRepoKey(parsed.owner, parsed.repo);
  let defaultBranch = input.defaultBranch ?? "main";
  let displayName = input.name ?? parsed.repo;

  try {
    const meta = await gh.getRepoMetadata(parsed.owner, parsed.repo);
    defaultBranch = input.defaultBranch ?? meta.defaultBranch;
    displayName = input.name ?? parsed.repo;
  } catch (err) {
    if (err instanceof GhError) {
      throw new Error(`Failed to fetch repository metadata for '${input.githubUrl}': ${err.message}`);
    }
    throw err;
  }

  const projectId = generateProjectId(displayName);
  const clonePath = join(homedir(), ".foreman", "projects", projectId);
  await mkdir(join(homedir(), ".foreman", "projects"), { recursive: true });

  try {
    await gh.repoClone(input.githubUrl, clonePath);
  } catch (err) {
    if (err instanceof GhNotAuthenticatedError) {
      throw new Error(`GitHub authentication required to clone '${input.githubUrl}'. Run 'gh auth login' first.`);
    }
    if (err instanceof GhError) {
      throw new Error(`Failed to clone repository '${input.githubUrl}': ${err.message}`);
    }
    throw err;
  }

  await sendElixirProjectCommand(client, "project.register", {
    project_id: projectId,
    name: displayName,
    path: clonePath,
    github_url: input.githubUrl,
    default_branch: defaultBranch,
    status: input.status ?? "active",
    config: { repo_key: repoKey },
  });

  return {
    id: projectId,
    name: displayName,
    path: clonePath,
    github_url: input.githubUrl,
    default_branch: defaultBranch,
    status: input.status ?? "active",
  };
}

function rowFromElixirProject(project: ElixirProject): ProjectRow {
  const id = project.project_id ?? project.id ?? "unknown";
  return {
    id,
    name: project.name ?? (project.path ? basename(project.path) : id),
    path: project.path,
    status: project.status ?? "active",
    default_branch: project.default_branch ?? null,
    github_url: project.github_url ?? null,
  };
}

async function sendElixirProjectCommand(
  client: ElixirServerClient,
  commandType: string,
  payload: Record<string, unknown>,
): Promise<void> {
  const response = await client.sendCommand({
    command_id: `cli-${commandType}-${Date.now()}-${randomBytes(4).toString("hex")}`,
    command_type: commandType,
    payload,
    metadata: { correlation_id: `cli-${commandType}-${Date.now()}` },
  });
  if (!response.ok) {
    throw new Error(response.error.message);
  }
}

async function getProjectClient(): Promise<ProjectCommandClient> {
  if (foremanBackendMode() === "elixir") {
    const manager = new ElixirServerManager();
    const status = await manager.ensureRunning();
    const client = new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN);
    return {
      backend: "elixir",
      add: (input) => addElixirProject(client, input),
      async list(input = {}) {
        let rows = (await client.listProjects()).map(rowFromElixirProject);
        if (input.status) rows = rows.filter((project) => project.status === input.status);
        if (input.search) {
          const search = input.search.toLowerCase();
          rows = rows.filter((project) => project.name.toLowerCase().includes(search));
        }
        return rows;
      },
      async update(id, updates) {
        await sendElixirProjectCommand(client, "project.update", {
          project_id: id,
          ...updates,
        });
      },
      async remove(id) {
        await sendElixirProjectCommand(client, "project.archive", { project_id: id });
      },
    };
  }

  const client = createTrpcClient();
  return {
    backend: "node",
    add: (input) => client.projects.add(input) as Promise<ProjectAddResult>,
    list: (input) => client.projects.list(input) as Promise<ProjectRow[]>,
    update: async (id, updates) => {
      await client.projects.update({ id, updates });
    },
    remove: async (id, force) => {
      await client.projects.remove({ id, force });
    },
  };
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
      chalk.red("Error: Cannot connect to the Foreman daemon.") +
        chalk.dim("\n  Make sure the daemon is running: foreman daemon start") +
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
  .description("Clone a GitHub repository and register it as a project via ForemanDaemon")
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
    try {
      const client = await getProjectClient();
      const result = await client.add({
        githubUrl,
        name: opts.name,
        defaultBranch: opts.defaultBranch,
        status: opts.status as "active" | "paused" | "archived",
      });
      console.log(
        chalk.green(
          `✓ Project '${result.name}' added as '${result.id}'`
        )
      );
      console.log(
        chalk.dim(`  Clone: ${result.path ?? "unknown"}`)
      );
      console.log(
        chalk.dim(`  GitHub: ${githubUrl}`)
      );
      console.log(
        chalk.dim(`  Branch: ${result.default_branch ?? "main"}`)
      );
      // Apply Jira configuration if provided
      const jiraUpdates = await buildJiraUpdates(opts);
      if (jiraUpdates) {
        await client.update(result.id, { jira: jiraUpdates });
        console.log(chalk.dim("  Jira: configured"));
      }
    } catch (err) {
      handleDaemonError(err);
    }
  });

// ---------------------------------------------------------------------------
// foreman project list
// ---------------------------------------------------------------------------

const listCommand = new Command("list")
  .description("List all projects via ForemanDaemon")
  .option("--status <status>", "Filter by status: active, paused, archived")
  .option("--search <term>", "Search by name")
  .option("--json", "Output as JSON")
  .action(async (opts) => {
    try {
      const client = await getProjectClient();
      const projects = await client.list({
        status: opts.status as "active" | "paused" | "archived" | undefined,
        search: opts.search,
      });

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
  .description("Remove (archive) a project via ForemanDaemon")
  .argument("<id>", "Project ID to remove")
  .option("--force", "Force remove even if there are active agents")
  .action(async (projectId: string, opts) => {
    try {
      const client = await getProjectClient();
      await client.remove(projectId, opts.force);
      console.log(chalk.green(`✓ Project '${projectId}' removed.`));
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
async function buildJiraUpdates(opts: Record<string, unknown>): Promise<Record<string, unknown> | undefined> {
  const jiraUpdates: Record<string, unknown> = {};
  if (opts.jiraUrl) jiraUpdates.apiUrl = opts.jiraUrl;
  if (opts.jiraEmail) jiraUpdates.email = opts.jiraEmail;
  if (opts.jiraToken) jiraUpdates.apiToken = await encrypt(opts.jiraToken as string);
  if (opts.jiraPollInterval) jiraUpdates.pollIntervalSeconds = Number(opts.jiraPollInterval);
  if (opts.jiraWebhookEnabled !== undefined) jiraUpdates.webhookEnabled = true;
  if (opts.jiraWebhookSecretEnv) jiraUpdates.webhookSecretEnvVar = opts.jiraWebhookSecretEnv;
  // Build projects array if any project options provided
  const projectKeys = (opts.jiraProject as string[] | undefined) ?? [];
  const startStatuses = (opts.jiraStartStatus as string[] | undefined) ?? [];
  const endStatuses = (opts.jiraEndStatus as string[] | undefined) ?? [];
  const issueTypeMappings = (opts.jiraIssueType as JiraIssueTypeMapping[] | undefined) ?? [];
  const projects: Array<Record<string, unknown>> = [];
  for (let i = 0; i < projectKeys.length; i++) {
    const project: Record<string, unknown> = {
      key: projectKeys[i],
      startStatus: startStatuses[i] ? startStatuses[i].split(",").map((s: string) => s.trim()) : [],
      endStatus: endStatuses[i] ? endStatuses[i].split(",").map((s: string) => s.trim()) : [],
      issueTypeWorkflowMap: {} as Record<string, string>,
    };
    // Map issue type=workflow pairs for this project index
    for (const mapping of issueTypeMappings) {
      (project.issueTypeWorkflowMap as Record<string, string>)[mapping.type] = mapping.workflow;
    }
    projects.push(project);
  }
  if (projects.length > 0) {
    jiraUpdates.projects = projects;
  }
  // Return undefined if no Jira options were provided
  const hasUpdates = Object.keys(jiraUpdates).length > 0;
  return hasUpdates ? jiraUpdates : undefined;
}

const editCommand = new Command("edit")
  .description("Edit project settings")
  .argument("<id>", "Project ID to edit")
  .option("--name <name>", "Project display name")
  .option("--status <status>", "Project status: active, paused, archived")
  .option("--default-branch <branch>", "Default/base branch for new project worktrees")
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
      const client = await getProjectClient();
      // Build Jira config updates if any Jira options provided
      const jiraUpdates = await buildJiraUpdates(opts);
      const updates: Record<string, unknown> = {};
      if (opts.name) updates.name = opts.name;
      if (opts.status) updates.status = opts.status;
      if (opts.defaultBranch) updates[client.backend === "elixir" ? "default_branch" : "defaultBranch"] = opts.defaultBranch;
      if (jiraUpdates) updates.jira = jiraUpdates;
      if (Object.keys(updates).length === 0) {
        console.log(chalk.yellow("No updates provided. Use --help to see available options."));
        return;
      }
      await client.update(projectId, updates);
      console.log(chalk.green(`✓ Project '${projectId}' updated.`));
    } catch (err) {
      handleDaemonError(err);
    }
  });

// ---------------------------------------------------------------------------
// Parent command
// ---------------------------------------------------------------------------

export const projectCommand = new Command("project")
  .description("Manage projects via ForemanDaemon (list/add/remove/edit)")
  .addCommand(addCommand)
  .addCommand(listCommand)
  .addCommand(removeCommand)
  .addCommand(editCommand);