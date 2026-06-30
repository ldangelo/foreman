/**
 * `foreman jira` CLI commands — removed Jira management surface after Elixir cutover.
 *
 * Jira transition ingestion remains supported by the Elixir ExternalTriggerCommand
 * API. The former Node/tRPC monitor configuration commands are no longer part of
 * the product surface.
 */

import chalk from "chalk";
import { Command } from "commander";

function removedJiraManagement(): never {
  console.error(chalk.red("Error: built-in Jira management commands were removed after the Elixir backend cutover."));
  console.error(chalk.dim("  Submit Jira transitions through the Elixir ExternalTriggerCommand API (/api/v1/commands)."));
  process.exit(1);
}

const configureCommand = new Command("configure")
  .description("Removed: Jira monitor configuration is no longer managed by the CLI")
  .option("--api-url <url>", "Jira Cloud API URL")
  .option("--email <email>", "Jira account email")
  .option("--api-token <token>", "Jira API token")
  .option("--project <key>", "Jira project key", (val, prev) => { (prev as string[]).push(val.toUpperCase()); return prev; }, [] as string[])
  .option("--start-status <status>", "Status that triggers workflow", (val, prev) => { (prev as string[]).push(val); return prev; }, [] as string[])
  .option("--end-status <status>", "Status that completes workflow", (val, prev) => { (prev as string[]).push(val); return prev; }, [] as string[])
  .option("--issue-type-workflow <pair>", "Map issue type to workflow", (val, prev) => { (prev as string[]).push(val); return prev; }, [] as string[])
  .option("--debounce-seconds <seconds>", "Debounce window in seconds")
  .option("--webhook-enabled", "Enable webhook-based real-time triggers")
  .option("--webhook-secret-env <name>", "Environment variable name containing webhook secret")
  .option("--poll-interval <seconds>", "Poll interval in seconds")
  .action(() => removedJiraManagement());

const statusCommand = new Command("status")
  .description("Removed: Jira monitor status is no longer managed by the CLI")
  .option("--json", "Output as JSON")
  .action(() => removedJiraManagement());

const testCommand = new Command("test")
  .description("Removed: Jira API connection tests are no longer managed by the CLI")
  .option("--api-url <url>", "Jira Cloud API URL")
  .option("--email <email>", "Jira account email")
  .option("--api-token <token>", "Jira API token")
  .option("--json", "Output as JSON")
  .action(() => removedJiraManagement());

const enableWebhookCommand = new Command("enable-webhook")
  .description("Removed: Jira webhook management is no longer managed by the CLI")
  .option("--secret-env <name>", "Env var name for webhook secret")
  .action(() => removedJiraManagement());

const disableWebhookCommand = new Command("disable-webhook")
  .description("Removed: Jira webhook management is no longer managed by the CLI")
  .action(() => removedJiraManagement());

export const jiraCommand = new Command("jira")
  .description("Jira transition ingestion is supported through the Elixir ExternalTriggerCommand API")
  .addCommand(configureCommand)
  .addCommand(statusCommand)
  .addCommand(testCommand)
  .addCommand(enableWebhookCommand)
  .addCommand(disableWebhookCommand);
