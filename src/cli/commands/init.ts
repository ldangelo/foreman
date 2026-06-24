import { Command } from "commander";
import chalk from "chalk";
import ora from "ora";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";
import { basename, join, resolve } from "node:path";

import { homedir } from "node:os";
import { ForemanStore } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import { PostgresAdapter } from "../../lib/db/postgres-adapter.js";
import { ProjectRegistry } from "../../lib/project-registry.js";
import { installBundledPrompts, installBundledSkills } from "../../lib/prompt-loader.js";
import { installBundledWorkflows, BUNDLED_WORKFLOW_NAMES } from "../../lib/workflow-loader.js";
import { installBundledActions } from "../../orchestrator/action-loader.js";
import { DatabaseConfigError, DatabaseError } from "../../lib/db/pool-manager.js";
import { ensureCliPostgresPool } from "./project-task-support.js";
import { encrypt } from "../../lib/encryption.js";

type Awaitable<T> = T | Promise<T>;

interface InitProjectStore {
  getProjectByPath: (path: string) => Awaitable<{ id: string } | null>;
  registerProject: (name: string, path: string) => Awaitable<{ id: string }>;
  getSentinelConfig: (projectId: string) => Awaitable<ReturnType<ForemanStore["getSentinelConfig"]>>;
  upsertSentinelConfig: (
    projectId: string,
    config: Parameters<ForemanStore["upsertSentinelConfig"]>[1],
  ) => Awaitable<void>;
}

// ── Backend-specific init logic (TRD-018) ─────────────────────────────────

/**
 * Options bag for initBackend — injectable for testing.
 */
export interface InitBackendOpts {
  /** Directory containing the project (.seeds / .beads live here). */
  projectDir: string;
  /** The issue tracker selected in the wizard (beads/jira/github). */
  issueTracker: "beads" | "jira" | "github";
  execSync?: typeof execFileSync;
  checkExists?: (path: string) => boolean;
}

/**
 * Initialize the task-tracking backend for the given project directory.
 *
 * TRD-024: Native Postgres task store is the only supported backend.
 * Foreman no longer uses beads (br) for task tracking — it writes directly
 * to the native Postgres store. The .beads/ directory is initialized here for
 * backwards compatibility (operators may still use br directly outside foreman).
 *
 * br init is only run when the user selected "beads" as their issue tracker.
 * For jira/github, beads is not used and initialization is skipped.
 *
 * Exported for unit testing.
 */
export async function initBackend(opts: InitBackendOpts): Promise<void> {
  const { projectDir, issueTracker, execSync = execFileSync, checkExists = existsSync } = opts;

  // Initialize .beads/ for backwards compatibility only when beads is the issue tracker
  // For jira/github, foreman writes directly to Postgres — no beads needed
  if (issueTracker !== "beads") {
    console.log(chalk.dim(`Skipping beads init (${issueTracker} tracker selected)`));
    return;
  }

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
  store: InitProjectStore,
): Promise<void> {
  let projectId: string;
  const existing = await store.getProjectByPath(projectDir);
  if (existing) {
    console.log(chalk.dim(`Project already registered (${existing.id})`));
    projectId = existing.id;
  } else {
    const project = await store.registerProject(projectName, projectDir);
    console.log(chalk.dim(`Registered in store: ${project.id}`));
    projectId = project.id;
  }

  // Seed default sentinel config only on first init
  if (!(await store.getSentinelConfig(projectId))) {
    await store.upsertSentinelConfig(projectId, {
      branch: "main",
      test_command: "npm test",
      interval_minutes: 30,
      failure_threshold: 2,
      enabled: 1,
    });
    console.log(chalk.dim("  Sentinel: enabled (npm test every 30m on main)"));
  }
}

// ── Init wizard ─────────────────────────────────────────────────────────────

export interface JiraWizardConfig {
  apiUrl: string;
  email: string;
  apiToken: string;
  projectKey: string;
  startStatus: string[];
}

export interface GitHubWizardConfig {
  apiUrl: string;
  token: string;
  owner: string;
  repo: string;
  triggerLabels: string[];
}

