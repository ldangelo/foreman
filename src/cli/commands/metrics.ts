import { Command } from "commander";
import chalk from "chalk";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";

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

// ── Rendering helpers ────────────────────────────────────────────────────

function formatRate(rate: number): string {
  const pct = (rate * 100).toFixed(1);
  if (rate >= 0.8) return chalk.green(`${pct}%`);
  if (rate >= 0.5) return chalk.yellow(`${pct}%`);
  return chalk.red(`${pct}%`);
}

function padCell(value: string, width: number): string {
  return value.length >= width ? value.slice(0, width) : value.padEnd(width);
}

export function renderPhaseTable(
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

// ── Command ──────────────────────────────────────────────────────────────

export const metricsCommand = new Command("metrics")
  .description("Show per-phase pipeline metrics (pass/fail rate, retries, turns, cost) from the Elixir server")
  .option("--json", "Output raw JSON from the server")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (opts: {
    json?: boolean;
    project?: string;
    projectPath?: string;
  }) => {
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
    const updated = pm.emitted_at
      ? new Date(pm.emitted_at).toLocaleString()
      : "—";

    console.log(chalk.bold("Pipeline Metrics"));
    console.log(chalk.dim(`Updated: ${updated}\n`));

    // Phase breakdown table
    console.log(chalk.bold("Per-Phase Breakdown"));
    renderPhaseTable(pm.phases);
    console.log();

    // Top failure reasons
    console.log(chalk.bold("Top Failure Reasons"));
    console.log(chalk.dim("  COUNT  PHASE             REASON"));
    renderFailureReasons(pm.top_failure_reasons);
    console.log();

    // Stuck by reason
    console.log(chalk.bold("Stuck Tasks by Reason"));
    console.log(chalk.dim("  COUNT  PHASE             REASON"));
    renderStuckByReason(pm.stuck_by_reason);
    console.log();

    // Recent bottlenecks
    console.log(chalk.bold("Recent Pipeline Bottlenecks (most recent first)"));
    renderBottlenecks(pm.recent_bottlenecks);
    console.log();

    // Retry attempts aggregate
    console.log(chalk.bold("Retry Attempts"));
    renderRetryAttempts(pm.phases);
    console.log();

    // Circuit breaker hits
    console.log(chalk.bold("Circuit Breaker"));
    renderCircuitBreakerHits(pm.counters);
    console.log();

    // QA environment blocked
    console.log(chalk.bold("QA Environment Blocked"));
    renderQAEnvironmentBlocked(pm.counters);
    console.log();

    // Blocked retry reasons
    console.log(chalk.bold("Blocked Retries by Reason"));
    console.log(chalk.dim("  COUNT  PHASE             REASON"));
    renderBlockedByReason(pm.retry_details);
  });