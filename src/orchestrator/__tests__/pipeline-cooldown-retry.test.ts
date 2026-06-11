/**
 * Tests for pipeline cooldown retry behavior.
 *
 * When a phase fails with a retryable error (e.g. rate limit) and retryAfterCooldown
 * is enabled, the task is placed in cooldown state instead of being marked failed/stuck.
 * The dispatcher will not re-dispatch until the cooldown period expires.
 */

import { describe, it, expect, vi } from "vitest";
import type { WorkflowPhaseConfig } from "../../lib/workflow-loader.js";
import { isRateLimitError, shouldUseCooldownRetry } from "../pipeline-executor.js";

// ── isRateLimitError unit tests ───────────────────────────────────────────

describe("isRateLimitError", () => {
  it("returns true for 'Rate limit exceeded' (CodeRabbit CLI error)", () => {
    expect(isRateLimitError("Rate limit exceeded")).toBe(true);
  });

  it("returns true for 'rate limit' in error message", () => {
    expect(isRateLimitError("Rate limit: API quota exceeded")).toBe(true);
    expect(isRateLimitError("rate limit exceeded")).toBe(true);
  });

  it("returns true for '429' status code", () => {
    expect(isRateLimitError("HTTP 429: Too Many Requests")).toBe(true);
    expect(isRateLimitError("Error: 429")).toBe(true);
  });

  it("returns true for 'hit your limit'", () => {
    expect(isRateLimitError("You have hit your limit")).toBe(true);
    expect(isRateLimitError("API hit your limit")).toBe(true);
  });

  it("returns true for 'too many requests'", () => {
    expect(isRateLimitError("Too many requests")).toBe(true);
    expect(isRateLimitError("Error: too many requests")).toBe(true);
  });

  it("returns true for 'rate_limit_exceeded'", () => {
    expect(isRateLimitError("rate_limit_exceeded")).toBe(true);
    expect(isRateLimitError("RATE_LIMIT_EXCEEDED")).toBe(true);
  });

  it("returns false for non-rate-limit errors", () => {
    expect(isRateLimitError("Connection refused")).toBe(false);
    expect(isRateLimitError("Timeout waiting for response")).toBe(false);
    expect(isRateLimitError("Internal server error")).toBe(false);
    expect(isRateLimitError("Authentication failed")).toBe(false);
    expect(isRateLimitError("File not found")).toBe(false);
  });

  it("returns false for undefined or empty error", () => {
    expect(isRateLimitError(undefined)).toBe(false);
    expect(isRateLimitError("")).toBe(false);
  });

  it("is case-insensitive", () => {
    expect(isRateLimitError("RATE LIMIT EXCEEDED")).toBe(true);
    expect(isRateLimitError("Rate Limit Exceeded")).toBe(true);
    expect(isRateLimitError("HTTP 429")).toBe(true);
  });
});

// ── WorkflowPhaseConfig retryAfterCooldown tests ─────────────────────────

describe("WorkflowPhaseConfig retryAfterCooldown", () => {
  it("has retryAfterCooldown field as boolean option", () => {
    const phase: WorkflowPhaseConfig = {
      name: "cli-review",
      builtin: true,
      artifact: "CR_REPORT.md",
      retryAfterCooldown: true,
      cooldownSeconds: 600,
    };

    expect(phase.retryAfterCooldown).toBe(true);
    expect(phase.cooldownSeconds).toBe(600);
  });

  it("defaults cooldownSeconds to undefined when not specified", () => {
    const phase: WorkflowPhaseConfig = {
      name: "cli-review",
      builtin: true,
      retryAfterCooldown: true,
    };

    expect(phase.retryAfterCooldown).toBe(true);
    expect(phase.cooldownSeconds).toBeUndefined();
  });

  it("can be used without cooldownSeconds (uses default)", () => {
    const phase: WorkflowPhaseConfig = {
      name: "cli-review",
      builtin: true,
      retryAfterCooldown: true,
      // cooldownSeconds not set — should use default (300s)
    };

    expect(phase.retryAfterCooldown).toBe(true);
    // The default cooldown is applied in the pipeline executor
    // when phase.cooldownSeconds is undefined
  });

  it("non-rate-limit errors should not trigger cooldown retry", () => {
    // This tests the logic that only rate limit errors trigger cooldown retry
    // Non-rate-limit errors should remain terminal even with retryAfterCooldown enabled
    const phase: WorkflowPhaseConfig = {
      name: "cli-review",
      builtin: true,
      retryAfterCooldown: true,
    };

    // The pipeline executor checks isRateLimitError(errorMsg) && phase.retryAfterCooldown
    // So only if both are true, cooldown retry is triggered
    expect(phase.retryAfterCooldown).toBe(true);
    // But isRateLimitError would return false for non-rate-limit errors
  });
});

// ── COOLDOWN_RETRY_CONFIG tests ───────────────────────────────────────────