export interface InitWizardAnswers {
  vcsBackend: "git" | "jujutsu" | "auto";
  workflowTemplate: string;
  issueTracker: "beads" | "jira" | "github";
  jira?: JiraWizardConfig;
  github?: GitHubWizardConfig;
}

export function buildInitWizardConfig(answers: InitWizardAnswers): string {
  // Use taskTypeWorkflowMap (ProjectConfig schema) instead of non-standard init: block
  const lines = [
    "# Generated by foreman init",
    "vcs:",
    `  backend: ${answers.vcsBackend}`,
    "",
    "# Default workflow for task type",
    "taskTypeWorkflowMap:",
    `  default: ${answers.workflowTemplate}`,
    "",
  ];

  // Add issue tracker configuration if jira is selected
  if (answers.issueTracker === "jira" && answers.jira) {
    lines.push("issueTracker:", "  backend: jira", "  jira:", `    apiUrl: ${answers.jira.apiUrl}`, `    email: ${answers.jira.email}`, `    apiToken: ${answers.jira.apiToken}`, "    projects:", "      - key: " + answers.jira.projectKey.toUpperCase(), "        startStatus:", ...answers.jira.startStatus.map((s) => "          - " + s), "        issueTypeWorkflowMap:", "          bug: bug", "          task: task", "          feature: feature");
  }

  // Add issue tracker configuration if github is selected
  if (answers.issueTracker === "github" && answers.github) {
    lines.push("issueTracker:", "  backend: github", "  github:", `    apiUrl: ${answers.github.apiUrl}`, `    token: ${answers.github.token}`, "    repositories:", "      - owner: " + answers.github.owner, "        repo: " + answers.github.repo, "        triggerLabels:", ...answers.github.triggerLabels.map((l) => "          - " + l));
  }

  return lines.join("\n");
}

async function promptChoice<T extends string>(rl: ReturnType<typeof createInterface>, label: string, choices: readonly T[], fallback: T): Promise<T> {
  const answer = (await rl.question(`${label} (${choices.join("/")}) [${fallback}]: `)).trim().toLowerCase();
  return choices.includes(answer as T) ? (answer as T) : fallback;
}

async function promptText(rl: ReturnType<typeof createInterface>, label: string, fallback: string): Promise<string> {
  const answer = (await rl.question(`${label} [${fallback}]: `)).trim();
  return answer || fallback;
}

async function promptJiraAuth(rl: ReturnType<typeof createInterface>): Promise<JiraWizardConfig> {
  const apiUrl = await promptText(rl, "  Jira API URL (e.g. https://your-domain.atlassian.net)", "https://your-domain.atlassian.net");
  const email = await promptText(rl, "  Jira account email", "");
  const apiToken = await rl.question("  Jira API token (will be encrypted): ");
  const projectKey = await promptText(rl, "  Jira project key (e.g. PROJ)", "");
  const startStatusStr = await promptText(rl, "  Start status (comma-separated, e.g. In Progress,To Do)", "In Progress");
  const startStatus = startStatusStr.split(",").map((s) => s.trim()).filter((s) => s);

  return { apiUrl, email, apiToken, projectKey, startStatus };
}

async function promptGitHubAuth(rl: ReturnType<typeof createInterface>): Promise<GitHubWizardConfig> {
  const apiUrl = await promptText(rl, "  GitHub API URL (e.g. https://api.github.com for GitHub.com)", "https://api.github.com");
  const token = await rl.question("  GitHub personal access token (will be encrypted): ");
  const owner = await promptText(rl, "  Repository owner (user or org)", "");
  const repo = await promptText(rl, "  Repository name", "");
  const triggerLabelsStr = await promptText(rl, "  Trigger labels (comma-separated, e.g. foreman,fixme)", "foreman");
  const triggerLabels = triggerLabelsStr.split(",").map((s) => s.trim()).filter((s) => s);

  return { apiUrl, token, owner, repo, triggerLabels };
}

