import { describe, it, expect } from "vitest";
import {
  ROLE_CONFIGS,
  explorerPrompt,
  developerPrompt,
  qaPrompt,
  reviewerPrompt,
  parseVerdict,
  extractIssues,
} from "../roles.js";

describe("ROLE_CONFIGS", () => {
  it("has configs for all sub-agent roles", () => {
    expect(ROLE_CONFIGS.explorer).toBeDefined();
    expect(ROLE_CONFIGS.developer).toBeDefined();
    expect(ROLE_CONFIGS.qa).toBeDefined();
    expect(ROLE_CONFIGS.reviewer).toBeDefined();
  });

  it("explorer uses haiku for cost efficiency", () => {
    expect(ROLE_CONFIGS.explorer.model).toBe("claude-haiku-4-5-20251001");
  });

  it("developer uses sonnet by default", () => {
    expect(ROLE_CONFIGS.developer.model).toBe("claude-sonnet-4-6");
  });

  it("explorer produces EXPLORER_REPORT.md", () => {
    expect(ROLE_CONFIGS.explorer.reportFile).toBe("EXPLORER_REPORT.md");
  });

  it("developer produces DEVELOPER_REPORT.md", () => {
    expect(ROLE_CONFIGS.developer.reportFile).toBe("DEVELOPER_REPORT.md");
  });

  it("all roles have positive maxBudgetUsd values", () => {
    for (const [role, config] of Object.entries(ROLE_CONFIGS)) {
      expect(config.maxBudgetUsd, `${role} should have a positive budget`).toBeGreaterThan(0);
    }
  });

  it("explorer has lower budget than developer (haiku vs sonnet)", () => {
    expect(ROLE_CONFIGS.explorer.maxBudgetUsd).toBeLessThan(ROLE_CONFIGS.developer.maxBudgetUsd);
  });

  it("developer budget is $5.00", () => {
    expect(ROLE_CONFIGS.developer.maxBudgetUsd).toBe(5.00);
  });

  it("reviewer budget is $2.00", () => {
    expect(ROLE_CONFIGS.reviewer.maxBudgetUsd).toBe(2.00);
  });

  it("all role configs have no maxTurns property", () => {
    for (const [role, config] of Object.entries(ROLE_CONFIGS)) {
      expect(config, `${role} should not have maxTurns`).not.toHaveProperty("maxTurns");
    }
  });
});

describe("DCG (Destructive Command Guard) permission modes", () => {
  it("all roles have a permissionMode configured", () => {
    for (const [role, config] of Object.entries(ROLE_CONFIGS)) {
      expect(config.permissionMode, `${role} should have a permissionMode`).toBeDefined();
      expect(typeof config.permissionMode, `${role} permissionMode should be a string`).toBe("string");
    }
  });

  it("no role uses bypassPermissions (DCG enforcement)", () => {
    for (const [role, config] of Object.entries(ROLE_CONFIGS)) {
      expect(
        config.permissionMode,
        `${role} must not use bypassPermissions — DCG requires guarded permission mode`,
      ).not.toBe("bypassPermissions");
    }
  });

  it("all roles use a non-interactive permission mode (safe for detached workers)", () => {
    // Workers run as detached processes with no user interaction.
    // 'default' would hang waiting for user input — must use acceptEdits or dontAsk.
    const interactiveModes = ["default"];
    for (const [role, config] of Object.entries(ROLE_CONFIGS)) {
      expect(
        interactiveModes,
        `${role} uses interactive permission mode '${config.permissionMode}' which would hang in detached worker`,
      ).not.toContain(config.permissionMode);
    }
  });

  it("explorer uses acceptEdits to allow writing EXPLORER_REPORT.md", () => {
    expect(ROLE_CONFIGS.explorer.permissionMode).toBe("acceptEdits");
  });

  it("developer uses acceptEdits for file write access", () => {
    expect(ROLE_CONFIGS.developer.permissionMode).toBe("acceptEdits");
  });

  it("qa uses acceptEdits for test runs and file modifications", () => {
    expect(ROLE_CONFIGS.qa.permissionMode).toBe("acceptEdits");
  });

  it("reviewer uses acceptEdits to allow writing REVIEW.md", () => {
    expect(ROLE_CONFIGS.reviewer.permissionMode).toBe("acceptEdits");
  });

  it("permissionMode values are valid SDK PermissionMode literals", () => {
    const validModes = ["default", "acceptEdits", "bypassPermissions", "plan", "dontAsk"];
    for (const [role, config] of Object.entries(ROLE_CONFIGS)) {
      expect(
        validModes,
        `${role} has invalid permissionMode: '${config.permissionMode}'`,
      ).toContain(config.permissionMode);
    }
  });
});

