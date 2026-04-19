/**
 * Refinery Agent CLI — foreman refine
 *
 * CLI wrapper for the Refinery Agent daemon and single-pass modes.
 */

import { parseArgs } from "node:util";
import { join } from "node:path";
import Database from "better-sqlite3";
import { ForemanStore } from "../lib/store.js";
import { MergeQueue } from "./merge-queue.js";
import { VcsBackendFactory } from "../lib/vcs/index.js";
import { RefineryAgent, type RefineryAgentConfig } from "./refinery-agent.js";

const DEFAULT_LOG_DIR = "docs/reports";

interface CliOptions {
  daemon: boolean;
  once: boolean;
  pollInterval: number;
  maxFixIterations: number;
  logDir: string;
  help: boolean;
}

function parseCliArgs(args: string[]): CliOptions {
  const { values } = parseArgs({
    args,
    options: {
      daemon: { type: "boolean", default: false, short: "d" },
      once: { type: "boolean", default: false, short: "o" },
      "poll-interval": { type: "string", default: "60000" },
      "max-fix-iterations": { type: "string", default: "2" },
      "log-dir": { type: "string", default: DEFAULT_LOG_DIR },
      help: { type: "boolean", default: false, short: "h" },
    },
    allowPositionals: true,
  });

  return {
    daemon: values.daemon ?? false,
    once: values.once ?? false,
    pollInterval: parseInt(values["poll-interval"] as string, 10),
    maxFixIterations: parseInt(values["max-fix-iterations"] as string, 10),
    logDir: values["log-dir"] as string,
    help: values.help ?? false,
  };
}

function printHelp(): void {
  console.log(`
foreman refine — Refinery Agent for merge queue processing

USAGE
  foreman refine [OPTIONS]

OPTIONS
  --daemon, -d          Run in daemon mode (continuous polling)
  --once, -o            Process queue once and exit
  --poll-interval MS    Poll interval in milliseconds (default: 60000)
  --max-fix-iterations N  Max fix attempts per entry (default: 2)
  --log-dir PATH        Directory for agent logs (default: docs/reports)
  --help, -h            Show this help message

EXAMPLES
  # Run once
  foreman refine --once

  # Run in daemon mode with custom poll interval
  foreman refine --daemon --poll-interval 30000

  # Custom fix budget
  foreman refine --once --max-fix-iterations 3

ENVIRONMENT
  FOREMAN_USE_REFINERY_AGENT   Enable agent (default: false, use legacy)
`);
}

/**
 * Main CLI entry point.
 */
export async function runRefineCli(args: string[]): Promise<number> {
  const opts = parseCliArgs(args);

  if (opts.help) {
    printHelp();
    return 0;
  }

  // Check feature flag
  const useAgent = process.env.FOREMAN_USE_REFINERY_AGENT === "true";
  if (!useAgent) {
    console.log("[refine] FOREMAN_USE_REFINERY_AGENT is not set to 'true'");
    console.log("[refine] Set FOREMAN_USE_REFINERY_AGENT=true to enable the agent");
    console.log("[refine] Falling back to legacy refinery (not implemented in this version)");
    return 1;
  }

  // Get project path
  const projectPath = process.cwd();

  // Create store and VCS backend
  const store = new ForemanStore();
  const db = store.getDb();
  const mergeQueue = new MergeQueue(db);
  const vcsBackend = await VcsBackendFactory.create({ backend: "auto" }, projectPath);

  // Agent config
  const agentConfig: Partial<RefineryAgentConfig> = {
    pollIntervalMs: opts.pollInterval,
    maxFixIterations: opts.maxFixIterations,
    logDir: join(projectPath, opts.logDir),
    projectPath,
  };

  // Create agent
  const agent = new RefineryAgent(mergeQueue, vcsBackend, projectPath, agentConfig);

  // Handle signals
  const shutdown = (): void => {
    console.log("\n[refine] Shutting down...");
    agent.stop();
    store.close();
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  if (opts.daemon) {
    console.log("[refine] Starting Refinery Agent in daemon mode");
    await agent.start();
    store.close();
    return 0;
  }

  if (opts.once) {
    console.log("[refine] Processing queue once...");
    const results = await agent.processOnce();

    for (const result of results) {
      if (result.action === "merged") {
        console.log(`✓ Merged: ${result.logPath}`);
      } else if (result.action === "escalated") {
        console.log(`⚠ Escalated: ${result.message}`);
      } else {
        console.log(`- Skipped: ${result.message}`);
      }
    }

    store.close();
    return results.some((r) => r.success) ? 0 : 1;
  }

  // No mode specified
  printHelp();
  return 1;
}

// CLI runner
const args = process.argv.slice(2);
runRefineCli(args)
  .then((code) => process.exit(code))
  .catch((err) => {
    console.error("[refine] Fatal error:", err);
    process.exit(2);
  });
