/**
 * `foreman project` CLI commands — manage the global project registry.
 *
 * Sub-commands:
 *   foreman project add <path> [--name <alias>] [--force]
 *   foreman project list [--stale]
 *   foreman project remove <name> [--force] [--stale]
 *
 * @module src/cli/commands/project
 */

import { Command } from "commander";
import chalk from "chalk";
import { resolve } from "node:path";
import {
  ProjectRegistry,
  DuplicateProjectError,
  ProjectNotFoundError,
  type ProjectEntry,
} from "../../lib/project-registry.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Column widths for the project table. */
const COL_NAME = 24;
const COL_PATH = 50;
const COL_STATUS = 12;

function pad(str: string, width: number): string {
  return str.length >= width ? str.slice(0, width - 1) + "…" : str.padEnd(width);
}

function printProjectTable(projects: ProjectEntry[], label?: string): void {
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
      chalk.bold(pad("PATH", COL_PATH)) +
      chalk.bold(pad("ADDED", COL_STATUS)),
  );
  console.log("─".repeat(COL_NAME + COL_PATH + COL_STATUS));

  for (const p of projects) {
    const addedDate = new Date(p.addedAt).toLocaleDateString();
    console.log(
      chalk.cyan(pad(p.name, COL_NAME)) +
        chalk.dim(pad(p.path, COL_PATH)) +
        chalk.dim(pad(addedDate, COL_STATUS)),
    );
  }
}

// ── foreman project add ───────────────────────────────────────────────────────

const addCommand = new Command("add")
  .description("Register a project in the global registry")
  .argument("<path>", "Path to the project root")
  .option("--name <alias>", "Register under this alias (default: directory basename)")
  .option("--force", "Overwrite existing registration with the same name")
  .action(
    async (
      projectPath: string,
      opts: { name?: string; force?: boolean },
    ) => {
      const resolvedPath = resolve(projectPath);
      const registry = new ProjectRegistry();

      try {
        if (opts.force) {
          // If forcing, remove any existing registration with the same name or path first
          const projects = registry.list();
          const targetName = opts.name ?? resolvedPath.split("/").pop() ?? resolvedPath;

          const existingByName = projects.find((p) => p.name === targetName);
          if (existingByName !== undefined) {
            await registry.remove(existingByName.name);
          }

          const existingByPath = registry.list().find((p) => p.path === resolvedPath);
          if (existingByPath !== undefined) {
            await registry.remove(existingByPath.name);
          }
        }

        await registry.add(resolvedPath, opts.name);
        const name = opts.name ?? resolvedPath.split("/").pop() ?? resolvedPath;
        console.log(chalk.green(`✓ Project '${name}' registered at: ${resolvedPath}`));
      } catch (err) {
        if (err instanceof DuplicateProjectError) {
          if (err.field === "name") {
            console.error(
              chalk.red(`Error: Project '${err.value}' is already registered.`) +
                chalk.dim("\n  Use --force to overwrite, or --name to choose a different alias."),
            );
          } else {
            console.error(
              chalk.red(`Error: Path '${err.value}' is already registered as a project.`) +
                chalk.dim("\n  Use --force to overwrite."),
            );
          }
          process.exit(1);
        }
        throw err;
      }
    },
  );

// ── foreman project list ──────────────────────────────────────────────────────

const listCommand = new Command("list")
  .description("List all registered projects")
  .option("--stale", "Show only projects with inaccessible directories")
  .action(async (opts: { stale?: boolean }) => {
    const registry = new ProjectRegistry();

    if (opts.stale) {
      const staleProjects = registry.listStale();
      if (staleProjects.length === 0) {
        console.log(chalk.green("✓ No stale projects found — all registered paths are accessible."));
        return;
      }
      console.log(chalk.yellow(`Found ${staleProjects.length} stale project(s):\n`));
      printProjectTable(staleProjects, "stale");
      console.log(
        chalk.dim("\n  Run 'foreman project remove <name>' or 'foreman project remove --stale' to clean up."),
      );
      return;
    }

    const projects = registry.list();
    if (projects.length === 0) {
      console.log(chalk.dim("No projects registered yet."));
      console.log(chalk.dim("  Run 'foreman project add <path>' to register a project."));
      return;
    }

    console.log(chalk.bold(`\n  Registered Projects (${projects.length})\n`));
    printProjectTable(projects);
    console.log();
  });

// ── foreman project remove ────────────────────────────────────────────────────

const removeCommand = new Command("remove")
  .description("Remove a project from the global registry")
  .argument("[name]", "Project name to remove")
  .option("--force", "Remove even if the project has active agents")
  .option("--stale", "Remove all stale (inaccessible) projects")
  .action(async (name: string | undefined, opts: { force?: boolean; stale?: boolean }) => {
    const registry = new ProjectRegistry();

    // -- Handle --stale: bulk-remove all inaccessible projects
    if (opts.stale) {
      const removed = await registry.removeStale();
      if (removed.length === 0) {
        console.log(chalk.green("✓ No stale projects to remove."));
      } else {
        for (const n of removed) {
          console.log(chalk.yellow(`  ✓ Removed stale project: ${n}`));
        }
        console.log(chalk.green(`\n✓ Removed ${removed.length} stale project(s).`));
      }
      return;
    }

    if (!name) {
      console.error(chalk.red("Error: project name required (or use --stale to remove all stale)."));
      process.exit(1);
    }

    try {
      await registry.remove(name);
      console.log(chalk.green(`✓ Project '${name}' removed from registry.`));
    } catch (err) {
      if (err instanceof ProjectNotFoundError) {
        console.error(chalk.red(`Error: Project '${name}' is not registered.`));
        process.exit(1);
      }
      throw err;
    }
  });

// ── Parent command ────────────────────────────────────────────────────────────

export const projectCommand = new Command("project")
  .description("Manage the global project registry (~/.foreman/projects.json)")
  .addCommand(addCommand)
  .addCommand(listCommand)
  .addCommand(removeCommand);
