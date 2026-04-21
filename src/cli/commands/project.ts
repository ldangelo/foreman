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

import { Command } from "commander";
import chalk from "chalk";
import { resolve } from "node:path";
import { createTrpcClient } from "../../lib/trpc-client.js";

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

function getClient() {
  return createTrpcClient();
}

function handleDaemonError(err: unknown): never {
  const message = err instanceof Error ? err.message : String(err);
  if (
    message.includes("ECONNREFUSED") ||
    message.includes("ENOENT") ||
    message.includes("connect")
  ) {
    console.error(
      chalk.red("Error: Cannot connect to the Foreman daemon.") +
        chalk.dim("\n  Make sure the daemon is running: foreman daemon start"),
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
  .description("Register a project via ForemanDaemon")
  .argument("<path>", "Path to the project root")
  .option("--name <name>", "Project name (default: directory basename)")
  .option("--github-url <url>", "GitHub repository URL")
  .option("--default-branch <branch>", "Default git branch", "main")
  .action(async (projectPath: string, opts) => {
    const resolvedPath = resolve(projectPath);
    const name = opts.name ?? resolvedPath.split("/").pop() ?? resolvedPath;
    const client = getClient();

    try {
      const result = await client.projects.add({
        name,
        path: resolvedPath,
        githubUrl: opts.githubUrl,
        defaultBranch: opts.defaultBranch,
      });
      console.log(chalk.green(`✓ Project '${name}' created: ${(result as { id: string }).id}`));
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
    const client = getClient();

    try {
      const result = await client.projects.list({
        status: opts.status as "active" | "paused" | "archived" | undefined,
        search: opts.search,
      });

      const projects = result as ProjectRow[];

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
    const client = getClient();

    try {
      await client.projects.remove({
        id: projectId,
        force: opts.force,
      });
      console.log(chalk.green(`✓ Project '${projectId}' removed.`));
    } catch (err) {
      handleDaemonError(err);
    }
  });

// ---------------------------------------------------------------------------
// Parent command
// ---------------------------------------------------------------------------

export const projectCommand = new Command("project")
  .description("Manage projects via ForemanDaemon (list/add/remove)")
  .addCommand(addCommand)
  .addCommand(listCommand)
  .addCommand(removeCommand);
