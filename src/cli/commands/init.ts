import { Command } from "commander";
import chalk from "chalk";
import ora from "ora";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync, copyFileSync, readdirSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
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

// ── Default config seeding (TRD-019) ──────────────────────────────────────

/**
 * Injectable filesystem operations for initDefaultConfigs — enables testing
 * with temp directories without mocking ESM modules.
 */
export interface InitDefaultConfigsOpts {
  /** Override for ~/.foreman path (defaults to homedir() + "/.foreman"). */
  foremanHomeDir?: string;
  /** Injectable existsSync (defaults to node:fs existsSync). */
  checkExists?: (p: string) => boolean;
  /** Injectable mkdirSync (defaults to node:fs mkdirSync). */
  mkdirSyncFn?: (p: string, opts?: { recursive?: boolean }) => string | undefined;
  /** Injectable copyFileSync (defaults to node:fs copyFileSync). */
  copyFileSyncFn?: (src: string, dest: string) => void;
  /** Injectable readdirSync (defaults to node:fs readdirSync). */
  readdirSyncFn?: (p: string) => string[];
  /** Bundled defaults directory path override (for testing). */
  defaultsDir?: string;
}

/**
 * Resolve the bundled defaults directory path relative to this module's location.
 *
 * In the compiled output (dist/), this file is at:
 *   dist/cli/commands/init.js
 * The defaults are at:
 *   dist/defaults/
 *
 * In the source tree (src/), this file is at:
 *   src/cli/commands/init.ts
 * The defaults are at:
 *   src/defaults/
 *
 * We resolve two levels up from this file's directory to reach the package root,
 * then descend into "defaults/".
 */
function resolveDefaultsDir(): string {
  const thisFile = fileURLToPath(import.meta.url);
  const thisDir = dirname(thisFile);
  // thisDir = .../src/cli/commands (or .../dist/cli/commands)
  // go up two levels → package root (src/ or dist/)
  return join(thisDir, "..", "..", "defaults");
}

/**
 * Seed ~/.foreman/ with bundled default configuration files on first run.
 *
 * For each file:
 *   - If the destination does NOT exist: copy it and print a confirmation.
 *   - If the destination already exists: skip it (preserve user customizations)
 *     and print a dim "already present" message.
 *
 * Files seeded:
 *   - ~/.foreman/phases.json      (from src/defaults/phases.json)
 *   - ~/.foreman/workflows.json   (from src/defaults/workflows.json)
 *   - ~/.foreman/prompts/*.md     (from src/defaults/prompts/*.md)
 *
 * Satisfies: REQ-013, AC-013-1 through AC-013-5
 *
 * Exported for unit testing.
 */
export function initDefaultConfigs(opts: InitDefaultConfigsOpts = {}): void {
  const {
    foremanHomeDir = join(homedir(), ".foreman"),
    checkExists = existsSync,
    mkdirSyncFn = (p, o) => mkdirSync(p, o),
    copyFileSyncFn = copyFileSync,
    readdirSyncFn = (p) => readdirSync(p) as string[],
    defaultsDir = resolveDefaultsDir(),
  } = opts;

  // Ensure ~/.foreman/ directory exists
  if (!checkExists(foremanHomeDir)) {
    mkdirSyncFn(foremanHomeDir, { recursive: true });
  }

  // ── phases.json ─────────────────────────────────────────────────────────
  const phasesSrc = join(defaultsDir, "phases.json");
  const phasesDest = join(foremanHomeDir, "phases.json");
  if (checkExists(phasesDest)) {
    console.log(chalk.dim("  Config: phases.json already present — skipping"));
  } else {
    try {
      copyFileSyncFn(phasesSrc, phasesDest);
      console.log(chalk.dim("  Config: phases.json written to ~/.foreman/phases.json"));
    } catch (e) {
      console.warn(chalk.yellow(`  Config: could not write phases.json (non-fatal): ${e instanceof Error ? e.message : String(e)}`));
    }
  }

  // ── workflows.json ───────────────────────────────────────────────────────
  const workflowsSrc = join(defaultsDir, "workflows.json");
  const workflowsDest = join(foremanHomeDir, "workflows.json");
  if (checkExists(workflowsDest)) {
    console.log(chalk.dim("  Config: workflows.json already present — skipping"));
  } else {
    try {
      copyFileSyncFn(workflowsSrc, workflowsDest);
      console.log(chalk.dim("  Config: workflows.json written to ~/.foreman/workflows.json"));
    } catch (e) {
      console.warn(chalk.yellow(`  Config: could not write workflows.json (non-fatal): ${e instanceof Error ? e.message : String(e)}`));
    }
  }

  // ── prompts/*.md ─────────────────────────────────────────────────────────
  const promptsSrc = join(defaultsDir, "prompts");
  const promptsDest = join(foremanHomeDir, "prompts");

  if (!checkExists(promptsDest)) {
    mkdirSyncFn(promptsDest, { recursive: true });
  }

  let promptFiles: string[];
  try {
    promptFiles = readdirSyncFn(promptsSrc).filter((f) => f.endsWith(".md"));
  } catch (e) {
    console.warn(chalk.yellow(`  Config: could not read bundled prompts directory (non-fatal): ${e instanceof Error ? e.message : String(e)}`));
    return;
  }

  for (const filename of promptFiles) {
    const src = join(promptsSrc, filename);
    const dest = join(promptsDest, filename);
    if (checkExists(dest)) {
      console.log(chalk.dim(`  Config: prompts/${filename} already present — skipping`));
    } else {
      try {
        copyFileSyncFn(src, dest);
        console.log(chalk.dim(`  Config: prompts/${filename} written to ~/.foreman/prompts/${filename}`));
      } catch (e) {
        console.warn(chalk.yellow(`  Config: could not write prompts/${filename} (non-fatal): ${e instanceof Error ? e.message : String(e)}`));
      }
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

    // Initialize the task-tracking backend
    await initBackend({ projectDir });

    // Write default Agent Mail config (.foreman/agent-mail.json) if missing
    initAgentMailConfig(projectDir);

    // TRD-019: Seed ~/.foreman/ with bundled default configs on first run (REQ-013)
    initDefaultConfigs();

    // Register project and seed sentinel config
    const store = ForemanStore.forProject(projectDir);
    await initProjectStore(projectDir, projectName, store);
    store.close();

    console.log();
    console.log(chalk.green("Foreman initialized successfully!"));
    console.log(chalk.dim(`  Project: ${projectName}`));
    console.log(chalk.dim(`  Path:    ${projectDir}`));
  });
