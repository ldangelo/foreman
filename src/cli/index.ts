#!/usr/bin/env node

import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join, resolve } from "path";
import { Command } from "commander";

/**
 * Read the package version at runtime so it automatically stays in sync with
 * whatever version release-please writes into package.json on each release.
 * Falls back to a safe sentinel if the file can't be loaded (e.g. during tests).
 */
function readPackageVersion(): string {
  try {
    const __filename = fileURLToPath(import.meta.url);
    const __dirname = dirname(__filename);
    // When running from dist/cli/index.js the package.json is two levels up.
    // When running via tsx directly from src/cli/index.ts it's three levels up.
    const candidates = [
      join(__dirname, "../../package.json"),
      join(__dirname, "../../../package.json"),
    ];
    for (const candidate of candidates) {
      try {
        const raw = readFileSync(candidate, "utf8");
        const pkg = JSON.parse(raw) as { version?: string };
        if (pkg.version) return pkg.version;
      } catch {
        // try next candidate
      }
    }
  } catch {
    // fall through to default
  }
  return "0.0.0-dev";
}
import { initCommand } from "./commands/init.js";
import { runsCommand } from "./commands/runs.js";
import { planCommand } from "./commands/plan.js";
import { runCommand } from "./commands/run.js";
import { statusCommand } from "./commands/status.js";
import { mergeCommand } from "./commands/merge.js";
import { prCommand } from "./commands/pr.js";
import { resetCommand } from "./commands/reset.js";
import { attachCommand } from "./commands/attach.js";
import { doctorCommand } from "./commands/doctor.js";
import { boardCommand } from "./commands/board.js";
import { watchCommand } from "./commands/watch/index.js";
import { beadCommand } from "./commands/bead.js";
import { worktreeCommand } from "./commands/worktree.js";
import { slingCommand } from "./commands/sling.js";
import { stopCommand } from "./commands/stop.js";
import { sentinelCommand } from "./commands/sentinel.js";
import { retryCommand } from "./commands/retry.js";
import { purgeCommand, purgeLogsCommand, purgeZombieRunsCommand } from "./commands/purge.js";
import { inboxCommand } from "./commands/inbox.js";
import { debugCommand } from "./commands/debug.js";
import { importCommand } from "./commands/import.js";
import { issueCommand } from "./commands/issue.js";
import { projectCommand } from "./commands/project.js";
import { taskCommand } from "./commands/task.js";
import { metricsCommand } from "./commands/metrics.js";
import { recoverCommand } from "./commands/recover.js";
import { daemonCommand } from "./commands/daemon.js";
import { jiraCommand } from "./commands/jira.js";
import { logsCommand } from "./commands/logs.js";
import { serverCommand } from "./commands/server.js";
import { mcpCommand } from "./commands/mcp.js";
import { maybeDelegateToLegacyTs } from "./legacy-coexistence.js";
function isCliEntrypoint(): boolean {
  try {
    const invokedPath = process.argv[1];
    if (!invokedPath) {
      return false;
    }
    return resolve(invokedPath) === fileURLToPath(import.meta.url);
  } catch {
    return false;
  }
}

function exitSilentlyOnEpipe(error: NodeJS.ErrnoException): void {
  if (error.code === "EPIPE") {
    process.exit(0);
  }
  throw error;
}

process.stdout.on("error", exitSilentlyOnEpipe);
process.stderr.on("error", exitSilentlyOnEpipe);

export const program = new Command();

program
  .name("foreman")
  .description("Multi-agent coding orchestrator with PostgreSQL-backed daemon")
  .version(readPackageVersion());

program.addCommand(initCommand);
program.addCommand(planCommand);
program.addCommand(runCommand);
program.addCommand(runsCommand);
program.addCommand(statusCommand);
program.addCommand(mergeCommand);
program.addCommand(prCommand);
program.addCommand(resetCommand);
program.addCommand(attachCommand);
program.addCommand(doctorCommand);
program.addCommand(boardCommand);
program.addCommand(watchCommand); // also handles the deprecated 'dashboard' alias
program.addCommand(beadCommand, { hidden: true }); // deprecated: 'foreman task create --from-text'
program.addCommand(worktreeCommand);
program.addCommand(slingCommand);
program.addCommand(stopCommand);
program.addCommand(sentinelCommand);
program.addCommand(retryCommand);
program.addCommand(purgeCommand);
program.addCommand(purgeZombieRunsCommand, { hidden: true }); // deprecated: 'foreman purge runs'
program.addCommand(purgeLogsCommand, { hidden: true }); // deprecated: 'foreman purge logs'
program.addCommand(inboxCommand);
program.addCommand(debugCommand);
program.addCommand(importCommand, { hidden: true });
program.addCommand(issueCommand);
program.addCommand(projectCommand);
program.addCommand(taskCommand);
program.addCommand(metricsCommand);
program.addCommand(recoverCommand);
program.addCommand(daemonCommand);
program.addCommand(jiraCommand);
program.addCommand(logsCommand);
program.addCommand(serverCommand);
program.addCommand(mcpCommand);

program.addHelpText(
  "after",
  `
Domain groups:
  Setup/health:     init, doctor, daemon, server
  Planning:         plan, sling
  Execution:        run, retry, reset, stop, recover
  Tasks/views:      task, status, metrics, board, watch, logs, runs
  Collaboration:    inbox, attach, debug, mcp
  Delivery/VCS:     worktree, merge, pr

Deprecated aliases print the replacement spelling when used:
  legacy dashboard -> watch
  legacy bead -> task create --from-text
  legacy purge-logs -> purge logs
  legacy purge-zombie-runs -> purge runs`,
);
if (isCliEntrypoint()) {
  try {
    const delegation = maybeDelegateToLegacyTs();
    if (delegation.delegated) process.exit(delegation.status);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }

  program.parse();
}
