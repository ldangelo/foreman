import { describe, it, expect, afterEach, vi } from "vitest";
import {
  readBudgetFromEnv,
  getExplorerBudget,
  getDeveloperBudget,
  getQaBudget,
  getReviewerBudget,
  getPlanStepBudget,
  PIPELINE_TIMEOUTS,
  PIPELINE_LIMITS,
  PIPELINE_BUFFERS,
} from "../config.js";

describe("readBudgetFromEnv", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("returns default when env var is not set", () => {
    vi.stubEnv("TEST_BUDGET_USD", undefined as unknown as string);
    expect(readBudgetFromEnv("TEST_BUDGET_USD", 2.5)).toBe(2.5);
  });

  it("returns default when env var is empty string", () => {
    vi.stubEnv("TEST_BUDGET_USD", "");
    expect(readBudgetFromEnv("TEST_BUDGET_USD", 2.5)).toBe(2.5);
  });

  it("reads a valid positive float value from env", () => {
    vi.stubEnv("TEST_BUDGET_USD", "7.50");
    expect(readBudgetFromEnv("TEST_BUDGET_USD", 2.5)).toBe(7.5);
  });

  it("reads an integer value from env", () => {
    vi.stubEnv("TEST_BUDGET_USD", "10");
    expect(readBudgetFromEnv("TEST_BUDGET_USD", 2.5)).toBe(10);
  });

  it("throws for a non-numeric value", () => {
    vi.stubEnv("TEST_BUDGET_USD", "not-a-number");
    expect(() => readBudgetFromEnv("TEST_BUDGET_USD", 2.5)).toThrow(
      'Invalid budget value for TEST_BUDGET_USD: "not-a-number"',
    );
  });

  it("throws for a zero value", () => {
    vi.stubEnv("TEST_BUDGET_USD", "0");
    expect(() => readBudgetFromEnv("TEST_BUDGET_USD", 2.5)).toThrow(
      'Invalid budget value for TEST_BUDGET_USD: "0"',
    );
  });

  it("throws for a negative value", () => {
    vi.stubEnv("TEST_BUDGET_USD", "-1.5");
    expect(() => readBudgetFromEnv("TEST_BUDGET_USD", 2.5)).toThrow(
      'Invalid budget value for TEST_BUDGET_USD: "-1.5"',
    );
  });

  it("includes the env var name in the error message", () => {
    vi.stubEnv("MY_CUSTOM_BUDGET", "bad");
    expect(() => readBudgetFromEnv("MY_CUSTOM_BUDGET", 1.0)).toThrow(
      "MY_CUSTOM_BUDGET",
    );
  });
});

describe("budget getter functions (defaults)", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("getExplorerBudget returns $1.00 by default", () => {
    vi.stubEnv("FOREMAN_EXPLORER_BUDGET_USD", undefined as unknown as string);
    expect(getExplorerBudget()).toBe(1.00);
  });

  it("getDeveloperBudget returns $5.00 by default", () => {
    vi.stubEnv("FOREMAN_DEVELOPER_BUDGET_USD", undefined as unknown as string);
    expect(getDeveloperBudget()).toBe(5.00);
  });

  it("getQaBudget returns $3.00 by default", () => {
    vi.stubEnv("FOREMAN_QA_BUDGET_USD", undefined as unknown as string);
    expect(getQaBudget()).toBe(3.00);
  });

  it("getReviewerBudget returns $2.00 by default", () => {
    vi.stubEnv("FOREMAN_REVIEWER_BUDGET_USD", undefined as unknown as string);
    expect(getReviewerBudget()).toBe(2.00);
  });

  it("getPlanStepBudget returns $3.00 by default", () => {
    vi.stubEnv("FOREMAN_PLAN_STEP_BUDGET_USD", undefined as unknown as string);
    expect(getPlanStepBudget()).toBe(3.00);
  });
});

describe("budget getter functions (custom env vars)", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("getExplorerBudget reads FOREMAN_EXPLORER_BUDGET_USD", () => {
    vi.stubEnv("FOREMAN_EXPLORER_BUDGET_USD", "2.00");
    expect(getExplorerBudget()).toBe(2.00);
  });

  it("getDeveloperBudget reads FOREMAN_DEVELOPER_BUDGET_USD", () => {
    vi.stubEnv("FOREMAN_DEVELOPER_BUDGET_USD", "10.00");
    expect(getDeveloperBudget()).toBe(10.00);
  });

  it("getQaBudget reads FOREMAN_QA_BUDGET_USD", () => {
    vi.stubEnv("FOREMAN_QA_BUDGET_USD", "4.50");
    expect(getQaBudget()).toBe(4.50);
  });

  it("getReviewerBudget reads FOREMAN_REVIEWER_BUDGET_USD", () => {
    vi.stubEnv("FOREMAN_REVIEWER_BUDGET_USD", "3.00");
    expect(getReviewerBudget()).toBe(3.00);
  });

  it("getPlanStepBudget reads FOREMAN_PLAN_STEP_BUDGET_USD", () => {
    vi.stubEnv("FOREMAN_PLAN_STEP_BUDGET_USD", "5.00");
    expect(getPlanStepBudget()).toBe(5.00);
  });
});

describe("PIPELINE_TIMEOUTS defaults", () => {
  it("progressFlushMs defaults to 2000", () => {
    expect(PIPELINE_TIMEOUTS.progressFlushMs).toBe(2_000);
  });

  it("gitOperationMs defaults to 30000", () => {
    expect(PIPELINE_TIMEOUTS.gitOperationMs).toBe(30_000);
  });

  it("beadClosureMs defaults to 10000", () => {
    expect(PIPELINE_TIMEOUTS.beadClosureMs).toBe(10_000);
  });

  it("testExecutionMs defaults to 300000", () => {
    expect(PIPELINE_TIMEOUTS.testExecutionMs).toBe(5 * 60 * 1000);
  });

  it("llmDecomposeMs defaults to 600000", () => {
    expect(PIPELINE_TIMEOUTS.llmDecomposeMs).toBe(600_000);
  });

  it("monitorPollMs defaults to 3000", () => {
    expect(PIPELINE_TIMEOUTS.monitorPollMs).toBe(3_000);
  });

  it("staleRunHours defaults to 24", () => {
    expect(PIPELINE_TIMEOUTS.staleRunHours).toBe(24);
  });
});

describe("PIPELINE_LIMITS defaults", () => {
  it("maxDevRetries defaults to 2", () => {
    expect(PIPELINE_LIMITS.maxDevRetries).toBe(2);
  });

  it("maxRecoveryRetries defaults to 3", () => {
    expect(PIPELINE_LIMITS.maxRecoveryRetries).toBe(3);
  });

  it("stuckDetectionMinutes defaults to 15", () => {
    expect(PIPELINE_LIMITS.stuckDetectionMinutes).toBe(15);
  });
});

describe("PIPELINE_BUFFERS defaults", () => {
  it("maxBufferBytes defaults to 10MB", () => {
    expect(PIPELINE_BUFFERS.maxBufferBytes).toBe(10 * 1024 * 1024);
  });
});
