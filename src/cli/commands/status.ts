import { Command } from "commander";
import chalk from "chalk";
import { execFileSync } from "node:child_process";
import { join, resolve } from "node:path";
import { ForemanStore } from "../../lib/store.js";
import { renderAgentCard } from "../watch-ui.js";

interface Seed {
  id: string;
  title: string;
  status: string;
}

const sdPath = join(process.env.HOME ?? "~", ".bun", "bin", "sd");

function renderStatus(): void {
  // Fetch seed list
  let seeds: Seed[] = [];
  try {
    const output = execFileSync(sdPath, ["list", "--json", "--limit", "0"], {
      stdio: ["pipe", "pipe", "pipe"],
      encoding: "utf-8",
    });
    const parsed = JSON.parse(output);
    seeds = parsed.issues ?? parsed ?? [];
  } catch {
    console.error(
      chalk.red(
        "Failed to read seeds. Is this a foreman project? Run 'foreman init' first.",
      ),
    );
    process.exit(1);
  }

  const inProgress = seeds.filter((b) => b.status === "in_progress").length;

  // sd list excludes closed issues by default — fetch them separately
  let completed = 0;
  try {
    const closedOutput = execFileSync(sdPath, ["list", "--status=closed", "--json", "--limit", "0"], {
      stdio: ["pipe", "pipe", "pipe"],
      encoding: "utf-8",
    });
    const closedParsed = JSON.parse(closedOutput);
    completed = (closedParsed.issues ?? closedParsed ?? []).length;
  } catch { /* no closed issues */ }

  const total = seeds.length + completed;

  // "ready" and "blocked" are computed from dependencies, not stored as status
  let ready = 0;
  let blocked = 0;
  try {
    const readyOutput = execFileSync(sdPath, ["ready", "--json"], {
      stdio: ["pipe", "pipe", "pipe"],
      encoding: "utf-8",
    });
    const readyParsed = JSON.parse(readyOutput);
    ready = (readyParsed.issues ?? readyParsed ?? []).length;
  } catch { /* sd ready may fail if no issues exist */ }
  try {
    const blockedOutput = execFileSync(sdPath, ["blocked", "--json"], {
      stdio: ["pipe", "pipe", "pipe"],
      encoding: "utf-8",
    });
    const blockedParsed = JSON.parse(blockedOutput);
    blocked = (blockedParsed.issues ?? blockedParsed ?? []).length;
  } catch { /* sd blocked may fail if no issues exist */ }

  console.log(chalk.bold("Tasks"));
  console.log(`  Total:       ${chalk.white(total)}`);
  console.log(`  Ready:       ${chalk.green(ready)}`);
  console.log(`  In Progress: ${chalk.yellow(inProgress)}`);
  console.log(`  Completed:   ${chalk.cyan(completed)}`);
  console.log(`  Blocked:     ${chalk.red(blocked)}`);

  // Show active agents from sqlite
  const store = new ForemanStore();
  const project = store.getProjectByPath(resolve("."));

  // Show failed/stuck run counts from SQLite
  if (project) {
    const failedCount = store.getRunsByStatus("failed", project.id).length;
    const stuckCount = store.getRunsByStatus("stuck", project.id).length;
    if (failedCount > 0) console.log(`  Failed:      ${chalk.red(failedCount)}`);
    if (stuckCount > 0) console.log(`  Stuck:       ${chalk.red(stuckCount)}`);
  }

  console.log();
  console.log(chalk.bold("Active Agents"));

  if (project) {
    const activeRuns = store.getActiveRuns(project.id);
    if (activeRuns.length === 0) {
      console.log(chalk.dim("  (no agents running)"));
    } else {
      for (let i = 0; i < activeRuns.length; i++) {
        const run = activeRuns[i];
        const progress = store.getRunProgress(run.id);
        console.log(renderAgentCard(run, progress));
        // Separate cards with a blank line, but don't add a trailing blank
        // after the last card (avoids a dangling empty line in single-agent output).
        if (i < activeRuns.length - 1) console.log();
      }
    }

    // Cost summary
    const metrics = store.getMetrics(project.id);
    if (metrics.totalCost > 0) {
      console.log();
      console.log(chalk.bold("Costs"));
      console.log(`  Total: ${chalk.yellow(`$${metrics.totalCost.toFixed(2)}`)}`);
      console.log(`  Tokens: ${chalk.dim(`${(metrics.totalTokens / 1000).toFixed(1)}k`)}`);
    }
  } else {
    console.log(chalk.dim("  (project not registered — run 'foreman init')"));
  }

  store.close();
}

export const statusCommand = new Command("status")
  .description("Show project status from seeds + sqlite")
  .option("-w, --watch [seconds]", "Refresh every N seconds (default: 10)")
  .action(async (opts: { watch?: boolean | string }) => {
    if (opts.watch !== undefined) {
      const interval = typeof opts.watch === "string" ? parseInt(opts.watch, 10) : 10;
      const seconds = Number.isFinite(interval) && interval > 0 ? interval : 10;

      // Keep process alive and handle Ctrl+C gracefully
      process.on("SIGINT", () => {
        process.stdout.write("\x1b[?25h"); // restore cursor
        process.exit(0);
      });

      process.stdout.write("\x1b[?25l"); // hide cursor
      while (true) {
        // Clear screen and move cursor to top
        process.stdout.write("\x1b[2J\x1b[H");
        console.log(chalk.bold("Project Status") + chalk.dim(`  (watching every ${seconds}s — Ctrl+C to stop)\n`));
        renderStatus();
        console.log(chalk.dim(`\nLast updated: ${new Date().toLocaleTimeString()}`));
        await new Promise((r) => setTimeout(r, seconds * 1000));
      }
    } else {
      console.log(chalk.bold("Project Status\n"));
      renderStatus();
    }
  });
