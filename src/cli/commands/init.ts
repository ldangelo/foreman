import { Command } from "commander";
import chalk from "chalk";
import ora from "ora";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { basename, join, resolve } from "node:path";

import { homedir } from "node:os";
import { ForemanStore } from "../../lib/store.js";
import { installBundledPrompts, installBundledSkills } from "../../lib/prompt-loader.js";

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

// ── Store init logic ──────────────────────────────────────────────────────

/**
 * Register project and seed default sentinel config if not already present.
 * Exported for unit testing.
 */
export async function initProjectStore(
  projectDir: string,
  projectName: string,
  store: ForemanStore,
): Promise<void> {
  let projectId: string;
  const existing = store.getProjectByPath(projectDir);
  if (existing) {
    console.log(chalk.dim(`Project already registered (${existing.id})`));
    projectId = existing.id;
  } else {
    const project = store.registerProject(projectName, projectDir);
    console.log(chalk.dim(`Registered in store: ${project.id}`));
    projectId = project.id;
  }

  // Seed default sentinel config only on first init
  if (!store.getSentinelConfig(projectId)) {
    store.upsertSentinelConfig(projectId, {
      branch: "main",
      test_command: "npm test",
      interval_minutes: 30,
      failure_threshold: 2,
      enabled: 1,
    });
    console.log(chalk.dim("  Sentinel: enabled (npm test every 30m on main)"));
  }

}

// ── Command ────────────────────────────────────────────────────────────────

/**
 * Install bundled prompt templates to <projectDir>/.foreman/prompts/.
 * Exported for unit testing.
 *
 * @param projectDir - Absolute path to the project directory
 * @param force      - Overwrite existing prompt files
 */
export function installPrompts(
  projectDir: string,
  force: boolean = false,
): { installed: string[]; skipped: string[] } {
  return installBundledPrompts(projectDir, force);
}

export const initCommand = new Command("init")
  .description("Initialize foreman in a project")
  .option("-n, --name <name>", "Project name (defaults to directory name)")
  .option("--force", "Overwrite existing prompt files when reinstalling")
  .action(async (opts) => {
    const projectDir = resolve(".");
    const projectName = opts.name ?? basename(projectDir);
    const force = (opts.force as boolean | undefined) ?? false;

    console.log(
      chalk.bold(`Initializing foreman project: ${chalk.cyan(projectName)}`),
    );

    // Initialize the task-tracking backend
    await initBackend({ projectDir });

    // Register project and seed sentinel config
    const store = ForemanStore.forProject(projectDir);
    await initProjectStore(projectDir, projectName, store);
    store.close();

    // Install bundled prompt templates to .foreman/prompts/
    const spinner = ora("Installing prompt templates...").start();
    try {
      const { installed, skipped } = installPrompts(projectDir, force);
      if (installed.length > 0) {
        spinner.succeed(
          `Installed ${installed.length} prompt template(s) to .foreman/prompts/`,
        );
      } else if (skipped.length > 0) {
        spinner.info(
          `Prompt templates already installed (${skipped.length} skipped). Use --force to overwrite.`,
        );
      } else {
        spinner.succeed("Prompt templates installed");
      }
    } catch (e) {
      spinner.fail("Failed to install prompt templates");
      console.error(chalk.red(e instanceof Error ? e.message : String(e)));
      process.exit(1);
    }

    // Install bundled Pi skills to ~/.pi/agent/skills/
    const skillSpinner = ora("Installing Pi skills...").start();
    try {
      const { installed: skillsInstalled } = installBundledSkills();
      if (skillsInstalled.length > 0) {
        skillSpinner.succeed(
          `Installed ${skillsInstalled.length} Pi skill(s) to ~/.pi/agent/skills/`,
        );
      } else {
        skillSpinner.succeed("Pi skills up to date");
      }
    } catch (e) {
      skillSpinner.warn(`Failed to install Pi skills: ${e instanceof Error ? e.message : String(e)}`);
    }

    console.log();
    console.log(chalk.green("Foreman initialized successfully!"));
    console.log(chalk.dim(`  Project: ${projectName}`));
    console.log(chalk.dim(`  Path:    ${projectDir}`));
  });
