import { Command } from "commander";
import chalk from "chalk";
import ora from "ora";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { homedir } from "node:os";
import { ForemanStore } from "../../lib/store.js";

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
 * TRD-024: sd backend removed. Always uses the br (beads_rust) backend.
 *   - Skips sd installation check and sd init entirely.
 *   - Runs `br init` if .beads/ does not already exist.
 *
 * Exported for unit testing.
 */
export async function initBackend(opts: InitBackendOpts): Promise<void> {
  const { projectDir, execSync = execFileSync, checkExists = existsSync } = opts;

  // br backend: initialize .beads if needed
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
    const store = ForemanStore.forProject(projectDir);
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
