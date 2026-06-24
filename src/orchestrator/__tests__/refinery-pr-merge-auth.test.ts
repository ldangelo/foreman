import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { isGhAuthFailure } from "../refinery.js";

describe("Refinery PR merge auth detection", () => {
  it("detects gh credential failures that should fall back to direct merge", () => {
    expect(isGhAuthFailure(new Error("GraphQL: Bad credentials"))).toBe(true);
    expect(isGhAuthFailure(new Error("HTTP 401: authentication required"))).toBe(true);
    expect(isGhAuthFailure(new Error("run gh auth login to authenticate"))).toBe(true);
  });

  it("does not treat mergeability or CI failures as credential failures", () => {
    expect(isGhAuthFailure(new Error("Pull request is not mergeable"))).toBe(false);
    expect(isGhAuthFailure(new Error("Required status check failed"))).toBe(false);
  });

  it("checks auth failures before GitHub PR cleanup lookup", () => {
    const source = readFileSync(join(process.cwd(), "src/orchestrator/refinery.ts"), "utf8");
    const cleanupComment = source.indexOf("// Local branch cleanup failures");
    const catchBlock = source.slice(source.lastIndexOf("if (!this.isTestRuntime())", cleanupComment), cleanupComment);
    expect(catchBlock.indexOf("if (isGhAuthFailure(err))")).toBeGreaterThanOrEqual(0);
    expect(catchBlock.indexOf("if (isGhAuthFailure(err))")).toBeLessThan(catchBlock.indexOf("this.getExistingPrState(branchName)"));
    expect(catchBlock).toContain("this.getExistingPrState(branchName).catch");
  });
});
