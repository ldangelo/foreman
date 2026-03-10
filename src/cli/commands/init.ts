import { Command } from "commander";
import chalk from "chalk";
import ora from "ora";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { basename, resolve } from "node:path";

export const initCommand = new Command("init")
  .description("Initialize foreman in a project")
  .option("-n, --name <name>", "Project name (defaults to directory name)")
  .action(async (opts) => {
    const projectDir = resolve(".");
    const projectName = opts.name ?? basename(projectDir);

    console.log(
      chalk.bold(`Initializing foreman project: ${chalk.cyan(projectName)}`),
    );

    // Check if bd (beads) is installed
    try {
      execFileSync("bd", ["--version"], { stdio: "pipe" });
    } catch {
      console.error(
        chalk.red("Error: bd (beads) CLI is not installed or not in PATH."),
      );
      console.error(
        chalk.dim("Install beads first: https://github.com/beads-project/bd"),
      );
      process.exit(1);
    }

    // Initialize beads if .beads doesn't exist
    if (!existsSync(".beads")) {
      const spinner = ora("Initializing beads workspace...").start();
      try {
        execFileSync("bd", ["init"], { stdio: "pipe" });
        spinner.succeed("Beads workspace initialized");
      } catch (e) {
        spinner.fail("Failed to initialize beads workspace");
        console.error(
          chalk.red(e instanceof Error ? e.message : String(e)),
        );
        process.exit(1);
      }
    } else {
      console.log(chalk.dim("Beads workspace already exists, skipping init"));
    }

    // TODO: Register project in state store
    // import { registerProject } from '../../lib/store.js';
    // await registerProject({ name: projectName, path: projectDir });

    console.log();
    console.log(chalk.green("Foreman initialized successfully!"));
    console.log(chalk.dim(`  Project: ${projectName}`));
    console.log(chalk.dim(`  Path:    ${projectDir}`));
  });
