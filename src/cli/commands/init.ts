import { Command } from "commander";
import chalk from "chalk";
import ora from "ora";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { ForemanStore } from "../../lib/store.js";

export const initCommand = new Command("init")
  .description("Initialize foreman in a project")
  .option("-n, --name <name>", "Project name (defaults to directory name)")
  .action(async (opts) => {
    const projectDir = resolve(".");
    const projectName = opts.name ?? basename(projectDir);

    console.log(
      chalk.bold(`Initializing foreman project: ${chalk.cyan(projectName)}`),
    );

    // Check if sd (seeds) is installed
    const sdPath = join(process.env.HOME ?? "~", ".bun", "bin", "sd");
    try {
      execFileSync(sdPath, ["--version"], { stdio: "pipe" });
    } catch {
      console.error(
        chalk.red("Error: sd (seeds) CLI is not installed."),
      );
      console.error(
        chalk.dim("Install: bun install -g @os-eco/seeds-cli"),
      );
      process.exit(1);
    }

    // Initialize seeds if .seeds doesn't exist
    if (!existsSync(".seeds")) {
      const spinner = ora("Initializing seeds workspace...").start();
      try {
        execFileSync(sdPath, ["init"], { stdio: "pipe" });
        spinner.succeed("Seeds workspace initialized");
      } catch (e) {
        spinner.fail("Failed to initialize seeds workspace");
        console.error(
          chalk.red(e instanceof Error ? e.message : String(e)),
        );
        process.exit(1);
      }
    } else {
      console.log(chalk.dim("Seeds workspace already exists, skipping init"));
    }

    // Register project in state store
    const store = new ForemanStore();
    const existing = store.getProjectByPath(projectDir);
    if (existing) {
      console.log(chalk.dim(`Project already registered (${existing.id})`));
    } else {
      const project = store.registerProject(projectName, projectDir);
      console.log(chalk.dim(`Registered in store: ${project.id}`));
    }
    store.close();

    console.log();
    console.log(chalk.green("Foreman initialized successfully!"));
    console.log(chalk.dim(`  Project: ${projectName}`));
    console.log(chalk.dim(`  Path:    ${projectDir}`));
  });
