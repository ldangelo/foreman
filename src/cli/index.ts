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
import { planCommand } from "./commands/plan.js";
import { runCommand } from "./commands/run.js";
import { statusCommand } from "./commands/status.js";
import { mergeCommand } from "./commands/merge.js";
import { prCommand } from "./commands/pr.js";
import { monitorCommand } from "./commands/monitor.js";
import { resetCommand } from "./commands/reset.js";
import { attachCommand } from "./commands/attach.js";
import { doctorCommand } from "./commands/doctor.js";
import { boardCommand } from "./commands/board.js";
import { dashboardCommand } from "./commands/dashboard.js";
import { watchCommand } from "./commands/watch/index.js";
import { beadCommand } from "./commands/bead.js";
import { worktreeCommand } from "./commands/worktree.js";
import { slingCommand } from "./commands/sling.js";
import { stopCommand } from "./commands/stop.js";
import { sentinelCommand } from "./commands/sentinel.js";
import { retryCommand } from "./commands/retry.js";
import { purgeZombieRunsCommand } from "./commands/purge-zombie-runs.js";
import { purgeLogsCommand } from "./commands/purge-logs.js";
import { inboxCommand } from "./commands/inbox.js";
import { mailCommand } from "./commands/mail.js";
import { debugCommand } from "./commands/debug.js";
import { importCommand } from "./commands/import.js";
import { projectCommand } from "./commands/project.js";
import { taskCommand } from "./commands/task.js";
import { recoverCommand } from "./commands/recover.js";

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

export const program = new Command();

program
  .name("foreman")
  .description("Multi-agent coding orchestrator built on beads_rust (br)")
  .version(readPackageVersion());

program.addCommand(initCommand);
program.addCommand(planCommand);
program.addCommand(runCommand);
program.addCommand(statusCommand);
program.addCommand(mergeCommand);
program.addCommand(prCommand);
program.addCommand(monitorCommand);
program.addCommand(resetCommand);
program.addCommand(attachCommand);
program.addCommand(doctorCommand);
program.addCommand(boardCommand);
program.addCommand(dashboardCommand);
program.addCommand(watchCommand);
program.addCommand(beadCommand);
program.addCommand(worktreeCommand);
program.addCommand(slingCommand);
program.addCommand(stopCommand);
program.addCommand(sentinelCommand);
program.addCommand(retryCommand);
program.addCommand(purgeZombieRunsCommand);
program.addCommand(purgeLogsCommand);
program.addCommand(inboxCommand);
program.addCommand(mailCommand);
program.addCommand(debugCommand);
program.addCommand(importCommand);
program.addCommand(projectCommand);
program.addCommand(taskCommand);
program.addCommand(recoverCommand);

if (isCliEntrypoint()) {
  program.parse();
}
