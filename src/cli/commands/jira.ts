/**
 * `foreman jira` CLI commands — configure and monitor Jira integration.
 */

import chalk from "chalk";
import { Command } from "commander";
import { createTrpcClient } from "../../lib/trpc-client.js";
import { encrypt } from "../../lib/encryption.js";
import { foremanBackendMode } from "../../lib/backend-mode.js";
import { ElixirServerClient, type ElixirEvent } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { JiraApiClient } from "../../daemon/jira-api-client.js";

// ── Helpers ─────────────────────────────────────────────────────────────────────

interface JiraProjectInput {
  key: string;
  startStatus: string[];
  endStatus?: string[];
  issueTypeWorkflowMap: Record<string, string>;
  debounceWindowSeconds?: number;
}

interface JiraConfigureOptions {
  apiUrl: string;
  email: string;
  apiToken: string;
  project: string[];
  startStatus: string[];
  endStatus: string[];
  issueTypeWorkflow: string[];
  debounceSeconds: number | undefined;
  webhookEnabled: boolean | undefined;
  webhookSecretEnv: string | undefined;
  pollInterval: number | undefined;
}

function parseIssueTypeWorkflow(options: string[]): Record<string, string> {
  const result: Record<string, string> = {};
  for (const pair of options) {
    const [type, workflow] = pair.split("=");
    if (!type || !workflow) {
      throw new Error(`Invalid --issue-type-workflow format: ${pair}. Expected type=workflow`);
    }
    result[type.trim()] = workflow.trim();
  }
  return result;
}

function createElixirClient(): ElixirServerClient {
  const manager = new ElixirServerManager();
  return new ElixirServerClient(manager.url, manager.authToken);
}

async function sendElixirJiraCommand(commandType: string, payload: Record<string, unknown>): Promise<void> {
  const client = createElixirClient();
  const response = await client.sendCommand({
    command_id: `cli-${commandType}-${Date.now()}`,
    command_type: commandType,
    payload,
    metadata: { source: "foreman jira" },
  });
  if (!response.ok) throw new Error(response.error.message);
}

function commandPayload(event: ElixirEvent): Record<string, unknown> | null {
  const payload = event.payload;
  if (!payload || typeof payload !== "object") return null;
  const typed = payload as Record<string, unknown>;
  return typed.input && typeof typed.input === "object" ? typed.input as Record<string, unknown> : typed;
}

function commandType(event: ElixirEvent): string | null {
  const payload = event.payload;
  if (!payload || typeof payload !== "object") return null;
  const typed = payload as Record<string, unknown>;
  return typeof typed.command_type === "string" ? typed.command_type : null;
}

// ── foreman jira configure ─────────────────────────────────────────────────────

const configureCommand = new Command("configure")
  .description("Configure Jira monitoring for the current project")
  .requiredOption("--api-url <url>", "Jira Cloud API URL (e.g., https://your-domain.atlassian.net)")
  .requiredOption("--email <email>", "Jira account email")
  .requiredOption("--api-token <token>", "Jira API token (will be encrypted)")
  .requiredOption("--project <key>", "Jira project key (can repeat for multiple projects)", (val, prev) => {
    (prev as string[]).push(val.toUpperCase());
    return prev;
  }, [] as string[])
  .requiredOption("--start-status <status>", "Status that triggers workflow (can repeat)", (val, prev) => {
    (prev as string[]).push(val);
    return prev;
  }, [] as string[])
  .option("--end-status <status>", "Status that completes workflow (can repeat)", (val, prev) => {
    (prev as string[]).push(val);
    return prev;
  }, [] as string[])
  .option("--issue-type-workflow <pair>", "Map issue type to workflow (format: type=workflow, can repeat)", (val, prev) => {
    (prev as string[]).push(val);
    return prev;
  }, [] as string[])
  .option("--debounce-seconds <seconds>", "Debounce window in seconds (default: 60)", (val) => parseInt(val, 10))
  .option("--webhook-enabled", "Enable webhook-based real-time triggers")
  .option("--webhook-secret-env <name>", "Environment variable name containing webhook secret")
  .option("--poll-interval <seconds>", "Poll interval in seconds (default: 60, min: 30)", (val) => parseInt(val, 10))
  .action(async (opts: JiraConfigureOptions) => {
    // Parse issue type workflow mapping
    const issueTypeWorkflowMap = parseIssueTypeWorkflow(opts.issueTypeWorkflow);
    if (Object.keys(issueTypeWorkflowMap).length === 0) {
      console.error(chalk.red("Error: At least one --issue-type-workflow is required"));
      process.exit(1);
    }
    // Encrypt the API token before sending to daemon
    const encryptedApiToken = await encrypt(opts.apiToken);
    const projects: JiraProjectInput[] = opts.project.map((key) => ({
      key: key.toUpperCase(),
      startStatus: opts.startStatus,
      endStatus: opts.endStatus,
      issueTypeWorkflowMap,
      debounceWindowSeconds: opts.debounceSeconds,
    }));
    try {
      const payload = {
        apiUrl: opts.apiUrl,
        email: opts.email,
        apiToken: encryptedApiToken,
        projects: projects,
        webhookEnabled: opts.webhookEnabled ?? false,
        webhookSecretEnvVar: opts.webhookSecretEnv,
        pollIntervalSeconds: opts.pollInterval,
      };
      if (foremanBackendMode() === "elixir") {
        await sendElixirJiraCommand("jira.configure", payload);
      } else {
        const client = createTrpcClient();
        await client.jira.configure(payload);
      }
      console.log(chalk.green("✓ Jira monitoring configured successfully"));
      console.log(chalk.dim(`  API URL: ${opts.apiUrl}`));
      console.log(chalk.dim(`  Projects: ${opts.project.join(", ")}`));
      console.log(chalk.dim(`  Start statuses: ${opts.startStatus.join(", ")}`));
      console.log(chalk.dim(`  Issue type mappings: ${Object.entries(issueTypeWorkflowMap).map(([k, v]) => `${k}=${v}`).join(", ")}`));
      if (opts.webhookEnabled) {
        console.log(chalk.dim(`  Webhooks: enabled`));
      }
    } catch (err) {
      const error = err as Error;
      console.error(chalk.red(`Error configuring Jira: ${error.message}`));
      process.exit(1);
    }
  });

