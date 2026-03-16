import { Command } from "commander";
import chalk from "chalk";
import ora from "ora";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { homedir } from "node:os";
import { ForemanStore } from "../../lib/store.js";
import { getTaskBackend } from "../../lib/feature-flags.js";

// ── Backend-specific init logic (TRD-018) ─────────────────────────────────

/**
 * Options bag for initBackend — injectable for testing.
 */
export interface InitBackendOpts {
  /** Directory containing the project (.seeds / .beads live here). */
  projectDir: string;
  execSync?: typeof execFileSync;
  checkExists?: (path: string) => boolean;
}

/**
 * Initialize the task-tracking backend for the given project directory.
 *
 * When FOREMAN_TASK_BACKEND='br':
 *   - Skips sd installation check and sd init entirely.
 *   - Runs `br init` if .beads/ does not already exist.
 *
 * When FOREMAN_TASK_BACKEND='sd' (default):
 *   - Checks that sd binary is installed.
 *   - Runs `sd init` if .seeds/ does not already exist.
 *
 * Exported for unit testing.
 */
export async function initBackend(opts: InitBackendOpts): Promise<void> {
  const { projectDir, execSync = execFileSync, checkExists = existsSync } = opts;
  const backend = getTaskBackend();

  if (backend === "br") {
    // br backend: skip sd entirely, initialize .beads if needed
    const brPath = join(homedir(), ".local", "bin", "br");

    if (!checkExists(join(projectDir, ".beads"))) {
      const spinner = ora("Initializing beads workspace...").start();
      try {
        execSync(brPath, ["init"], { stdio: "pipe" });
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
  } else {
    // sd backend (default): check sd binary and initialize .seeds if needed
    const sdPath = join(process.env.HOME ?? "~", ".bun", "bin", "sd");

    try {
      execSync(sdPath, ["--version"], { stdio: "pipe" });
    } catch {
      console.error(
        chalk.red("Error: sd (seeds) CLI is not installed."),
      );
      console.error(
        chalk.dim("Install: bun install -g @os-eco/seeds-cli"),
      );
      process.exit(1);
    }

    if (!checkExists(join(projectDir, ".seeds"))) {
      const spinner = ora("Initializing seeds workspace...").start();
      try {
        execSync(sdPath, ["init"], { stdio: "pipe" });
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
  }
}

// ── Command ────────────────────────────────────────────────────────────────

export const initCommand = new Command("init")
  .description("Initialize foreman in a project")
  .option("-n, --name <name>", "Project name (defaults to directory name)")
  .action(async (opts) => {
    const projectDir = resolve(".");
    const projectName = opts.name ?? basename(projectDir);

    console.log(
      chalk.bold(`Initializing foreman project: ${chalk.cyan(projectName)}`),
    );

    // Initialize the task-tracking backend (sd or br depending on env)
    await initBackend({ projectDir });

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
