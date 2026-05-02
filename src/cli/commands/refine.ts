import { Command } from "commander";

import { runRefineryAgentCommand } from "../../orchestrator/refinery-agent-cli.js";

export const refineCommand = new Command("refine")
  .description("Process the merge queue with the experimental Refinery Agent")
  .option("--daemon, -d", "Run in daemon mode (continuous polling)")
  .option("--once, -o", "Process queue once and exit")
  .option("--poll-interval <ms>", "Poll interval in milliseconds", "60000")
  .option("--max-fix-iterations <n>", "Max fix attempts per entry", "2")
  .option("--log-dir <path>", "Directory for agent logs", "docs/reports")
  .action(async (opts) => {
    const code = await runRefineryAgentCommand({
      daemon: Boolean(opts.daemon),
      once: Boolean(opts.once),
      pollInterval: Number.parseInt(String(opts.pollInterval), 10),
      maxFixIterations: Number.parseInt(String(opts.maxFixIterations), 10),
      logDir: String(opts.logDir),
      help: false,
    });

    if (code !== 0) {
      process.exit(code);
    }
  });
