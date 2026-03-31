import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import {
  ROLE_CONFIGS,
  buildRoleConfigs,
  ALL_AGENT_TOOLS,
  getDisallowedTools,
  explorerPrompt,
  developerPrompt,
  qaPrompt,
  reviewerPrompt,
  finalizePrompt,
  sentinelPrompt,
  buildPhasePrompt,
  parseVerdict,
  extractIssues,
} from "../roles.js";
import type { RoleConfig } from "../roles.js";

describe("ROLE_CONFIGS", () => {
  it("has configs for all sub-agent roles", () => {
    expect(ROLE_CONFIGS.explorer).toBeDefined();
    expect(ROLE_CONFIGS.developer).toBeDefined();
    expect(ROLE_CONFIGS.qa).toBeDefined();
    expect(ROLE_CONFIGS.reviewer).toBeDefined();
  });

  it("explorer uses MiniMax for cost efficiency", () => {
    expect(ROLE_CONFIGS.explorer.model).toBe("minimax/MiniMax-M2.7");
  });

  it("developer uses MiniMax by default", () => {
    expect(ROLE_CONFIGS.developer.model).toBe("minimax/MiniMax-M2.7");
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

  it("developer budget defaults to $5.00", () => {
    // Use buildRoleConfigs() to get a fresh read with clean env
    const configs = buildRoleConfigs();
    expect(configs.developer.maxBudgetUsd).toBe(5.00);
  });

  it("reviewer budget defaults to $2.00", () => {
    const configs = buildRoleConfigs();
    expect(configs.reviewer.maxBudgetUsd).toBe(2.00);
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
    }
  });

  it("no role uses bypassPermissions", () => {
    for (const [role, config] of Object.entries(ROLE_CONFIGS)) {
      expect(config.permissionMode, `${role} must not use bypassPermissions`).not.toBe("bypassPermissions");
    }
  });

  it("all roles use a non-interactive permission mode", () => {
    for (const [role, config] of Object.entries(ROLE_CONFIGS)) {
      expect(config.permissionMode, `${role} uses interactive mode`).not.toBe("default");
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

  it("sentinelPrompt includes branch, testCommand, and report reference", () => {
    const prompt = sentinelPrompt("main", "npm test");
    expect(prompt).toContain("main");
    expect(prompt).toContain("npm test");
    expect(prompt).toContain("SENTINEL_REPORT.md");
  });

  it("finalizePrompt includes seed context", () => {
    const prompt = finalizePrompt("bd-123", "Fix auth", "run-xyz", "main");
    expect(prompt).toContain("bd-123");
    expect(prompt).toContain("Fix auth");
    expect(prompt).toContain("git add");
    expect(prompt).toContain("git commit");
  });

  it("finalizePrompt interpolates worktreePath into the template", () => {
    const prompt = finalizePrompt("bd-123", "Fix auth", "run-xyz", "main", undefined, "/tmp/worktrees/bd-123");
    expect(prompt).toContain("/tmp/worktrees/bd-123");
  });

  it("finalizePrompt leaves {{worktreePath}} unresolved when not provided", () => {
    // When worktreePath is not given, the template placeholder stays empty string
    // (renderTemplate uses "" for undefined keys, so {{worktreePath}} → "")
    const prompt = finalizePrompt("bd-123", "Fix auth");
    // Should not contain the raw un-interpolated placeholder
    expect(prompt).not.toContain("{{worktreePath}}");
  });
});

describe("buildPhasePrompt — worktreePath propagation", () => {
  it("injects worktreePath into finalize prompt", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-abc",
      seedTitle: "My task",
      seedDescription: "desc",
      runId: "run-1",
      worktreePath: "/home/user/worktrees/bd-abc",
    });
    expect(prompt).toContain("/home/user/worktrees/bd-abc");
  });

  it("does not break other phases when worktreePath is provided", () => {
    // Other phases don't use {{worktreePath}} but it should be harmless to pass it
    const prompt = buildPhasePrompt("developer", {
      seedId: "bd-abc",
      seedTitle: "My task",
      seedDescription: "desc",
      runId: "run-1",
      worktreePath: "/home/user/worktrees/bd-abc",
    });
    expect(prompt).toContain("bd-abc");
    expect(prompt).toContain("My task");
  });

  it("produces empty string for worktreePath when omitted", () => {
    // buildPhasePrompt should not leave {{worktreePath}} un-interpolated
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-abc",
      seedTitle: "My task",
      seedDescription: "desc",
    });
    expect(prompt).not.toContain("{{worktreePath}}");
  });
});