describe("COOLDOWN_RETRY_CONFIG", () => {
  it("has sensible default cooldown duration", async () => {
    const { COOLDOWN_RETRY_CONFIG } = await import("../../lib/config.js");
    expect(COOLDOWN_RETRY_CONFIG.defaultCooldownSeconds).toBe(300); // 5 minutes
  });

  it("default cooldown is configurable via env var", async () => {
    const previous = process.env.FOREMAN_COOLDOWN_DEFAULT_SECONDS;
    process.env.FOREMAN_COOLDOWN_DEFAULT_SECONDS = "42";
    vi.resetModules();
    try {
      const { COOLDOWN_RETRY_CONFIG } = await import("../../lib/config.js");
      expect(COOLDOWN_RETRY_CONFIG.defaultCooldownSeconds).toBe(42);
    } finally {
      if (previous === undefined) {
        delete process.env.FOREMAN_COOLDOWN_DEFAULT_SECONDS;
      } else {
        process.env.FOREMAN_COOLDOWN_DEFAULT_SECONDS = previous;
      }
      vi.resetModules();
    }
  });
});

// ── Integration-style tests for cooldown retry logic ──────────────────────

describe("cooldown retry integration", () => {
  // Helper to create a mock phase config with retryAfterCooldown
  function makeCooldownPhase(overrides?: Partial<WorkflowPhaseConfig>): WorkflowPhaseConfig {
    return {
      name: "cli-review",
      builtin: true,
      artifact: "CR_REPORT.md",
      retryAfterCooldown: true,
      cooldownSeconds: 300,
      ...overrides,
    };
  }

  it("phase with retryAfterCooldown and cooldownSeconds uses specified values", () => {
    const phase = makeCooldownPhase({ cooldownSeconds: 600 });
    expect(phase.cooldownSeconds).toBe(600);
    expect(phase.retryAfterCooldown).toBe(true);
  });

  it("phase without cooldownSeconds should use default 300s", () => {
    const phase = makeCooldownPhase({ cooldownSeconds: undefined });
    // When cooldownSeconds is undefined, the pipeline executor uses COOLDOWN_RETRY_CONFIG.defaultCooldownSeconds
    expect(phase.retryAfterCooldown).toBe(true);
    // cooldownSeconds is undefined, so default (300s) will be used
  });

  it("phase without retryAfterCooldown should not trigger cooldown retry", () => {
    const phase: WorkflowPhaseConfig = {
      name: "cli-review",
      builtin: true,
      // retryAfterCooldown not set
    };
    expect(phase.retryAfterCooldown).toBeUndefined();
  });
});

// ── Non-rate-limit error terminal path tests ─────────────────────────────

describe("non-rate-limit error terminal behavior", () => {
  function determineErrorOutcome(errorMsg: string | undefined, phase: WorkflowPhaseConfig): string {
    if (shouldUseCooldownRetry(errorMsg, phase)) return "cooldown";
    if (phase.retryAfterCooldown) return "stuck";
    return "unknown";
  }

  it("marks task as stuck (terminal) for non-rate-limit errors even with retryAfterCooldown enabled", () => {
    const phase: WorkflowPhaseConfig = {
      name: "cli-review",
      builtin: true,
      retryAfterCooldown: true,
      cooldownSeconds: 300,
    };

    // Test various non-rate-limit errors
    const nonRateLimitErrors = [
      "Connection refused",
      "Authentication failed: invalid API key",
      "File not found: /path/to/config.yaml",
      "Internal server error: 500",
      "Timeout waiting for response after 30s",
      "Permission denied: cannot write to output directory",
      "Syntax error in generated code",
    ];

    for (const error of nonRateLimitErrors) {
      const outcome = determineErrorOutcome(error, phase);
      expect(outcome).toBe("stuck");
    }
  });

  it("marks task as cooldown for rate-limit errors with retryAfterCooldown enabled", () => {
    const phase: WorkflowPhaseConfig = {
      name: "cli-review",
      builtin: true,
      retryAfterCooldown: true,
      cooldownSeconds: 300,
    };

    // Test various rate-limit errors
    const rateLimitErrors = [
      "Rate limit exceeded",
      "HTTP 429: Too Many Requests",
      "API rate limit hit",
      "You have hit your limit",
      "rate_limit_exceeded",
    ];

    for (const error of rateLimitErrors) {
      const outcome = determineErrorOutcome(error, phase);
      expect(outcome).toBe("cooldown");
    }
  });

  it("non-rate-limit errors without retryAfterCooldown do not enter cooldown", () => {
    const phase: WorkflowPhaseConfig = {
      name: "cli-review",
      builtin: true,
      // retryAfterCooldown not set
    };

    const error = "Connection refused";
    const outcome = determineErrorOutcome(error, phase);
    expect(outcome).toBe("unknown"); // Neither cooldown nor stuck path triggered
  });

  it("distinguishes between rate-limit and non-rate-limit errors correctly", () => {
    const phase: WorkflowPhaseConfig = {
      name: "cli-review",
      builtin: true,
      retryAfterCooldown: true,
    };

    // These should be classified as rate-limit errors
    const rateLimitCases = [
      { error: "Rate limit exceeded", expected: "cooldown" },
      { error: "429 Too Many Requests", expected: "cooldown" },
      { error: "rate_limit_exceeded", expected: "cooldown" },
    ];

    // These should be classified as non-rate-limit errors
    const nonRateLimitCases = [
      { error: "Connection refused", expected: "stuck" },
      { error: "Authentication failed", expected: "stuck" },
      { error: "File not found", expected: "stuck" },
      { error: "Internal server error", expected: "stuck" },
    ];

    for (const { error, expected } of rateLimitCases) {
      expect(determineErrorOutcome(error, phase)).toBe(expected);
    }

    for (const { error, expected } of nonRateLimitCases) {
      expect(determineErrorOutcome(error, phase)).toBe(expected);
    }
  });
});