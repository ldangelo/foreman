/**
 * Test coverage for foreman metrics command — AC: Expand retry UX in metrics dashboard
 * Verifies: retry attempts, circuit breaker hits, QA environment-blocked outcomes,
 * and blocked/stuck retry reasons are surfaced in the interface and rendered output.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type {
  PipelineMetricsResponse,
} from "../metrics.js";

beforeEach(() => {
  vi.restoreAllMocks();
});

afterEach(() => {
  vi.restoreAllMocks();
});

// ── AC5: PipelineMetricsResponse interface includes new fields ─────────────────────

describe("PipelineMetricsResponse interface", () => {
  it("includes retry_details in pipeline_metrics (AC5)", () => {
    // Compile-time check: the type must accept retry_details
    const pm: PipelineMetricsResponse["pipeline_metrics"] = {
      phases: {},
      top_failure_reasons: [],
      stuck_by_reason: [],
      recent_bottlenecks: [],
      emitted_at: new Date().toISOString(),
      retry_details: {
        stuck_by_reason: [],
        blocked_by_reason: [],
        qa_environment_blocked: 0,
      },
      counters: {
        phases_started: 0,
        phases_completed: 0,
        retries: 0,
        failures: 0,
        recoveries: 0,
        worker_restarts: 0,
        circuit_breaker_hits: 0,
        qa_environment_blocked: 0,
      },
    };
    expect(pm.retry_details).toBeDefined();
    expect(typeof pm.retry_details.qa_environment_blocked).toBe("number");
    expect(Array.isArray(pm.retry_details.stuck_by_reason)).toBe(true);
    expect(Array.isArray(pm.retry_details.blocked_by_reason)).toBe(true);
  });

  it("includes counters in pipeline_metrics with circuit_breaker_hits (AC2)", () => {
    const pm: PipelineMetricsResponse["pipeline_metrics"] = {
      phases: {},
      top_failure_reasons: [],
      stuck_by_reason: [],
      recent_bottlenecks: [],
      emitted_at: new Date().toISOString(),
      retry_details: {
        stuck_by_reason: [],
        blocked_by_reason: [],
        qa_environment_blocked: 0,
      },
      counters: {
        phases_started: 0,
        phases_completed: 0,
        retries: 0,
        failures: 0,
        recoveries: 0,
        worker_restarts: 0,
        circuit_breaker_hits: 0,
        qa_environment_blocked: 0,
      },
    };
    expect(pm.counters).toBeDefined();
    expect(typeof pm.counters.circuit_breaker_hits).toBe("number");
    expect(typeof pm.counters.qa_environment_blocked).toBe("number");
  });

  it("retry_details.stuck_by_reason entries have reason, phase, count fields (AC4)", () => {
    const entry: PipelineMetricsResponse["pipeline_metrics"]["retry_details"]["stuck_by_reason"][number] = {
      reason: "agent timeout",
      phase: "developer",
      count: 3,
    };
    expect(entry.reason).toBe("agent timeout");
    expect(entry.phase).toBe("developer");
    expect(entry.count).toBe(3);
  });

  it("retry_details.blocked_by_reason entries have reason, phase, count fields (AC4)", () => {
    const entry: PipelineMetricsResponse["pipeline_metrics"]["retry_details"]["blocked_by_reason"][number] = {
      reason: "env mismatch",
      phase: "qa",
      count: 1,
    };
    expect(entry.reason).toBe("env mismatch");
    expect(entry.phase).toBe("qa");
    expect(entry.count).toBe(1);
  });

  it("counters includes circuit_breaker_hits count (AC2)", () => {
    const entry: PipelineMetricsResponse["pipeline_metrics"]["counters"]["circuit_breaker_hits"] = 5;
    expect(entry).toBe(5);
  });

  it("counters includes qa_environment_blocked count (AC3)", () => {
    const entry: PipelineMetricsResponse["pipeline_metrics"]["counters"]["qa_environment_blocked"] = 2;
    expect(entry).toBe(2);
  });
});

// ── AC1: renderRetryAttempts exists and aggregates retry_count from phases ─────────────

describe("renderRetryAttempts", () => {
  it("is exported from metrics.ts", async () => {
    const mod = await import("../metrics.js");
    expect(typeof mod.renderRetryAttempts).toBe("function");
  });

  it("outputs the total retry count across all phases", async () => {
    const { renderRetryAttempts } = await import("../metrics.js");
    const consoleLog = vi.spyOn(console, "log").mockImplementation(() => {});

    const phases: PipelineMetricsResponse["pipeline_metrics"]["phases"] = {
      explorer: { pass_rate: 0.5, fail_count: 1, timed_out_count: 0, retry_count: 2, avg_turns: 5, avg_cost: 0.10, total_runs: 3, phases_started: 2, phases_completed: 1 },
      developer: { pass_rate: 1.0, fail_count: 0, timed_out_count: 0, retry_count: 3, avg_turns: 10, avg_cost: 0.20, total_runs: 3, phases_started: 1, phases_completed: 2 },
    };

    renderRetryAttempts(phases);

    // Total retries = 2 (explorer) + 3 (developer) = 5
    expect(consoleLog).toHaveBeenCalled();
    const output = consoleLog.mock.calls.map(call => call.join(" ")).join("\n");
    expect(output).toMatch("5");
  });

  it("outputs 0 when no phases have retry_count", async () => {
    const { renderRetryAttempts } = await import("../metrics.js");
    const consoleLog = vi.spyOn(console, "log").mockImplementation(() => {});

    const phases: PipelineMetricsResponse["pipeline_metrics"]["phases"] = {};
    renderRetryAttempts(phases);

    const output = consoleLog.mock.calls.map(call => call.join(" ")).join("\n");
    expect(output).toMatch("0");
  });
});

// ── AC2: renderCircuitBreakerHits exists and displays circuit_breaker_hits count ─────

describe("renderCircuitBreakerHits", () => {
  it("is exported from metrics.ts", async () => {
    const mod = await import("../metrics.js");
    expect(typeof mod.renderCircuitBreakerHits).toBe("function");
  });

  it("outputs the circuit breaker hits count", async () => {
    const { renderCircuitBreakerHits } = await import("../metrics.js");
    const consoleLog = vi.spyOn(console, "log").mockImplementation(() => {});

    const counters: PipelineMetricsResponse["pipeline_metrics"]["counters"] = {
      phases_started: 10,
      phases_completed: 8,
      retries: 2,
      failures: 2,
      recoveries: 1,
      worker_restarts: 0,
      circuit_breaker_hits: 4,
      qa_environment_blocked: 1,
    };

    renderCircuitBreakerHits(counters);

    const output = consoleLog.mock.calls.map(call => call.join(" ")).join("\n");
    expect(output).toMatch("4");
  });
});

// ── AC3: renderQAEnvironmentBlocked exists and displays qa_environment_blocked count ─

describe("renderQAEnvironmentBlocked", () => {
  it("is exported from metrics.ts", async () => {
    const mod = await import("../metrics.js");
    expect(typeof mod.renderQAEnvironmentBlocked).toBe("function");
  });

  it("outputs the QA environment blocked count", async () => {
    const { renderQAEnvironmentBlocked } = await import("../metrics.js");
    const consoleLog = vi.spyOn(console, "log").mockImplementation(() => {});

    const counters: PipelineMetricsResponse["pipeline_metrics"]["counters"] = {
      phases_started: 10,
      phases_completed: 8,
      retries: 2,
      failures: 2,
      recoveries: 1,
      worker_restarts: 0,
      circuit_breaker_hits: 4,
      qa_environment_blocked: 3,
    };

    renderQAEnvironmentBlocked(counters);

    const output = consoleLog.mock.calls.map(call => call.join(" ")).join("\n");
    expect(output).toMatch("3");
  });
});

// ── AC4: renderBlockedByReason exists and displays blocked retry reasons ──────────────

describe("renderBlockedByReason", () => {
  it("is exported from metrics.ts", async () => {
    const mod = await import("../metrics.js");
    expect(typeof mod.renderBlockedByReason).toBe("function");
  });

  it("outputs blocked entries from retry_details.blocked_by_reason", async () => {
    const { renderBlockedByReason } = await import("../metrics.js");
    const consoleLog = vi.spyOn(console, "log").mockImplementation(() => {});

    const retryDetails: PipelineMetricsResponse["pipeline_metrics"]["retry_details"] = {
      stuck_by_reason: [{ reason: "unresponsive", phase: "developer", count: 2 }],
      blocked_by_reason: [{ reason: "env mismatch", phase: "qa", count: 1 }],
      qa_environment_blocked: 0,
    };

    renderBlockedByReason(retryDetails);

    const output = consoleLog.mock.calls.map(call => call.join(" ")).join("\n");
    expect(output).toMatch("env mismatch");
    expect(output).toMatch("qa");
  });

  it("handles empty blocked_by_reason gracefully", async () => {
    const { renderBlockedByReason } = await import("../metrics.js");
    const consoleLog = vi.spyOn(console, "log").mockImplementation(() => {});

    const retryDetails: PipelineMetricsResponse["pipeline_metrics"]["retry_details"] = {
      stuck_by_reason: [],
      blocked_by_reason: [],
      qa_environment_blocked: 0,
    };

    renderBlockedByReason(retryDetails);

    // Should print an empty/no-data message, not throw
    expect(consoleLog).toHaveBeenCalled();
  });
});

// ── Full response shape with new fields ─────────────────────────────────────────────

describe("full PipelineMetricsResponse with all new fields", () => {
  it("accepts a response object containing all new fields (AC5)", () => {
    const response: PipelineMetricsResponse = {
      ok: true,
      pipeline_metrics: {
        phases: {
          explorer: { pass_rate: 1.0, fail_count: 0, timed_out_count: 0, retry_count: 1, avg_turns: 5, avg_cost: 0.10, total_runs: 1, phases_started: 1, phases_completed: 1 },
        },
        top_failure_reasons: [],
        stuck_by_reason: [],
        recent_bottlenecks: [],
        emitted_at: new Date().toISOString(),
        retry_details: {
          stuck_by_reason: [{ reason: "timeout", phase: "developer", count: 1 }],
          blocked_by_reason: [{ reason: "env blocked", phase: "qa", count: 1 }],
          qa_environment_blocked: 1,
        },
        counters: {
          phases_started: 1,
          phases_completed: 1,
          retries: 1,
          failures: 0,
          recoveries: 0,
          worker_restarts: 0,
          circuit_breaker_hits: 2,
          qa_environment_blocked: 1,
        },
      },
    };

    expect(response.ok).toBe(true);
    expect(response.pipeline_metrics.phases.explorer.retry_count).toBe(1);
    expect(response.pipeline_metrics.retry_details.qa_environment_blocked).toBe(1);
    expect(response.pipeline_metrics.counters.circuit_breaker_hits).toBe(2);
  });
});

// ── Elixir compact pipeline metrics ─────────────────────────────────────────────

describe("renderPipelineMetricsCompact", () => {
  it("renders Elixir pipeline metrics as key=value output", async () => {
    const { renderPipelineMetricsCompact } = await import("../metrics.js");
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    renderPipelineMetricsCompact({
      phases: { qa: { pass_rate: 0.5, fail_count: 1, timed_out_count: 0, retry_count: 2, avg_turns: 3, avg_cost: 0.1, total_runs: 2, phases_started: 2, phases_completed: 1 } },
      top_failure_reasons: [],
      stuck_by_reason: [{ reason: "timeout", phase: "qa", count: 2 }],
      recent_bottlenecks: [],
      emitted_at: "2026-06-26T00:00:00Z",
      retry_details: {
        stuck_by_reason: [],
        blocked_by_reason: [{ reason: "needs_operator", phase: "qa", count: 1 }],
        qa_environment_blocked: 1,
      },
      counters: {
        phases_started: 2,
        phases_completed: 1,
        retries: 2,
        failures: 1,
        recoveries: 0,
        worker_restarts: 0,
        circuit_breaker_hits: 3,
        qa_environment_blocked: 1,
      },
    });

    const output = String(logSpy.mock.calls[0][0]);
    expect(output).toContain("phases=1");
    expect(output).toContain("failures=1");
    expect(output).toContain("stuck=2");
    expect(output).toContain("blocked=1");
    expect(output).toContain("circuit_breakers=3");
  });
});
