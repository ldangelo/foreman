import { describe, it, expect, afterEach } from "vitest";
import { getBudgetFromEnv } from "../config.js";

describe("getBudgetFromEnv", () => {
  const VAR = "FOREMAN_TEST_BUDGET_USD";

  afterEach(() => {
    delete process.env[VAR];
  });

  it("returns the default value when env var is not set", () => {
    delete process.env[VAR];
    expect(getBudgetFromEnv(VAR, 3.00)).toBe(3.00);
  });

  it("returns the default value when env var is empty string", () => {
    process.env[VAR] = "";
    expect(getBudgetFromEnv(VAR, 2.50)).toBe(2.50);
  });

  it("returns the parsed number when env var is a valid positive number", () => {
    process.env[VAR] = "7.50";
    expect(getBudgetFromEnv(VAR, 1.00)).toBe(7.50);
  });

  it("supports integer values", () => {
    process.env[VAR] = "10";
    expect(getBudgetFromEnv(VAR, 1.00)).toBe(10);
  });

  it("returns the default value when env var is a non-numeric string", () => {
    process.env[VAR] = "banana";
    expect(getBudgetFromEnv(VAR, 5.00)).toBe(5.00);
  });

  it("returns the default value when env var is zero", () => {
    process.env[VAR] = "0";
    expect(getBudgetFromEnv(VAR, 3.00)).toBe(3.00);
  });

  it("returns the default value when env var is a negative number", () => {
    process.env[VAR] = "-1.5";
    expect(getBudgetFromEnv(VAR, 3.00)).toBe(3.00);
  });

  it("returns the default value when env var is Infinity (non-finite)", () => {
    process.env[VAR] = "Infinity";
    expect(getBudgetFromEnv(VAR, 3.00)).toBe(3.00);
  });

  it("returns the default value when env var is NaN", () => {
    process.env[VAR] = "NaN";
    expect(getBudgetFromEnv(VAR, 3.00)).toBe(3.00);
  });

  it("uses different defaults for different calls", () => {
    expect(getBudgetFromEnv(VAR, 1.00)).toBe(1.00);
    expect(getBudgetFromEnv(VAR, 5.00)).toBe(5.00);
  });
});