describe("prompt templates", () => {
  it("explorerPrompt includes seed context and read-only instructions", () => {
    const prompt = explorerPrompt("bd-123", "Fix auth", "JWT token refresh");
    expect(prompt).toContain("bd-123");
    expect(prompt).toContain("Fix auth");
    expect(prompt).toContain("JWT token refresh");
    expect(prompt).toContain("DO NOT modify");
    expect(prompt).toContain("EXPLORER_REPORT.md");
  });

  it("developerPrompt includes seed context", () => {
    const prompt = developerPrompt("bd-123", "Fix auth", "JWT refresh", true);
    expect(prompt).toContain("bd-123");
    expect(prompt).toContain("EXPLORER_REPORT.md");
  });

  it("developerPrompt includes feedback when provided", () => {
    const prompt = developerPrompt("bd-123", "Fix auth", "desc", false, "Tests failed: auth.test.ts");
    expect(prompt).toContain("Previous Feedback");
    expect(prompt).toContain("Tests failed: auth.test.ts");
  });

  it("developerPrompt omits feedback section when none given", () => {
    const prompt = developerPrompt("bd-123", "Fix auth", "desc", false);
    expect(prompt).not.toContain("Previous Feedback");
  });

  it("qaPrompt includes seed reference", () => {
    const prompt = qaPrompt("bd-123", "Fix auth");
    expect(prompt).toContain("bd-123");
    expect(prompt).toContain("QA_REPORT.md");
  });

  it("reviewerPrompt includes seed context and read-only rules", () => {
    const prompt = reviewerPrompt("bd-123", "Fix auth", "JWT refresh");
    expect(prompt).toContain("bd-123");
    expect(prompt).toContain("REVIEW.md");
    expect(prompt).toContain("DO NOT modify");
  });
});

describe("parseVerdict", () => {
  it("parses PASS verdict", () => {
    expect(parseVerdict("## Verdict: PASS\nAll good")).toBe("pass");
  });

  it("parses FAIL verdict", () => {
    expect(parseVerdict("## Verdict: FAIL\nIssues found")).toBe("fail");
  });

  it("is case-insensitive", () => {
    expect(parseVerdict("## Verdict: pass")).toBe("pass");
    expect(parseVerdict("## Verdict: Pass")).toBe("pass");
  });

  it("returns unknown when no verdict found", () => {
    expect(parseVerdict("No verdict here")).toBe("unknown");
  });

  it("returns unknown for empty content", () => {
    expect(parseVerdict("")).toBe("unknown");
  });
});

describe("extractIssues", () => {
  it("extracts issues section", () => {
    const report = `# Review
## Verdict: FAIL
## Issues
- **[CRITICAL]** auth.ts:42 — missing null check
- **[WARNING]** user.ts:10 — unused import
## Positive Notes
Good structure`;
    const issues = extractIssues(report);
    expect(issues).toContain("auth.ts:42");
    expect(issues).toContain("user.ts:10");
    expect(issues).not.toContain("Good structure");
  });

  it("returns fallback when no issues section", () => {
    expect(extractIssues("No issues section")).toContain("no specific issues");
  });
});
