import { Command } from "commander";
import chalk from "chalk";
import { foremanBackendMode } from "../../lib/backend-mode.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { ForemanStore, type Metrics } from "../../lib/store.js";
import { resolveRepoRootProjectPath } from "./project-task-support.js";

/** Shape returned by the /api/v1/pipeline-metrics endpoint. */
export interface PipelineMetricsResponse {
  ok: boolean;
  pipeline_metrics: {
    phases: Record<
      string,
      {
        pass_rate: number;
        fail_count: number;
        timed_out_count: number;
        retry_count: number;
        avg_turns: number;
        avg_cost: number;
        total_runs: number;
        phases_started: number;
        phases_completed: number;
      }
    >;
    top_failure_reasons: Array<{ reason: string; phase: string; count: number }>;
    stuck_by_reason: Array<{ reason: string; phase: string; count: number }>;
    recent_bottlenecks: Array<{ phase_id: string; run_id: string; started_at: string }>;
    emitted_at: string;
    retry_details: {
      stuck_by_reason: Array<{ reason: string; phase: string; count: number }>;
      blocked_by_reason: Array<{ reason: string; phase: string; count: number }>;
      qa_environment_blocked: number;
    };
    counters: {
      phases_started: number;
      phases_completed: number;
      retries: number;
      failures: number;
      recoveries: number;
      worker_restarts: number;
      circuit_breaker_hits: number;
      qa_environment_blocked: number;
    };
  };
}

interface CostMetricsOptions {
  since?: string;
  phase?: string;
  agent?: string;
  taskType?: string;
}

interface MetricsCommandOptions extends CostMetricsOptions {
  json?: boolean;
  compact?: boolean;
  costs?: boolean;
  project?: string;
  projectPath?: string;
}

// ── Cost/token rendering helpers ─────────────────────────────────────────

