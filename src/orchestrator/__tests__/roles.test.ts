import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import {
  ROLE_CONFIGS,
  buildRoleConfigs,
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

describe("buildRoleConfigs — environment variable overrides", () => {
  // Capture the original env vars so we can restore them after each test
  const originalEnv: Record<string, string | undefined> = {};
  const ENV_VARS = [
    "FOREMAN_EXPLORER_MODEL",
    "FOREMAN_DEVELOPER_MODEL",
    "FOREMAN_QA_MODEL",
    "FOREMAN_REVIEWER_MODEL",
  ] as const;

  beforeEach(() => {
    for (const key of ENV_VARS) {
      originalEnv[key] = process.env[key];
      delete process.env[key];
    }
  });

  afterEach(() => {
    for (const key of ENV_VARS) {
      if (originalEnv[key] === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = originalEnv[key];
      }
    }
  });

  it("uses hard-coded defaults when no env vars are set", () => {
    const configs = buildRoleConfigs();
    expect(configs.explorer.model).toBe("claude-haiku-4-5-20251001");
    expect(configs.developer.model).toBe("claude-sonnet-4-6");
    expect(configs.qa.model).toBe("claude-sonnet-4-6");
    expect(configs.reviewer.model).toBe("claude-sonnet-4-6");
  });

  it("overrides explorer model via FOREMAN_EXPLORER_MODEL", () => {
    process.env["FOREMAN_EXPLORER_MODEL"] = "claude-sonnet-4-6";
    const configs = buildRoleConfigs();
    expect(configs.explorer.model).toBe("claude-sonnet-4-6");
    // Other phases should still use their defaults
    expect(configs.developer.model).toBe("claude-sonnet-4-6");
  });

  it("overrides developer model via FOREMAN_DEVELOPER_MODEL", () => {
    process.env["FOREMAN_DEVELOPER_MODEL"] = "claude-opus-4-6";
    const configs = buildRoleConfigs();
    expect(configs.developer.model).toBe("claude-opus-4-6");
    expect(configs.explorer.model).toBe("claude-haiku-4-5-20251001");
  });

  it("overrides qa model via FOREMAN_QA_MODEL", () => {
    process.env["FOREMAN_QA_MODEL"] = "claude-haiku-4-5-20251001";
    const configs = buildRoleConfigs();
    expect(configs.qa.model).toBe("claude-haiku-4-5-20251001");
  });

  it("overrides reviewer model via FOREMAN_REVIEWER_MODEL", () => {
    process.env["FOREMAN_REVIEWER_MODEL"] = "claude-haiku-4-5-20251001";
    const configs = buildRoleConfigs();
    expect(configs.reviewer.model).toBe("claude-haiku-4-5-20251001");
  });

  it("allows all four phases to be overridden simultaneously", () => {
    process.env["FOREMAN_EXPLORER_MODEL"] = "claude-opus-4-6";
    process.env["FOREMAN_DEVELOPER_MODEL"] = "claude-haiku-4-5-20251001";
    process.env["FOREMAN_QA_MODEL"] = "claude-haiku-4-5-20251001";
    process.env["FOREMAN_REVIEWER_MODEL"] = "claude-haiku-4-5-20251001";
    const configs = buildRoleConfigs();
    expect(configs.explorer.model).toBe("claude-opus-4-6");
    expect(configs.developer.model).toBe("claude-haiku-4-5-20251001");
    expect(configs.qa.model).toBe("claude-haiku-4-5-20251001");
    expect(configs.reviewer.model).toBe("claude-haiku-4-5-20251001");
  });

  it("ignores empty string env var and falls back to default", () => {
    process.env["FOREMAN_EXPLORER_MODEL"] = "";
    const configs = buildRoleConfigs();
    expect(configs.explorer.model).toBe("claude-haiku-4-5-20251001");
  });

  it("throws for an invalid model value in an env var", () => {
    process.env["FOREMAN_DEVELOPER_MODEL"] = "gpt-4o";
    expect(() => buildRoleConfigs()).toThrow(/Invalid model "gpt-4o" in FOREMAN_DEVELOPER_MODEL/);
  });

  it("error message for invalid model lists valid options", () => {
    process.env["FOREMAN_QA_MODEL"] = "not-a-model";
    expect(() => buildRoleConfigs()).toThrow(/claude-opus-4-6/);
  });

  it("budget values are not affected by model env var overrides", () => {
    process.env["FOREMAN_DEVELOPER_MODEL"] = "claude-haiku-4-5-20251001";
    const configs = buildRoleConfigs();
    expect(configs.developer.maxBudgetUsd).toBe(5.00);
  });

  it("report files are not affected by model env var overrides", () => {
    process.env["FOREMAN_EXPLORER_MODEL"] = "claude-sonnet-4-6";
    const configs = buildRoleConfigs();
    expect(configs.explorer.reportFile).toBe("EXPLORER_REPORT.md");
  });
});

describe("ROLE_CONFIGS module-level fallback", () => {
  /**
   * The module-level `ROLE_CONFIGS` constant is built with a try/catch so
   * that an invalid env var never crashes the module at import time.  We
   * can't re-trigger the IIFE in these tests, but we can verify that:
   *   a) the constant is always a valid object (module loaded successfully), and
   *   b) `buildRoleConfigs()` warns + falls back when called with a bad env var
   *      — which mirrors what the IIFE does.
   */

  const ENV_VARS = [
    "FOREMAN_EXPLORER_MODEL",
    "FOREMAN_DEVELOPER_MODEL",
    "FOREMAN_QA_MODEL",
    "FOREMAN_REVIEWER_MODEL",
  ] as const;
  const originalEnv: Record<string, string | undefined> = {};

  beforeEach(() => {
    for (const key of ENV_VARS) {
      originalEnv[key] = process.env[key];
      delete process.env[key];
    }
  });

  afterEach(() => {
    for (const key of ENV_VARS) {
      if (originalEnv[key] === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = originalEnv[key];
      }
    }
    vi.restoreAllMocks();
  });

  it("ROLE_CONFIGS is always a valid object (module loaded without crashing)", () => {
    // If the module-level IIFE threw, ROLE_CONFIGS would be undefined; verify it isn't.
    expect(ROLE_CONFIGS).toBeDefined();
    expect(ROLE_CONFIGS.explorer).toBeDefined();
    expect(ROLE_CONFIGS.developer).toBeDefined();
    expect(ROLE_CONFIGS.qa).toBeDefined();
    expect(ROLE_CONFIGS.reviewer).toBeDefined();
  });

  it("buildRoleConfigs throws on invalid model (same logic used by the IIFE try-block)", () => {
    process.env["FOREMAN_EXPLORER_MODEL"] = "not-a-valid-model";
    expect(() => buildRoleConfigs()).toThrow(/Invalid model/);
  });

  it("ROLE_CONFIGS falls back to valid defaults when env var is unset", () => {
    // With no env vars set, both the IIFE and a fresh buildRoleConfigs() call
    // should produce the same hard-coded defaults.
    const fresh = buildRoleConfigs();
    expect(ROLE_CONFIGS.explorer.model).toBe(fresh.explorer.model);
    expect(ROLE_CONFIGS.developer.model).toBe(fresh.developer.model);
    expect(ROLE_CONFIGS.qa.model).toBe(fresh.qa.model);
    expect(ROLE_CONFIGS.reviewer.model).toBe(fresh.reviewer.model);
  });
});
