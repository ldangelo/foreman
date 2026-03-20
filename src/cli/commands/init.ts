import { Command } from "commander";
import chalk from "chalk";
import ora from "ora";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { homedir } from "node:os";
import { ForemanStore } from "../../lib/store.js";
import { AgentMailClient } from "../../orchestrator/agent-mail-client.js";
import { MERGE_AGENT_MAILBOX } from "../../orchestrator/merge-agent.js";

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

// ── Agent Mail config init (AC-014-1) ─────────────────────────────────────

/**
 * Write a default agent-mail.json to .foreman/ if it does not already exist.
 * AC-014-1: Given `foreman init`, when the project is initialized, then the
 * Agent Mail server configuration is stored in .foreman/agent-mail.json.
 *
 * Exported for unit testing.
 */
export function initAgentMailConfig(
  projectDir: string,
  opts: { checkExists?: (path: string) => boolean; mkdirSyncFn?: typeof mkdirSync; writeFileSyncFn?: typeof writeFileSync } = {},
): void {
  const checkExists = opts.checkExists ?? existsSync;
  const mkdirSyncFn = opts.mkdirSyncFn ?? mkdirSync;
  const writeFileSyncFn = opts.writeFileSyncFn ?? writeFileSync;

  const foremanDir = join(projectDir, ".foreman");
  const configPath = join(foremanDir, "agent-mail.json");

  if (checkExists(configPath)) {
    // Already present — leave untouched
    return;
  }

  try {
    if (!checkExists(foremanDir)) {
      mkdirSyncFn(foremanDir, { recursive: true });
    }
    const defaultConfig = { url: "http://localhost:8765", enabled: true };
    writeFileSyncFn(configPath, JSON.stringify(defaultConfig, null, 2) + "\n", "utf-8");
    console.log(chalk.dim("  Agent Mail: default config written (.foreman/agent-mail.json)"));
  } catch (e) {
    // Non-fatal — agent-mail.json is optional (AgentMailClient falls back to env vars / defaults)
    console.warn(chalk.yellow(`  Agent Mail: could not write config (non-fatal): ${e instanceof Error ? e.message : String(e)}`));
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

  // Seed default merge agent config only on first init
  if (!store.getMergeAgentConfig()) {
    store.setMergeAgentConfig({ enabled: 1, poll_interval_ms: 30_000 });
    console.log(chalk.dim("  Merge Agent: enabled (polling every 30s)"));
  }

  // Register the "refinery" Agent Mail mailbox so MergeAgent can receive messages.
  // Non-fatal — Agent Mail server may not be running at init time.
  try {
    const agentMail = new AgentMailClient();
    const healthy = await agentMail.healthCheck();
    if (healthy) {
      await agentMail.ensureProject(projectDir);
      await agentMail.registerAgent(MERGE_AGENT_MAILBOX);
      console.log(chalk.dim(`  Agent Mail: registered "${MERGE_AGENT_MAILBOX}" mailbox`));
    }
  } catch {
    // Non-fatal — Agent Mail registration will be retried when merge-agent starts
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

    // Initialize the task-tracking backend
    await initBackend({ projectDir });

    // Write default Agent Mail config (.foreman/agent-mail.json) if missing
    initAgentMailConfig(projectDir);

    // Register project and seed sentinel config
    const store = ForemanStore.forProject(projectDir);
    await initProjectStore(projectDir, projectName, store);
    store.close();

    console.log();
    console.log(chalk.green("Foreman initialized successfully!"));
    console.log(chalk.dim(`  Project: ${projectName}`));
    console.log(chalk.dim(`  Path:    ${projectDir}`));
  });
