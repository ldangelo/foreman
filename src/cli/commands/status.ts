import { Command } from "commander";
import chalk from "chalk";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { ForemanStore, type RunProgress } from "../../lib/store.js";

interface Bead {
  id: string;
  title: string;
  status: string;
}

export const statusCommand = new Command("status")
  .description("Show project status from beads + sqlite")
  .action(async () => {
    console.log(chalk.bold("Project Status\n"));

    // Fetch bead list
    let beads: Bead[] = [];
    try {
      const output = execFileSync("bd", ["list", "--json"], {
        stdio: ["pipe", "pipe", "pipe"],
        encoding: "utf-8",
      });
      beads = JSON.parse(output);
    } catch {
      console.error(
        chalk.red(
          "Failed to read beads. Is this a foreman project? Run 'foreman init' first.",
        ),
      );
      process.exit(1);
    }

    const total = beads.length;
    const inProgress = beads.filter((b) => b.status === "in_progress").length;
    const completed = beads.filter((b) => b.status === "closed").length;

    // "ready" and "blocked" are computed from dependencies, not stored as status
    let ready = 0;
    let blocked = 0;
    try {
      const readyOutput = execFileSync("bd", ["ready", "--json", "-n", "0"], {
        stdio: ["pipe", "pipe", "pipe"],
        encoding: "utf-8",
      });
      ready = JSON.parse(readyOutput).length;
    } catch { /* bd ready may fail if no issues exist */ }
    try {
      const blockedOutput = execFileSync("bd", ["blocked", "--json"], {
        stdio: ["pipe", "pipe", "pipe"],
        encoding: "utf-8",
      });
      blocked = JSON.parse(blockedOutput).length;
    } catch { /* bd blocked may fail if no issues exist */ }

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

              // Show current activity
              const lastTool = progress.lastToolCall ?? "starting";
              const phase = parsePipelinePhase(progress.lastToolCall);
              if (phase) {
                const phaseColors: Record<string, (s: string) => string> = {
                  explorer: chalk.cyan, developer: chalk.green,
                  qa: chalk.yellow, reviewer: chalk.magenta, finalize: chalk.blue,
                };
                const colorFn = phaseColors[phase.name] ?? chalk.white;
                const retryTag = phase.retry ? chalk.dim(` (retry ${phase.retry})`) : "";
                console.log(`    ${chalk.dim("└")} Phase: ${colorFn(phase.name)}${retryTag}  ${chalk.dim(details.join(", "))}`);
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

/**
 * Parse pipeline phase from progress.lastToolCall.
 * Pipeline sets values like "explorer:start", "developer:start (retry 1)", "qa:start".
 * Non-pipeline agents use tool names like "Bash", "Read" — returns null for those.
 */
function parsePipelinePhase(lastToolCall: string | null): { name: string; retry?: number } | null {
  if (!lastToolCall) return null;
  const match = lastToolCall.match(/^(explorer|developer|qa|reviewer|finalize):(\S+)(?: \(retry (\d+)\))?$/);
  if (!match) return null;
  return {
    name: match[1],
    retry: match[3] ? parseInt(match[3], 10) : undefined,
  };
}