function renderCostMetrics(metrics: Metrics, opts?: CostMetricsOptions): void {
  const contexts: string[] = [];
  if (opts?.since) contexts.push(`since ${opts.since}`);
  if (opts?.phase) contexts.push(`phase=${opts.phase}`);
  if (opts?.agent) contexts.push(`agent=${opts.agent}`);
  if (opts?.taskType) contexts.push(`task-type=${opts.taskType}`);

  if (contexts.length > 0) {
    console.log(chalk.bold("Metrics") + " " + chalk.dim(`(${contexts.join(", ")})`));
  } else {
    console.log(chalk.bold("Metrics"));
  }

  const hasData =
    metrics.totalCost > 0 ||
    metrics.totalTokens > 0 ||
    (metrics.costByPhase && Object.keys(metrics.costByPhase).length > 0) ||
    (metrics.agentCostBreakdown && Object.keys(metrics.agentCostBreakdown).length > 0) ||
    (metrics.tasksByStatus && Object.keys(metrics.tasksByStatus).length > 0);

  if (!hasData) {
    console.log(chalk.dim("  No metrics found for this project."));
    return;
  }

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

function renderCostMetricsCompact(metrics: Metrics, opts?: CostMetricsOptions): void {
  const phaseCount = metrics.costByPhase ? Object.keys(metrics.costByPhase).length : 0;
  const agentCount = metrics.agentCostBreakdown ? Object.keys(metrics.agentCostBreakdown).length : 0;
  const parts: string[] = [
    `cost=${metrics.totalCost.toFixed(4)}`,
    `tokens=${metrics.totalTokens}`,
    `phases=${phaseCount}`,
    `agents=${agentCount}`,
  ];
  const filters: string[] = [];
  if (opts?.since) filters.push(`since=${opts.since}`);
  if (opts?.phase) filters.push(`phase=${opts.phase}`);
  if (opts?.agent) filters.push(`agent=${opts.agent}`);
  if (opts?.taskType) filters.push(`task-type=${opts.taskType}`);
  if (filters.length > 0) {
    parts.push(`filters=${filters.join(",")}`);
  }
  console.log(parts.join(" "));
}

function filterMetricsByPhase(metrics: Metrics, phase: string): Metrics {
  const filtered: Metrics = { ...metrics };
  if (filtered.costByPhase === undefined) {
    return { ...filtered, costByPhase: {} };
  }
  const phaseCost = filtered.costByPhase[phase];
  return { ...filtered, costByPhase: phaseCost !== undefined ? { [phase]: phaseCost } : {} };
}

function filterMetricsByAgent(metrics: Metrics, agent: string): Metrics {
  const filtered: Metrics = { ...metrics };
  if (filtered.agentCostBreakdown === undefined) {
    return { ...filtered, agentCostBreakdown: {} };
  }
  const agentCost = filtered.agentCostBreakdown[agent];
  return { ...filtered, agentCostBreakdown: agentCost !== undefined ? { [agent]: agentCost } : {} };
}

async function renderTaskStoreMetrics(opts: MetricsCommandOptions): Promise<void> {
  const projectPath = await resolveRepoRootProjectPath(opts);
  const store = ForemanStore.forProject(projectPath);
  try {
    const project = store.getProjectByPath(projectPath);

    if (!project) {
      const msg = "Project not found. Run 'foreman init' first.";
      if (opts.json || opts.compact) {
        console.error(JSON.stringify({ error: msg }));
        process.exit(1);
      }
      console.log(chalk.red(msg));
      return;
    }

    let metrics: Metrics = store.getMetrics(project.id, opts.since, opts.taskType);

    if (opts.phase) {
      metrics = filterMetricsByPhase(metrics, opts.phase);
    }

    if (opts.agent) {
      metrics = filterMetricsByAgent(metrics, opts.agent);
    }

    const renderOpts: CostMetricsOptions = {
      since: opts.since,
      phase: opts.phase,
      agent: opts.agent,
      taskType: opts.taskType,
    };

    if (opts.json) {
      console.log(
        JSON.stringify(
          {
            projectId: project.id,
            timestamp: new Date().toISOString(),
            ...metrics,
          },
          null,
          2,
        ),
      );
    } else if (opts.compact) {
      renderCostMetricsCompact(metrics, renderOpts);
    } else {
      renderCostMetrics(metrics, renderOpts);
    }
  } finally {
    store.close();
  }
}

// ── Pipeline rendering helpers ───────────────────────────────────────────

function formatRate(rate: number): string {
  const pct = (rate * 100).toFixed(1);
  if (rate >= 0.8) return chalk.green(`${pct}%`);
  if (rate >= 0.5) return chalk.yellow(`${pct}%`);
  return chalk.red(`${pct}%`);
}

function padCell(value: string, width: number): string {
  return value.length >= width ? value.slice(0, width) : value.padEnd(width);
}

function renderPhaseTable(
  phases: PipelineMetricsResponse["pipeline_metrics"]["phases"],
): void {
  const header = [
    padCell("PHASE", 16),
    padCell("PASS RATE", 10),
    padCell("FAILS", 6),
    padCell("TIMEOUTS", 8),
    padCell("RETRIES", 7),
    padCell("AVG TURNS", 10),
    padCell("AVG COST", 9),
    padCell("TOTAL", 6),
  ].join("  ");

  console.log(chalk.bold(header));
  console.log(chalk.dim("─".repeat(header.length)));

  const sorted = Object.entries(phases).sort(([a], [b]) => a.localeCompare(b));

  if (sorted.length === 0) {
    console.log(chalk.dim("  (no phase data available)"));
    return;
  }

  for (const [phase_id, m] of sorted) {
    const row = [
      padCell(phase_id, 16),
      padCell(formatRate(m.pass_rate), 10),
      padCell(String(m.fail_count), 6),
      padCell(String(m.timed_out_count), 8),
      padCell(String(m.retry_count), 7),
      padCell(m.avg_turns.toFixed(1), 10),
      padCell(`$${m.avg_cost.toFixed(2)}`, 9),
      padCell(String(m.total_runs), 6),
    ].join("  ");
    console.log(row);
  }
}

function renderFailureReasons(
  reasons: PipelineMetricsResponse["pipeline_metrics"]["top_failure_reasons"],
): void {
  if (reasons.length === 0) {
    console.log(chalk.dim("  (no recorded failures)"));
    return;
  }
  for (const r of reasons) {
    const reason = r.reason.length > 60 ? r.reason.slice(0, 57) + "…" : r.reason;
    console.log(
      `  ${chalk.red(padCell(String(r.count), 4))}  ${chalk.dim(r.phase.padEnd(16))}  ${reason}`,
    );
  }
}

function renderStuckByReason(
  stuck: PipelineMetricsResponse["pipeline_metrics"]["stuck_by_reason"],
): void {
  if (stuck.length === 0) {
    console.log(chalk.dim("  (no stuck tasks recorded)"));
    return;
  }
  for (const s of stuck) {
    const reason = s.reason.length > 60 ? s.reason.slice(0, 57) + "…" : s.reason;
    console.log(
      `  ${chalk.red(padCell(String(s.count), 4))}  ${chalk.dim(s.phase.padEnd(16))}  ${reason}`,
    );
  }
}

function renderBottlenecks(
  bottlenecks: PipelineMetricsResponse["pipeline_metrics"]["recent_bottlenecks"],
): void {
  if (bottlenecks.length === 0) {
    console.log(chalk.dim("  (no recent bottlenecks)"));
    return;
  }
  for (const b of bottlenecks) {
    const when = b.started_at
      ? new Date(b.started_at).toLocaleString()
      : "unknown";
    console.log(
      `  ${chalk.yellow(padCell(b.phase_id, 16))}  ${chalk.dim(b.run_id)}  ${chalk.dim(when)}`,
    );
  }
}

// ── Retry UX render helpers ─────────────────────────────────────────────

export function renderRetryAttempts(
  phases: PipelineMetricsResponse["pipeline_metrics"]["phases"],
): void {
  const total = Object.values(phases).reduce((sum, p) => sum + (p.retry_count || 0), 0);
  console.log(`  Total: ${chalk.cyan(total)} retry attempts`);
}

export function renderCircuitBreakerHits(
  counters: PipelineMetricsResponse["pipeline_metrics"]["counters"],
): void {
  const hits = counters.circuit_breaker_hits || 0;
  const label = hits === 1 ? "hit" : "hits";
  console.log(`  Same-failure circuit breaker ${label}: ${chalk.yellow(hits)}`);
}

export function renderQAEnvironmentBlocked(
  counters: PipelineMetricsResponse["pipeline_metrics"]["counters"],
): void {
  const blocked = counters.qa_environment_blocked || 0;
  const label = blocked === 1 ? "outcome" : "outcomes";
  console.log(`  QA environment-blocked ${label}: ${chalk.yellow(blocked)}`);
}

export function renderBlockedByReason(
  retryDetails: PipelineMetricsResponse["pipeline_metrics"]["retry_details"],
): void {
  const blocked = retryDetails.blocked_by_reason || [];
  if (blocked.length === 0) {
    console.log(chalk.dim("  (no blocked retries recorded)"));
    return;
  }
  for (const b of blocked) {
    const reason = b.reason.length > 60 ? b.reason.slice(0, 57) + "…" : b.reason;
    console.log(
      `  ${chalk.red(padCell(String(b.count), 5))}  ${chalk.dim(padCell(b.phase, 16))}  ${reason}`,
    );
  }
}

export function renderPipelineMetricsCompact(pm: PipelineMetricsResponse["pipeline_metrics"]): void {
  const phaseCount = Object.keys(pm.phases ?? {}).length;
  const stuckCount = (pm.stuck_by_reason ?? []).reduce((sum, item) => sum + item.count, 0);
  const blockedCount = (pm.retry_details?.blocked_by_reason ?? []).reduce((sum, item) => sum + item.count, 0);
  const parts = [
    `phases=${phaseCount}`,
    `started=${pm.counters?.phases_started ?? 0}`,
    `completed=${pm.counters?.phases_completed ?? 0}`,
    `failures=${pm.counters?.failures ?? 0}`,
    `retries=${pm.counters?.retries ?? 0}`,
    `recoveries=${pm.counters?.recoveries ?? 0}`,
    `stuck=${stuckCount}`,
    `blocked=${blockedCount}`,
    `circuit_breakers=${pm.counters?.circuit_breaker_hits ?? 0}`,
    `qa_environment_blocked=${pm.counters?.qa_environment_blocked ?? 0}`,
  ];
  if (pm.emitted_at) parts.push(`emitted_at=${pm.emitted_at}`);
  console.log(parts.join(" "));
}

async function renderPipelineMetrics(opts: MetricsCommandOptions): Promise<void> {
  const manager = new ElixirServerManager();
  const status = manager.status();

  if (!status.running) {
    const msg = "Elixir server is not running. Start it with 'foreman server start'.";
    if (opts.json) {
      console.log(JSON.stringify({ error: msg }));
    } else {
      console.error(chalk.red(msg));
    }
    process.exit(1);
  }

  const result = await manager.pipelineMetrics();

  if (!result.ok) {
    const msg = result.error ?? "Failed to fetch pipeline metrics";
    if (opts.json) {
      console.log(JSON.stringify({ error: msg }));
    } else {
      console.error(chalk.red(msg));
    }
    process.exit(1);
  }

  const body = result.body as PipelineMetricsResponse;

  if (opts.json) {
    console.log(JSON.stringify(body, null, 2));
    return;
  }

  const pm = body.pipeline_metrics;
  if (opts.compact) {
    renderPipelineMetricsCompact(pm);
    return;
  }
  const updated = pm.emitted_at
    ? new Date(pm.emitted_at).toLocaleString()
    : "—";

  console.log(chalk.bold("Pipeline Metrics"));
  console.log(chalk.dim(`Updated: ${updated}\n`));

  console.log(chalk.bold("Per-Phase Breakdown"));
  renderPhaseTable(pm.phases);
  console.log();

  console.log(chalk.bold("Top Failure Reasons"));
  console.log(chalk.dim("  COUNT  PHASE             REASON"));
  renderFailureReasons(pm.top_failure_reasons);
  console.log();

  console.log(chalk.bold("Stuck Tasks by Reason"));
  console.log(chalk.dim("  COUNT  PHASE             REASON"));
  renderStuckByReason(pm.stuck_by_reason);
  console.log();

  console.log(chalk.bold("Recent Pipeline Bottlenecks (most recent first)"));
  renderBottlenecks(pm.recent_bottlenecks);
  console.log();

  console.log(chalk.bold("Retry Attempts"));
  renderRetryAttempts(pm.phases);
  console.log();

  console.log(chalk.bold("Circuit Breaker"));
  renderCircuitBreakerHits(pm.counters);
  console.log();

  console.log(chalk.bold("QA Environment Blocked"));
  renderQAEnvironmentBlocked(pm.counters);
  console.log();

  console.log(chalk.bold("Blocked Retries by Reason"));
  console.log(chalk.dim("  COUNT  PHASE             REASON"));
  renderBlockedByReason(pm.retry_details);
}

// ── Command ──────────────────────────────────────────────────────────────

export const metricsCommand = new Command("metrics")
  .description("Show Foreman pipeline metrics, or task-store cost/token metrics with --costs/filters")
  .option("--json", "Output JSON")
  .option("--compact", "Output Elixir pipeline counters as key=value; with FOREMAN_BACKEND=node, output task-store cost metrics")
  .option("--costs", "Show task-store cost/token metrics instead of pipeline metrics")
  .option("--since <iso-timestamp>", "Show cost metrics since this ISO timestamp (e.g., 2026-06-01T00:00:00Z)")
  .option("--phase <phase-name>", "Filter cost metrics to a specific phase (explorer, developer, qa, reviewer, finalize)")
  .option("--agent <agent-id>", "Filter cost metrics to a specific agent/model (e.g., claude-sonnet-4-6)")
  .option("--task-type <type>", "Filter cost metrics to tasks of a specific type (feature, bug, chore, task)")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (opts: MetricsCommandOptions) => {
    try {
      const backendMode = foremanBackendMode();
      const legacyCostFilterMode = Boolean(opts.costs || opts.since || opts.phase || opts.agent || opts.taskType);
      if (backendMode === "elixir") {
        if (legacyCostFilterMode) {
          throw new Error("metrics cost filters (--costs/--since/--phase/--agent/--task-type) read the legacy task store. Set FOREMAN_BACKEND=node for legacy cost metrics; default 'foreman metrics' uses Elixir pipeline metrics; --compact is supported for Elixir pipeline metrics.");
        }
        await renderPipelineMetrics(opts);
      } else if (legacyCostFilterMode || opts.compact) {
        await renderTaskStoreMetrics(opts);
      } else {
        await renderPipelineMetrics(opts);
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      if (opts.json || opts.compact) {
        console.error(JSON.stringify({ error: message }));
      } else {
        console.error(chalk.red(message));
      }
      process.exit(1);
    }
  });
