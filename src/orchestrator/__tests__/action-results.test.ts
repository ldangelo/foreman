import { describe, expect, it } from "vitest";
import { assertPhaseActionResult } from "../action-results.js";

describe("assertPhaseActionResult", () => {
  it("accepts valid phase action results", () => {
    const result = { success: true, costUsd: 0, turns: 1, tokensIn: 2, tokensOut: 3, outputText: "ok" };
    expect(assertPhaseActionResult("notify", result)).toBe(result);
  });

  it("rejects non-object results", () => {
    expect(() => assertPhaseActionResult("notify", undefined)).toThrow(/phase result object/);
  });

  it("rejects missing success", () => {
    expect(() => assertPhaseActionResult("notify", { costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0 })).toThrow(/success must be a boolean/);
  });

  it("rejects non-finite numeric fields", () => {
    expect(() => assertPhaseActionResult("notify", { success: true, costUsd: Number.NaN, turns: 0, tokensIn: 0, tokensOut: 0 })).toThrow(/costUsd must be a finite number/);
  });
});
