#!/usr/bin/env node

import { Command } from "commander";
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
import { dashboardCommand } from "./commands/dashboard.js";
import { beadCommand } from "./commands/bead.js";
import { worktreeCommand } from "./commands/worktree.js";
import { slingCommand } from "./commands/sling.js";
import { stopCommand } from "./commands/stop.js";
import { sentinelCommand } from "./commands/sentinel.js";
import { retryCommand } from "./commands/retry.js";
import { purgeZombieRunsCommand } from "./commands/purge-zombie-runs.js";

const program = new Command();

program
  .name("foreman")
  .description("Multi-agent coding orchestrator built on beads_rust (br)")
  .version("0.1.0");

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
program.addCommand(dashboardCommand);
program.addCommand(beadCommand);
program.addCommand(worktreeCommand);
program.addCommand(slingCommand);
program.addCommand(stopCommand);
program.addCommand(sentinelCommand);
program.addCommand(retryCommand);
program.addCommand(purgeZombieRunsCommand);

program.parse();