// ── foreman jira status ───────────────────────────────────────────────────────

interface JiraStatusResult {
  configured: boolean;
  projects: number;
  lastPoll?: string;
  webhookEnabled: boolean;
}

const statusCommand = new Command("status")
  .description("Show Jira monitor status")
  .option("--json", "Output as JSON")
  .action(async (opts: { json?: boolean }) => {
    try {
      const status = foremanBackendMode() === "elixir"
        ? await getElixirJiraStatus()
        : await createTrpcClient().jira.getStatus({}) as JiraStatusResult;

      if (opts.json) {
        console.log(JSON.stringify(status, null, 2));
        return;
      }

      console.log(chalk.bold("Jira Monitor Status"));
      console.log(chalk.dim("─".repeat(40)));

      if (!status.configured) {
        console.log(chalk.yellow("⚠ Not configured"));
        console.log(chalk.dim("  Run 'foreman jira configure' to set up Jira monitoring"));
        return;
      }

      console.log(chalk.green("✓ Configured"));
      console.log(chalk.dim(`  Projects monitored: ${status.projects}`));
      if (status.lastPoll) {
        console.log(chalk.dim(`  Last poll: ${status.lastPoll}`));
      }
      console.log(chalk.dim(`  Webhooks: ${status.webhookEnabled ? "enabled" : "disabled"}`));
    } catch (err) {
      const error = err as Error;
      console.error(chalk.red(`Error getting status: ${error.message}`));
      process.exit(1);
    }
  });

// ── foreman jira test ───────────────────────────────────────────────────────

interface JiraTestResult {
  connected: boolean;
  projects?: Array<{ key: string; name: string }>;
  error?: string;
}

const testCommand = new Command("test")
  .description("Test Jira API connection")
  .requiredOption("--api-url <url>", "Jira Cloud API URL")
  .requiredOption("--email <email>", "Jira account email")
  .requiredOption("--api-token <token>", "Jira API token (will be encrypted)")
  .option("--json", "Output as JSON")
  .action(async (opts: { apiUrl: string; email: string; apiToken: string; json?: boolean }) => {
    console.log(chalk.dim("Testing Jira connection..."));
    try {
      const result = foremanBackendMode() === "elixir"
        ? await testJiraConnection(opts)
        : await createTrpcClient().jira.testConnection({
            apiUrl: opts.apiUrl,
            email: opts.email,
            apiToken: await encrypt(opts.apiToken),
          }) as JiraTestResult;
      if (opts.json) {
        console.log(JSON.stringify(result, null, 2));
        return;
      }
      if (result.connected) {
        console.log(chalk.green("✓ Connected to Jira"));
        if (result.projects && result.projects.length > 0) {
          console.log(chalk.dim(`  Available projects: ${result.projects.map((p: { key: string }) => p.key).join(", ")}`));
        }
      } else {
        console.log(chalk.red("✗ Connection failed"));
        console.log(chalk.dim("  Check your credentials and API URL"));
      }
    } catch (err) {
      const error = err as Error;
      if (opts.json) {
        console.log(JSON.stringify({ connected: false, error: error.message }, null, 2));
      } else {
        console.error(chalk.red(`Connection failed: ${error.message}`));
      }
      process.exit(1);
    }
  });