describe("buildPhasePrompt — seedType propagation", () => {
  it("injects seedType into finalize prompt when provided", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-abc",
      seedTitle: "My task",
      seedDescription: "desc",
      runId: "run-1",
      seedType: "test",
    });
    // The finalize prompt uses {{seedType}} — it should be interpolated
    expect(prompt).not.toContain("{{seedType}}");
    expect(prompt).toContain("test");
  });

  it("produces empty string for seedType when omitted", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-abc",
      seedTitle: "My task",
      seedDescription: "desc",
    });
    expect(prompt).not.toContain("{{seedType}}");
  });

  it("finalize prompt contains nothing-to-commit logic for verification beads", () => {
    const prompt = buildPhasePrompt("finalize", {
      seedId: "bd-abc",
      seedTitle: "Verify auth flow",
      seedDescription: "desc",
      runId: "run-1",
      seedType: "test",
    });
    // The updated finalize.md should instruct the agent to check seedType
    expect(prompt).toContain("verification");
    expect(prompt).toContain("nothing to commit");
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
    "FOREMAN_EXPLORER_BUDGET_USD",
    "FOREMAN_DEVELOPER_BUDGET_USD",
    "FOREMAN_QA_BUDGET_USD",
    "FOREMAN_REVIEWER_BUDGET_USD",
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
    expect(configs.explorer.model).toBe("minimax/MiniMax-M2.7");
    expect(configs.developer.model).toBe("minimax/MiniMax-M2.7");
    expect(configs.qa.model).toBe("minimax/MiniMax-M2.7");
    expect(configs.reviewer.model).toBe("minimax/MiniMax-M2.7");
  });

  it("overrides explorer model via FOREMAN_EXPLORER_MODEL", () => {
    process.env["FOREMAN_EXPLORER_MODEL"] = "anthropic/claude-sonnet-4-6";
    const configs = buildRoleConfigs();
    expect(configs.explorer.model).toBe("anthropic/claude-sonnet-4-6");
    // Other phases should still use their defaults (MiniMax now)
    expect(configs.developer.model).toBe("minimax/MiniMax-M2.7");
  });

  it("overrides developer model via FOREMAN_DEVELOPER_MODEL", () => {
    process.env["FOREMAN_DEVELOPER_MODEL"] = "anthropic/claude-opus-4-6";
    const configs = buildRoleConfigs();
    expect(configs.developer.model).toBe("anthropic/claude-opus-4-6");
    // Explorer should still use MiniMax default
    expect(configs.explorer.model).toBe("minimax/MiniMax-M2.7");
  });

  it("overrides qa model via FOREMAN_QA_MODEL", () => {
    process.env["FOREMAN_QA_MODEL"] = "anthropic/claude-haiku-4-5";
    const configs = buildRoleConfigs();
    expect(configs.qa.model).toBe("anthropic/claude-haiku-4-5");
  });

  it("overrides reviewer model via FOREMAN_REVIEWER_MODEL", () => {
    process.env["FOREMAN_REVIEWER_MODEL"] = "anthropic/claude-haiku-4-5";
    const configs = buildRoleConfigs();
    expect(configs.reviewer.model).toBe("anthropic/claude-haiku-4-5");
  });

  it("allows all four phases to be overridden simultaneously", () => {
    process.env["FOREMAN_EXPLORER_MODEL"] = "anthropic/claude-opus-4-6";
    process.env["FOREMAN_DEVELOPER_MODEL"] = "anthropic/claude-haiku-4-5";
    process.env["FOREMAN_QA_MODEL"] = "anthropic/claude-haiku-4-5";
    process.env["FOREMAN_REVIEWER_MODEL"] = "anthropic/claude-haiku-4-5";
    const configs = buildRoleConfigs();
    expect(configs.explorer.model).toBe("anthropic/claude-opus-4-6");
    expect(configs.developer.model).toBe("anthropic/claude-haiku-4-5");
    expect(configs.qa.model).toBe("anthropic/claude-haiku-4-5");
    expect(configs.reviewer.model).toBe("anthropic/claude-haiku-4-5");
  });

  it("ignores empty string env var and falls back to default", () => {
    process.env["FOREMAN_EXPLORER_MODEL"] = "";
    const configs = buildRoleConfigs();
    expect(configs.explorer.model).toBe("minimax/MiniMax-M2.7");
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
    process.env["FOREMAN_DEVELOPER_MODEL"] = "anthropic/claude-haiku-4-5";
    const configs = buildRoleConfigs();
    expect(configs.developer.maxBudgetUsd).toBe(5.00);
  });

  it("overrides budget via FOREMAN_DEVELOPER_BUDGET_USD", () => {
    process.env["FOREMAN_DEVELOPER_BUDGET_USD"] = "10.00";
    const configs = buildRoleConfigs();
    expect(configs.developer.maxBudgetUsd).toBe(10.00);
  });

  it("overrides budget via FOREMAN_EXPLORER_BUDGET_USD", () => {
    process.env["FOREMAN_EXPLORER_BUDGET_USD"] = "2.50";
    const configs = buildRoleConfigs();
    expect(configs.explorer.maxBudgetUsd).toBe(2.50);
  });

  it("report files are not affected by model env var overrides", () => {
    process.env["FOREMAN_EXPLORER_MODEL"] = "anthropic/claude-sonnet-4-6";
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

// ── Tool enforcement guards ──────────────────────────────────────────────

describe("ALL_AGENT_TOOLS", () => {
  it("contains at least 20 tools", () => {
    expect(ALL_AGENT_TOOLS.length).toBeGreaterThanOrEqual(20);
  });

  it("contains core read/write tools", () => {
    expect(ALL_AGENT_TOOLS).toContain("Read");
    expect(ALL_AGENT_TOOLS).toContain("Write");
    expect(ALL_AGENT_TOOLS).toContain("Edit");
    expect(ALL_AGENT_TOOLS).toContain("Glob");
    expect(ALL_AGENT_TOOLS).toContain("Grep");
    expect(ALL_AGENT_TOOLS).toContain("Bash");
  });

  it("contains agent management tools", () => {
    expect(ALL_AGENT_TOOLS).toContain("Agent");
    expect(ALL_AGENT_TOOLS).toContain("TaskOutput");
    expect(ALL_AGENT_TOOLS).toContain("TaskStop");
  });

  it("has no duplicate entries", () => {
    const unique = new Set(ALL_AGENT_TOOLS);
    expect(unique.size).toBe(ALL_AGENT_TOOLS.length);
  });

  it("is sorted alphabetically", () => {
    const sorted = [...ALL_AGENT_TOOLS].sort();
    expect(ALL_AGENT_TOOLS).toEqual(sorted);
  });
});

describe("tool enforcement guards", () => {
  it("all role configs have allowedTools", () => {
    for (const [role, config] of Object.entries(ROLE_CONFIGS)) {
      expect(config.allowedTools, `${role} should have allowedTools`).toBeDefined();
      expect(config.allowedTools.length, `${role} should have at least one allowed tool`).toBeGreaterThan(0);
    }
  });

  it("explorer is read-only (only Read, Write, Glob, Grep)", () => {
    const { allowedTools } = ROLE_CONFIGS.explorer;
    expect(allowedTools).toContain("Read");
    expect(allowedTools).toContain("Glob");
    expect(allowedTools).toContain("Grep");
    expect(allowedTools).toContain("Write");
    expect(allowedTools).not.toContain("Edit");
    expect(allowedTools).not.toContain("Bash");
    expect(allowedTools).not.toContain("Agent");
  });

  it("reviewer is read-only (only Read, Write, Glob, Grep)", () => {
    const { allowedTools } = ROLE_CONFIGS.reviewer;
    expect(allowedTools).toContain("Read");
    expect(allowedTools).toContain("Glob");
    expect(allowedTools).toContain("Grep");
    expect(allowedTools).toContain("Write");
    expect(allowedTools).not.toContain("Edit");
    expect(allowedTools).not.toContain("Bash");
    expect(allowedTools).not.toContain("Agent");
  });

  it("developer has full read/write/execute access", () => {
    const { allowedTools } = ROLE_CONFIGS.developer;
    expect(allowedTools).toContain("Read");
    expect(allowedTools).toContain("Write");
    expect(allowedTools).toContain("Edit");
    expect(allowedTools).toContain("Bash");
    expect(allowedTools).toContain("Glob");
    expect(allowedTools).toContain("Grep");
  });

  it("developer can spawn and manage sub-agents", () => {
    const { allowedTools } = ROLE_CONFIGS.developer;
    expect(allowedTools).toContain("Agent");
    expect(allowedTools).toContain("TaskOutput");
    expect(allowedTools).toContain("TaskStop");
  });

  it("qa can run tests (Bash) and edit test files", () => {
    const { allowedTools } = ROLE_CONFIGS.qa;
    expect(allowedTools).toContain("Bash");
    expect(allowedTools).toContain("Read");
    expect(allowedTools).toContain("Write");
    expect(allowedTools).toContain("Edit");
  });

  it("qa cannot spawn agents", () => {
    const { allowedTools } = ROLE_CONFIGS.qa;
    expect(allowedTools).not.toContain("Agent");
    expect(allowedTools).not.toContain("TaskOutput");
    expect(allowedTools).not.toContain("TaskStop");
  });

  it("no role has AskUserQuestion (pipeline is fully autonomous)", () => {
    for (const [role, config] of Object.entries(ROLE_CONFIGS)) {
      expect(config.allowedTools, `${role} should not have AskUserQuestion`).not.toContain("AskUserQuestion");
    }
  });

  it("explorer and reviewer have the same allowed tools (both read-only)", () => {
    const explorerTools = [...ROLE_CONFIGS.explorer.allowedTools].sort();
    const reviewerTools = [...ROLE_CONFIGS.reviewer.allowedTools].sort();
    expect(explorerTools).toEqual(reviewerTools);
  });

  it("all allowed tools exist in ALL_AGENT_TOOLS", () => {
    const allToolsSet = new Set(ALL_AGENT_TOOLS);
    for (const [role, config] of Object.entries(ROLE_CONFIGS)) {
      for (const tool of config.allowedTools) {
        expect(allToolsSet.has(tool), `${role}: '${tool}' must be in ALL_AGENT_TOOLS`).toBe(true);
      }
    }
  });
});

describe("getDisallowedTools", () => {
  it("returns tools not in allowedTools", () => {
    const disallowed = getDisallowedTools(ROLE_CONFIGS.explorer);
    expect(disallowed).toContain("Bash");
    expect(disallowed).toContain("Edit");
    expect(disallowed).not.toContain("Read");
    expect(disallowed).not.toContain("Write");
  });

  it("disallowed + allowed = ALL_AGENT_TOOLS for each role", () => {
    for (const [role, config] of Object.entries(ROLE_CONFIGS)) {
      const disallowed = getDisallowedTools(config);
      const combined = [...config.allowedTools, ...disallowed].sort();
      const allSorted = [...ALL_AGENT_TOOLS].sort();
      expect(combined, `${role}: allowed + disallowed should equal ALL_AGENT_TOOLS`).toEqual(allSorted);
    }
  });

  it("developer has the fewest disallowed tools (most access)", () => {
    const devDisallowed = getDisallowedTools(ROLE_CONFIGS.developer);
    const explorerDisallowed = getDisallowedTools(ROLE_CONFIGS.explorer);
    const qaDisallowed = getDisallowedTools(ROLE_CONFIGS.qa);
    const reviewerDisallowed = getDisallowedTools(ROLE_CONFIGS.reviewer);
    expect(devDisallowed.length).toBeLessThan(explorerDisallowed.length);
    expect(devDisallowed.length).toBeLessThan(qaDisallowed.length);
    expect(devDisallowed.length).toBeLessThan(reviewerDisallowed.length);
  });

  it("explorer and reviewer have the same disallowed tools", () => {
    const explorerDisallowed = getDisallowedTools(ROLE_CONFIGS.explorer).sort();
    const reviewerDisallowed = getDisallowedTools(ROLE_CONFIGS.reviewer).sort();
    expect(explorerDisallowed).toEqual(reviewerDisallowed);
  });

  it("AskUserQuestion is disallowed for all roles", () => {
    for (const [role, config] of Object.entries(ROLE_CONFIGS)) {
      const disallowed = getDisallowedTools(config);
      expect(disallowed, `${role}: AskUserQuestion must be disallowed`).toContain("AskUserQuestion");
    }
  });

  it("returns empty array for a hypothetical all-tools config", () => {
    const allToolsConfig: RoleConfig = {
      role: "developer",
      model: "anthropic/claude-sonnet-4-6",
      maxBudgetUsd: 5.00,
      permissionMode: "acceptEdits",
      reportFile: "DEVELOPER_REPORT.md",
      allowedTools: [...ALL_AGENT_TOOLS],
    };
    expect(getDisallowedTools(allToolsConfig)).toEqual([]);
  });

  it("returns all tools for empty allowedTools", () => {
    const noToolsConfig: RoleConfig = {
      role: "reviewer",
      model: "anthropic/claude-sonnet-4-6",
      maxBudgetUsd: 2.00,
      permissionMode: "acceptEdits",
      reportFile: "REVIEW.md",
      allowedTools: [],
    };
    const disallowed = getDisallowedTools(noToolsConfig);
    expect(disallowed).toEqual([...ALL_AGENT_TOOLS]);
  });
});
