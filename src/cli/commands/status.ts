import { Command } from "commander";
import chalk from "chalk";
import { execFileSync } from "node:child_process";
import { join, resolve } from "node:path";
import { ForemanStore, type RunProgress } from "../../lib/store.js";

interface Bead {
  id: string;
  title: string;
  status: string;
}

export const statusCommand = new Command("status")
  .description("Show project status from seeds + sqlite")
  .action(async () => {
    console.log(chalk.bold("Project Status\n"));

    // Fetch seed list
    const sdPath = join(process.env.HOME ?? "~", ".bun", "bin", "sd");
    let seeds: Bead[] = [];
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
    
    console.log();
    console.log(chalk.bold("Active Agents"));
    
    if (project) {
      const activeRuns = store.getActiveRuns(project.id);
      if (activeRuns.length === 0) {
        console.log(chalk.dim("  (no agents running)"));
      } else {
        for (const run of activeRuns) {
          const elapsed = run.started_at
            ? Math.round((Date.now() - new Date(run.started_at).getTime()) / 60000)
            : 0;
          const badge = run.agent_type === "claude-code"
            ? chalk.bgBlue.white(` ${run.agent_type} `)
            : run.agent_type === "pi"
            ? chalk.bgGreen.white(` ${run.agent_type} `)
            : chalk.bgMagenta.white(` ${run.agent_type} `);
          console.log(`  ${badge} ${run.bead_id} — ${run.status} (${elapsed}m)`);

          // Show agent progress details
          if (run.progress) {
            try {
              const progress: RunProgress = JSON.parse(run.progress);
              const details: string[] = [];
              if (progress.turns > 0) details.push(`${progress.turns} turns`);
              if (progress.toolCalls > 0) details.push(`${progress.toolCalls} tools`);
              if (progress.filesChanged.length > 0) details.push(`${progress.filesChanged.length} files`);

              // Show current phase (pipeline mode) or last tool (single agent)
              const lastTool = progress.lastToolCall ?? "starting";
              const currentPhase = progress.currentPhase;
              if (currentPhase) {
                const phaseColors: Record<string, (s: string) => string> = {
                  explorer: chalk.cyan, developer: chalk.green,
                  qa: chalk.yellow, reviewer: chalk.magenta, finalize: chalk.blue,
                };
                const colorFn = phaseColors[currentPhase] ?? chalk.white;
                console.log(`    ${chalk.dim("└")} Phase: ${colorFn(currentPhase)}  last: ${chalk.dim(lastTool)}  ${chalk.dim(details.join(", "))}`);
              } else if (details.length > 0) {
                // Team mode or single agent — show last tool and stats
                const agentCount = progress.toolBreakdown["Agent"] ?? 0;
                const activity = agentCount > 0
                  ? `${agentCount} sub-agent(s) spawned`
                  : `last: ${lastTool}`;
                console.log(`    ${chalk.dim("└")} ${chalk.dim(activity)}  ${chalk.dim(details.join(", "))}`);
              }
              if (progress.costUsd > 0) {
                console.log(`    ${chalk.dim("  ")} Cost:  ${chalk.yellow(`$${progress.costUsd.toFixed(4)}`)}`);
              }
            } catch { /* ignore malformed progress */ }
          }
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
  });