async function runInitWizard(projectDir: string): Promise<InitWizardAnswers> {
  const rl = createInterface({ input, output });
  try {
    const vcsBackend = await promptChoice(rl, "VCS backend", ["git", "jujutsu", "auto"] as const, "auto");

    // Get all available workflow templates from BUNDLED_WORKFLOW_NAMES
    const workflowChoices = [...BUNDLED_WORKFLOW_NAMES] as const;
    const workflowTemplate = await promptChoice(rl, "Workflow template", workflowChoices, "default");

    const issueTracker = await promptChoice(rl, "Issue tracker", ["beads", "jira", "github"] as const, "beads");

    let jira: JiraWizardConfig | undefined;
    if (issueTracker === "jira") {
      console.log(chalk.dim("\n  Jira configuration:"));
      jira = await promptJiraAuth(rl);
      // Encrypt the API token before storing
      // Fail fast if FOREMAN_MASTER_KEY is not set — do not store plaintext jira.apiToken
      try {
        jira.apiToken = await encrypt(jira.apiToken);
      } catch (err) {
        const msg =
          err instanceof Error && err.message.includes("FOREMAN_MASTER_KEY")
            ? err.message
            : `Failed to encrypt jira.apiToken via encrypt(). ` +
              `Set FOREMAN_MASTER_KEY environment variable and re-run init. ` +
              `Generate a key with: openssl rand -base64 32`;
        console.error(chalk.red(`\n  Error: ${msg}`));
        process.exit(1);
      }
    }

    let github: GitHubWizardConfig | undefined;
    if (issueTracker === "github") {
      console.log(chalk.dim("\n  GitHub configuration:"));
      github = await promptGitHubAuth(rl);
      // Encrypt the token before storing
      // Fail fast if FOREMAN_MASTER_KEY is not set — do not store plaintext github.token
      try {
        github.token = await encrypt(github.token);
      } catch (err) {
        const msg =
          err instanceof Error && err.message.includes("FOREMAN_MASTER_KEY")
            ? err.message
            : `Failed to encrypt github.token via encrypt(). ` +
              `Set FOREMAN_MASTER_KEY environment variable and re-run init. ` +
              `Generate a key with: openssl rand -base64 32`;
        console.error(chalk.red(`\n  Error: ${msg}`));
        process.exit(1);
      }
    }

    const answers: InitWizardAnswers = {
      vcsBackend,
      workflowTemplate,
      issueTracker,
      jira,
      github,
    };

    mkdirSync(join(projectDir, ".foreman"), { recursive: true });
    writeFileSync(join(projectDir, ".foreman", "config.yaml"), buildInitWizardConfig(answers), "utf8");
    return answers;
  } finally {
    rl.close();
  }
}

export function formatInitDatabaseError(err: unknown, projectDir: string): string {
  const intro = "Failed to initialize the Postgres-backed project registry.";
  const fix = `Set DATABASE_URL in ${join(projectDir, ".env")} or your environment to a full Postgres URL like postgresql://user:password@host:5432/database.`;

  if (err instanceof DatabaseConfigError) {
    return `${intro}\n${err.message}\n${fix}`;
  }

  if (err instanceof DatabaseError && err.message.includes("client password must be a string")) {
    return `${intro}\nDATABASE_URL is missing a password for the configured Postgres user.\n${fix}`;
  }

  if (err instanceof Error) {
    return `${intro}\n${err.message}`;
  }

  return `${intro}\n${String(err)}`;
}

// ── Command ────────────────────────────────────────────────────────────────

