/**
 * Refinery Agent CLI — foreman refine
 *
 * CLI wrapper for the Refinery Agent daemon and single-pass modes.
 */

import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { join, resolve } from "node:path";
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

export function printRefineHelp(): void {
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
  FOREMAN_USE_REFINERY_AGENT   Enable the experimental Refinery Agent (set to true)
`);
}

/**
 * Main command implementation shared by the standalone runner and commander.
 */
export async function runRefineryAgentCommand(opts: CliOptions): Promise<number> {
  if (opts.help) {
    printRefineHelp();
    return 0;
  }

  const useAgent = process.env.FOREMAN_USE_REFINERY_AGENT === "true";
  if (!useAgent) {
    console.error("[refine] The Refinery Agent command is experimental and currently disabled.");
    console.error("[refine] Re-run with FOREMAN_USE_REFINERY_AGENT=true to enable it.");
    return 1;
  }

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
  printRefineHelp();
  return 1;
}

/**
 * Standalone CLI entry point.
 */
export async function runRefineCli(args: string[]): Promise<number> {
  return runRefineryAgentCommand(parseCliArgs(args));
}

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

if (isCliEntrypoint()) {
  const args = process.argv.slice(2);
  runRefineCli(args)
    .then((code) => process.exit(code))
    .catch((err) => {
      console.error("[refine] Fatal error:", err);
      process.exit(2);
    });
}
