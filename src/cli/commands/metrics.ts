import { Command } from "commander";
import chalk from "chalk";
import { ForemanStore, type Metrics } from "../../lib/store.js";
import { resolveRepoRootProjectPath, requireProjectOrAllInMultiMode } from "./project-task-support.js";

/**
 * Render metrics as human-readable output.
 * Mirrors the cost display pattern used in status.ts.
 */
function renderMetrics(metrics: Metrics): void {
  console.log(chalk.bold("Metrics"));
  console.log(`  Total Cost:   ${chalk.yellow(`$${metrics.totalCost.toFixed(2)}`)}`);
  console.log(`  Total Tokens: ${chalk.dim(`${(metrics.totalTokens / 1000).toFixed(1)}k`)}`);

  if (metrics.costByPhase && Object.keys(metrics.costByPhase).length > 0) {
    console.log();
    console.log(chalk.bold("By Phase"));
    for (const [phase, cost] of Object.entries(metrics.costByPhase)) {
      console.log(`  ${phase.padEnd(12)} ${chalk.yellow(`$${cost.toFixed(2)}`)}`);
    }
  }

  if (metrics.agentCostBreakdown && Object.keys(metrics.agentCostBreakdown).length > 0) {
    console.log();
    console.log(chalk.bold("By Agent"));
    for (const [agent, cost] of Object.entries(metrics.agentCostBreakdown)) {
      console.log(`  ${agent.padEnd(24)} ${chalk.yellow(`$${cost.toFixed(2)}`)}`);
    }
  }

  if (metrics.tasksByStatus && Object.keys(metrics.tasksByStatus).length > 0) {
    console.log();
    console.log(chalk.bold("Tasks by Status"));
    for (const [status, count] of Object.entries(metrics.tasksByStatus)) {
      console.log(`  ${status.padEnd(12)} ${count}`);
    }
  }
}

/**
 * Filter metrics to only include a specific phase's cost.
 */
function filterMetricsByPhase(metrics: Metrics, phase: string): Metrics {
  const filtered: Metrics = { ...metrics };
  if (filtered.costByPhase === undefined) {
    return { ...filtered, costByPhase: {} };
  }
  const phaseCost = filtered.costByPhase[phase];
  return { ...filtered, costByPhase: phaseCost !== undefined ? { [phase]: phaseCost } : {} };
}

/**
 * Filter metrics to only include a specific agent's cost.
 */
function filterMetricsByAgent(metrics: Metrics, agent: string): Metrics {
  const filtered: Metrics = { ...metrics };
  if (filtered.agentCostBreakdown === undefined) {
    return { ...filtered, agentCostBreakdown: {} };
  }
  const agentCost = filtered.agentCostBreakdown[agent];
  return { ...filtered, agentCostBreakdown: agentCost !== undefined ? { [agent]: agentCost } : {} };
}

/**
 * Filter metrics to only include tasks of a specific type (feature, bug, chore, etc.).
 * Note: This mirrors the behavior of other CLI filters but the actual filtering is done
 * at the SQL level in store.getMetrics for efficiency.
 */
function filterMetricsByTaskType(metrics: Metrics, taskType: string): Metrics {
  // Task type filtering happens in SQL via getMetrics taskType parameter.
  // This CLI filter function exists for consistency with --phase and --agent filters.
  // When taskType is specified, all metrics returned are already filtered by that type.
  return { ...metrics };
}

export const metricsCommand = new Command("metrics")
  .description("Show cost and token usage metrics from the native Postgres task store")
  .option("--json", "Output metrics as JSON")
  .option("--since <iso-timestamp>", "Include metrics since this ISO timestamp (e.g., 2026-06-01T00:00:00Z)")
  .option("--phase <phase-name>", "Filter costs to a specific phase (explorer, developer, qa, reviewer, finalize)")
  .option("--agent <agent-id>", "Filter costs to a specific agent/model (e.g., claude-sonnet-4-6)")
  .option("--task-type <type>", "Filter costs to tasks of a specific type (feature, bug, chore, task)")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (opts: {
    json?: boolean;
    since?: string;
    phase?: string;
    agent?: string;
    taskType?: string;
    project?: string;
    projectPath?: string;
  }) => {
    try {
      const projectPath = await resolveRepoRootProjectPath(opts);
      const store = ForemanStore.forProject(projectPath);
      const project = store.getProjectByPath(projectPath);

      if (!project) {
        if (opts.json) {
          console.error(JSON.stringify({ error: "Project not found. Run 'foreman init' first." }));
          store.close();
          process.exit(1);
        }
        console.log(chalk.red("Project not found. Run 'foreman init' first."));
        store.close();
        return;
      }

      // Fetch metrics with optional --since and --task-type filters
      let metrics: Metrics = store.getMetrics(project.id, opts.since, opts.taskType);

      // Apply --phase filter if specified
      if (opts.phase) {
        metrics = filterMetricsByPhase(metrics, opts.phase);
      }

      // Apply --agent filter if specified
      if (opts.agent) {
        metrics = filterMetricsByAgent(metrics, opts.agent);
      }

      // Apply --task-type CLI filter (SQL filtering already done, this ensures consistency)
      if (opts.taskType) {
        metrics = filterMetricsByTaskType(metrics, opts.taskType);
      }

      if (opts.json) {
        console.log(JSON.stringify(metrics, null, 2));
      } else {
        renderMetrics(metrics);
      }

      store.close();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      if (opts.json) {
        console.error(JSON.stringify({ error: message }));
      } else {
        console.error(chalk.red(message));
      }
      process.exit(1);
    }
  });
