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
import { basename, resolve } from "node:path";
import { Command } from "commander";
import { createTrpcClient } from "../../lib/trpc-client.js";
import { encrypt } from "../../lib/encryption.js";
import { foremanBackendMode } from "../../lib/backend-mode.js";
import { listRegisteredProjects, registerProjectInElixir } from "./project-task-support.js";
// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
/** Column widths for the project table. */
const COL_NAME = 24;
const COL_ID = 14;
const COL_STATUS = 12;
function pad(str, width) {
    return str.length >= width ? str.slice(0, width - 1) + "…" : str.padEnd(width);
}
function printProjectTable(projects, label) {
    if (projects.length === 0) {
        if (label) {
            console.log(chalk.dim(`No ${label} projects found.`));
        }
        else {
            console.log(chalk.dim("No projects registered."));
        }
        return;
    }
    // Header
    console.log(chalk.bold(pad("NAME", COL_NAME)) +
        chalk.bold(pad("ID", COL_ID)) +
        chalk.bold(pad("STATUS", COL_STATUS)));
    console.log("─".repeat(COL_NAME + COL_ID + COL_STATUS));
    for (const p of projects) {
        const name = p.name ?? "(unnamed)";
        const id = p.id ?? "(unknown)";
        const status = p.status ?? "unknown";
        const statusColor = status === "active"
            ? chalk.green(status)
            : status === "paused"
                ? chalk.yellow(status)
                : chalk.dim(status);
        console.log(chalk.cyan(pad(name, COL_NAME)) +
            chalk.dim(pad(id, COL_ID)) +
            statusColor);
    }
}
function getClient() {
    return createTrpcClient();
}
function requireNodeProjectCommand(subcommand) {
    if (foremanBackendMode() !== "elixir")
        return;
    console.error(chalk.red(`Error: 'foreman project ${subcommand}' is legacy Node-backed only. Set FOREMAN_BACKEND=node for explicit legacy operation.`));
    process.exit(1);
}
function collectErrorDetails(err) {
    const seen = new Set();
    const details = new Set();
    const visit = (value) => {
        if (value == null || seen.has(value))
            return;
        if (typeof value === "object" || typeof value === "function") {
            seen.add(value);
        }
        if (value instanceof AggregateError) {
            const message = value.message?.trim();
            if (message)
                details.add(message);
            for (const nested of value.errors) {
                visit(nested);
            }
            return;
        }
        if (value instanceof Error) {
            const message = value.message?.trim();
            if (message)
                details.add(message);
            visit(value.cause);
            return;
        }
        if (typeof value === "string") {
            const message = value.trim();
            if (message)
                details.add(message);
        }
    };
    visit(err);
    return [...details];
}
function handleDaemonError(err) {
    const details = collectErrorDetails(err);
    const message = details[0] ?? (err instanceof Error ? err.message : String(err));
    const combined = details.join(" | ");
    if (combined.includes("ECONNREFUSED") ||
        combined.includes("ENOENT") ||
        combined.includes("EPERM") ||
        combined.includes("connect")) {
        console.error(chalk.red("Error: Cannot connect to the Foreman daemon.") +
            chalk.dim("\n  Make sure the daemon is running: foreman daemon start") +
            (message
                ? chalk.dim(`\n  Underlying error: ${message}`)
                : ""));
    }
    else {
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
    .option("--jira-project <key>", "Jira project key", (val, prev) => { prev.push(val.toUpperCase()); return prev; }, [])
    .option("--jira-start-status <status>", "Status that triggers workflow", (val, prev) => { prev.push(val); return prev; }, [])
    .option("--jira-end-status <status>", "Status that completes workflow", (val, prev) => { prev.push(val); return prev; }, [])
    .option("--jira-issue-type <type=workflow>", "Map issue type to workflow", (val, prev) => { const [type, workflow] = val.split("="); prev.push({ type, workflow }); return prev; }, [])
    .option("--jira-poll-interval <seconds>", "Poll interval in seconds (default: 60)")
    .option("--jira-webhook-enabled", "Enable webhook-based triggers")
    .option("--jira-webhook-secret-env <name>", "Environment variable for webhook secret")
    .action(async (githubUrl, opts) => {
    requireNodeProjectCommand("add");
    const client = getClient();
    try {
        const result = (await client.projects.add({
            githubUrl,
            name: opts.name,
            defaultBranch: opts.defaultBranch,
            status: opts.status,
        }));
        console.log(chalk.green(`✓ Project '${result.name}' added as '${result.id}'`));
        console.log(chalk.dim(`  Clone: ${result.path ?? "unknown"}`));
        console.log(chalk.dim(`  GitHub: ${githubUrl}`));
        console.log(chalk.dim(`  Branch: ${result.default_branch ?? "main"}`));
        // Apply Jira configuration if provided
        const jiraUpdates = await buildJiraUpdates(opts);
        if (jiraUpdates) {
            await client.projects.update({
                id: result.id,
                updates: { jira: jiraUpdates },
            });
            console.log(chalk.dim("  Jira: configured"));
        }
    }
    catch (err) {
        handleDaemonError(err);
    }
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
    .action(async (pathArg, opts) => {
    const projectPath = resolve(pathArg ?? process.cwd());
    const fallbackName = opts.name ?? basename(projectPath);
    try {
        const project = await registerProjectInElixir(projectPath, {
            name: opts.name,
            defaultBranch: opts.defaultBranch,
            status: opts.status,
        });
        console.log(chalk.green(`✓ Project '${project.name ?? fallbackName}' registered with Elixir as '${project.id}'`));
        console.log(chalk.dim(`  Path: ${project.path}`));
        console.log(chalk.dim(`  Branch: ${project.defaultBranch ?? "main"}`));
    }
    catch (err) {
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
        const projects = foremanBackendMode() === "elixir"
            ? (await listRegisteredProjects()).filter((project) => {
                if (opts.status && project.status && project.status !== opts.status)
                    return false;
                if (opts.status && !project.status && opts.status !== "active")
                    return false;
                if (opts.search && !project.name.toLowerCase().includes(String(opts.search).toLowerCase()))
                    return false;
                return true;
            }).map((project) => ({
                id: project.id,
                name: project.name,
                path: project.path,
                status: project.status ?? "active",
            }))
            : await (async () => {
                const client = getClient();
                return await client.projects.list({
                    status: opts.status,
                    search: opts.search,
                });
            })();
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
    }
    catch (err) {
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
    .action(async (projectId, opts) => {
    requireNodeProjectCommand("remove");
    const client = getClient();
    try {
        await client.projects.remove({
            id: projectId,
            force: opts.force,
        });
        console.log(chalk.green(`✓ Project '${projectId}' removed.`));
    }
    catch (err) {
        handleDaemonError(err);
    }
});
async function buildJiraUpdates(opts) {
    const jiraUpdates = {};
    if (opts.jiraUrl)
        jiraUpdates.apiUrl = opts.jiraUrl;
    if (opts.jiraEmail)
        jiraUpdates.email = opts.jiraEmail;
    if (opts.jiraToken)
        jiraUpdates.apiToken = await encrypt(opts.jiraToken);
    if (opts.jiraPollInterval)
        jiraUpdates.pollIntervalSeconds = Number(opts.jiraPollInterval);
    if (opts.jiraWebhookEnabled !== undefined)
        jiraUpdates.webhookEnabled = true;
    if (opts.jiraWebhookSecretEnv)
        jiraUpdates.webhookSecretEnvVar = opts.jiraWebhookSecretEnv;
    // Build projects array if any project options provided
    const projectKeys = opts.jiraProject ?? [];
    const startStatuses = opts.jiraStartStatus ?? [];
    const endStatuses = opts.jiraEndStatus ?? [];
    const issueTypeMappings = opts.jiraIssueType ?? [];
    const projects = [];
    for (let i = 0; i < projectKeys.length; i++) {
        const project = {
            key: projectKeys[i],
            startStatus: startStatuses[i] ? startStatuses[i].split(",").map((s) => s.trim()) : [],
            endStatus: endStatuses[i] ? endStatuses[i].split(",").map((s) => s.trim()) : [],
            issueTypeWorkflowMap: {},
        };
        // Map issue type=workflow pairs for this project index
        for (const mapping of issueTypeMappings) {
            project.issueTypeWorkflowMap[mapping.type] = mapping.workflow;
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
    .option("--jira-url <url>", "Jira Cloud API URL (e.g., https://your-domain.atlassian.net)")
    .option("--jira-email <email>", "Jira account email")
    .option("--jira-token <token>", "Jira API token (will be encrypted)")
    .option("--jira-project <key>", "Jira project key", (val, prev) => { prev.push(val.toUpperCase()); return prev; }, [])
    .option("--jira-start-status <status>", "Status that triggers workflow", (val, prev) => { prev.push(val); return prev; }, [])
    .option("--jira-end-status <status>", "Status that completes workflow", (val, prev) => { prev.push(val); return prev; }, [])
    .option("--jira-issue-type <type=workflow>", "Map issue type to workflow", (val, prev) => { const [type, workflow] = val.split("="); prev.push({ type, workflow }); return prev; }, [])
    .option("--jira-poll-interval <seconds>", "Poll interval in seconds (default: 60)")
    .option("--jira-webhook-enabled", "Enable webhook-based triggers")
    .option("--jira-webhook-secret-env <name>", "Environment variable for webhook secret")
    .action(async (projectId, opts) => {
    requireNodeProjectCommand("edit");
    const client = getClient();
    try {
        // Build Jira config updates if any Jira options provided
        const jiraUpdates = await buildJiraUpdates(opts);
        const updates = {};
        if (opts.name)
            updates.name = opts.name;
        if (opts.status)
            updates.status = opts.status;
        if (jiraUpdates)
            updates.jira = jiraUpdates;
        if (Object.keys(updates).length === 0) {
            console.log(chalk.yellow("No updates provided. Use --help to see available options."));
            return;
        }
        await client.projects.update({
            id: projectId,
            updates,
        });
        console.log(chalk.green(`✓ Project '${projectId}' updated.`));
    }
    catch (err) {
        handleDaemonError(err);
    }
});
// ---------------------------------------------------------------------------
// Parent command
// ---------------------------------------------------------------------------
export const projectCommand = new Command("project")
    .description("Manage projects (Elixir register/list plus legacy-gated daemon add/remove/edit)")
    .addCommand(addCommand)
    .addCommand(registerCommand)
    .addCommand(listCommand)
    .addCommand(removeCommand)
    .addCommand(editCommand);
//# sourceMappingURL=project.js.map