// ── foreman jira enable-webhook ─────────────────────────────────────────────

interface EnableWebhookResult {
  webhookUrl: string;
}

const enableWebhookCommand = new Command("enable-webhook")
  .description("Enable Jira webhook for real-time triggers")
  .option("--secret-env <name>", "Env var name for webhook secret (default: FOREMAN_JIRA_WEBHOOK_SECRET)", "FOREMAN_JIRA_WEBHOOK_SECRET")
  .action(async (opts: { secretEnv: string }) => {
    console.log(chalk.dim("Registering Jira webhook..."));
    // Generate a random webhook secret
    const secret = generateWebhookSecret();
    console.log(chalk.dim(`  Generated webhook secret: ${secret}`));
    try {
      const result = foremanBackendMode() === "elixir"
        ? await enableElixirWebhook(secret)
        : await createTrpcClient().jira.enableWebhook({ webhookSecret: secret }) as EnableWebhookResult;
      console.log(chalk.green("✓ Webhook enabled"));
      console.log(chalk.dim(`  Webhook URL: ${result.webhookUrl}`));
      console.log(chalk.bold("\n  Setup instructions:"));
      console.log(chalk.dim("  1. Set the webhook URL in your Jira site settings"));
      console.log(chalk.dim(`  2. Set the secret by storing it in \`${opts.secretEnv}\` env var`));
      console.log(
        chalk.dim("  3. Enable the webhook in Jira admin → System → Webhooks")
      );
    } catch (err) {
      const error = err as Error;
      console.error(chalk.red(`Error enabling webhook: ${error.message}`));
      process.exit(1);
    }
  });

// ── foreman jira disable-webhook ───────────────────────────────────────────

const disableWebhookCommand = new Command("disable-webhook")
  .description("Disable Jira webhook")
  .action(async () => {
    console.log(chalk.dim("Disabling Jira webhook..."));
    try {
      if (foremanBackendMode() === "elixir") {
        await sendElixirJiraCommand("jira.webhook.disable", {});
      } else {
        await createTrpcClient().jira.disableWebhook({});
      }
      console.log(chalk.green("✓ Webhook disabled"));
    } catch (err) {
      const error = err as Error;
      console.error(chalk.red(`Error disabling webhook: ${error.message}`));
      process.exit(1);
    }
  });

// ── Helper ────────────────────────────────────────────────────────────────────────

/** Generate a cryptographically random secret string. */
function generateWebhookSecret(): string {
  const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  let secret = "";
  for (let i = 0; i < 32; i++) {
    secret += chars[Math.floor(Math.random() * chars.length)];
  }
  return secret;
}

async function getElixirJiraStatus(): Promise<JiraStatusResult> {
  const events = await createElixirClient().listEvents({ limit: 500 });
  const latestConfigure = events.find((event) => commandType(event) === "jira.configure");
  if (!latestConfigure) return { configured: false, projects: 0, webhookEnabled: false };

  const payload = commandPayload(latestConfigure) ?? {};
  const projects = Array.isArray(payload.projects) ? payload.projects.length : 0;
  const latestWebhook = events.find((event) => {
    const type = commandType(event);
    return type === "jira.webhook.enable" || type === "jira.webhook.disable";
  });
  const webhookType = latestWebhook ? commandType(latestWebhook) : null;

  return {
    configured: true,
    projects,
    lastPoll: typeof latestConfigure.occurred_at === "string" ? latestConfigure.occurred_at : undefined,
    webhookEnabled: webhookType === "jira.webhook.enable" ? true : webhookType === "jira.webhook.disable" ? false : payload.webhookEnabled === true,
  };
}

async function testJiraConnection(opts: { apiUrl: string; email: string; apiToken: string }): Promise<JiraTestResult> {
  const client = new JiraApiClient({ apiUrl: opts.apiUrl, email: opts.email, apiToken: opts.apiToken });
  await client.authenticate();
  const projects = await client.listProjects();
  return { connected: true, projects };
}

async function enableElixirWebhook(secret: string): Promise<EnableWebhookResult> {
  await sendElixirJiraCommand("jira.webhook.enable", { webhookSecret: secret });
  return { webhookUrl: "managed by Foreman Elixir server" };
}

export const jiraCommand = new Command("jira")
  .description("Configure and monitor Jira issue tracker integration")
  .addCommand(configureCommand)
  .addCommand(statusCommand)
  .addCommand(testCommand)
  .addCommand(enableWebhookCommand)
  .addCommand(disableWebhookCommand);