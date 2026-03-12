import { describe, it, expect } from "vitest";
import {
  ROLE_CONFIGS,
  ALL_AGENT_TOOLS,
  getDisallowedTools,
  explorerPrompt,
  developerPrompt,
  qaPrompt,
  reviewerPrompt,
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

  it("contains AskUserQuestion", () => {
    expect(ALL_AGENT_TOOLS).toContain("AskUserQuestion");
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
    expect(allowedTools).toContain("Write"); // to produce EXPLORER_REPORT.md
    // Must NOT have code-modifying or execution tools
    expect(allowedTools).not.toContain("Edit");
    expect(allowedTools).not.toContain("Bash");
    expect(allowedTools).not.toContain("Agent");
  });

  it("reviewer is read-only (only Read, Write, Glob, Grep)", () => {
    const { allowedTools } = ROLE_CONFIGS.reviewer;
    expect(allowedTools).toContain("Read");
    expect(allowedTools).toContain("Glob");
    expect(allowedTools).toContain("Grep");
    expect(allowedTools).toContain("Write"); // to produce REVIEW.md
    // Must NOT have code-modifying or execution tools
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

  it("developer can use web and todo tools", () => {
    const { allowedTools } = ROLE_CONFIGS.developer;
    expect(allowedTools).toContain("WebFetch");
    expect(allowedTools).toContain("WebSearch");
    expect(allowedTools).toContain("TodoWrite");
  });

  it("qa can run tests (Bash) and edit test files", () => {
    const { allowedTools } = ROLE_CONFIGS.qa;
    expect(allowedTools).toContain("Bash");
    expect(allowedTools).toContain("Read");
    expect(allowedTools).toContain("Write");
    expect(allowedTools).toContain("Edit");
    expect(allowedTools).toContain("Glob");
    expect(allowedTools).toContain("Grep");
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
    // Explorer can't use Bash or Edit
    expect(disallowed).toContain("Bash");
    expect(disallowed).toContain("Edit");
    // Explorer CAN use Read and Write — those should not be disallowed
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
    // `satisfies RoleConfig` ensures this object stays structurally valid if
    // RoleConfig gains new required fields in the future.
    const allToolsConfig = {
      role: "developer" as const,
      model: "claude-sonnet-4-6" as const,
      maxBudgetUsd: 5.00,
      reportFile: "DEVELOPER_REPORT.md",
      allowedTools: [...ALL_AGENT_TOOLS],
    } satisfies RoleConfig;
    expect(getDisallowedTools(allToolsConfig)).toEqual([]);
  });

  it("returns all tools for empty allowedTools", () => {
    // `satisfies RoleConfig` ensures this object stays structurally valid if
    // RoleConfig gains new required fields in the future.
    const noToolsConfig = {
      role: "reviewer" as const,
      model: "claude-sonnet-4-6" as const,
      maxBudgetUsd: 2.00,
      reportFile: "REVIEW.md",
      allowedTools: [],
    } satisfies RoleConfig;
    const disallowed = getDisallowedTools(noToolsConfig);
    expect(disallowed).toEqual([...ALL_AGENT_TOOLS]);
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