/**
 * Install bundled prompt templates to ~/.foreman/prompts/.
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
  .option("--wizard", "Run an interactive setup wizard and write .foreman/config.yaml")
  .action(async (opts) => {
    const projectDir = resolve(".");
    const projectName = opts.name ?? basename(projectDir);
    const force = (opts.force as boolean | undefined) ?? false;
    const wizard = (opts.wizard as boolean | undefined) ?? true;

    console.log(
      chalk.bold(`Initializing foreman project: ${chalk.cyan(projectName)}`),
    );

    let issueTracker: "beads" | "jira" | "github" = "beads";

    if (wizard) {
      const answers = await runInitWizard(projectDir);
      console.log(chalk.dim(`  VCS: ${answers.vcsBackend}`));
      console.log(chalk.dim(`  Workflow: ${answers.workflowTemplate}`));
      console.log(chalk.dim(`  Issue tracker: ${answers.issueTracker}`));
      if (answers.issueTracker === "jira" && answers.jira) {
        console.log(chalk.dim(`  Jira: ${answers.jira.email}@${answers.jira.apiUrl}`));
        console.log(chalk.dim(`  Jira project: ${answers.jira.projectKey}`));
      }
      issueTracker = answers.issueTracker;
    }

    // Initialize the task-tracking backend
    // issueTracker comes from wizard answers (or defaults to "beads" if wizard skipped)
    await initBackend({ projectDir, issueTracker });

    let store: PostgresStore | null = null;
    try {
      // Register project and seed sentinel config
      ensureCliPostgresPool(projectDir);
      const registry = new ProjectRegistry({ pg: new PostgresAdapter() });
      let project = (await registry.list()).find((record) => record.path === projectDir || record.name === projectName);
      if (!project) {
        project = await registry.add({ name: projectName, path: projectDir, status: "active" });
      }
      store = PostgresStore.forProject(project.id);
      await initProjectStore(projectDir, projectName, {
        getProjectByPath: async (path: string) => (path === projectDir ? { id: project.id } : null),
        registerProject: async () => ({ id: project.id }),
        getSentinelConfig: async (projectId: string) => store!.getSentinelConfig(projectId),
        upsertSentinelConfig: async (projectId: string, config) => store!.upsertSentinelConfig(projectId, config),
      });
    } catch (err) {
      console.error(chalk.red(formatInitDatabaseError(err, projectDir)));
      process.exit(1);
    } finally {
      store?.close();
    }

    // Install bundled prompt templates to .foreman/prompts/
    const spinner = ora("Installing prompt templates...").start();
    try {
      const { installed, skipped } = installPrompts(projectDir, force);
      if (installed.length > 0) {
        spinner.succeed(
          `Installed ${installed.length} prompt template(s) to ~/.foreman/prompts/`,
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

    // Install bundled workflow configs to ~/.foreman/workflows/
    const workflowSpinner = ora("Installing workflow configs...").start();
    try {
      const { installed: workflowsInstalled, skipped: workflowsSkipped } = installBundledWorkflows(projectDir, force);
      if (workflowsInstalled.length > 0) {
        workflowSpinner.succeed(
          `Installed ${workflowsInstalled.length} workflow config(s) to ~/.foreman/workflows/`,
        );
      } else if (workflowsSkipped.length > 0) {
        workflowSpinner.info(
          `Workflow configs already installed (${workflowsSkipped.length} skipped). Use --force to overwrite.`,
        );
      } else {
        workflowSpinner.succeed("Workflow configs installed");
      }
    } catch (e) {
      workflowSpinner.warn(`Failed to install workflow configs: ${e instanceof Error ? e.message : String(e)}`);
    }

    // Install editable project action stubs to .foreman/actions/
    const actionSpinner = ora("Installing action modules...").start();
    try {
      const { installed: actionsInstalled, skipped: actionsSkipped } = installBundledActions(projectDir, force);
      if (actionsInstalled.length > 0) {
        actionSpinner.succeed(`Installed ${actionsInstalled.length} action module(s) to .foreman/actions/`);
      } else if (actionsSkipped.length > 0) {
        actionSpinner.info(`Action modules already installed (${actionsSkipped.length} skipped). Use --force to overwrite.`);
      } else {
        actionSpinner.succeed("Action modules installed");
      }
    } catch (e) {
      actionSpinner.warn(`Failed to install action modules: ${e instanceof Error ? e.message : String(e)}`);
    }

    console.log();
    console.log(chalk.green("Foreman initialized successfully!"));
    console.log(chalk.dim(`  Project: ${projectName}`));
    console.log(chalk.dim(`  Path:    ${projectDir}`));
  });
