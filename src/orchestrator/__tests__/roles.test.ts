import { describe, it, expect } from "vitest";
import {
  ROLE_CONFIGS,
  explorerPrompt,
  developerPrompt,
  qaPrompt,
  reviewerPrompt,
  parseVerdict,
  extractIssues,
  formatMemoryContext,
} from "../roles.js";
import type { AgentMemory } from "../../lib/store.js";

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

describe("formatMemoryContext", () => {
  const emptyMemory: AgentMemory = { episodes: [], patterns: [], skills: [] };

  it("returns empty string for empty memory", () => {
    expect(formatMemoryContext(emptyMemory)).toBe("");
  });

  it("includes episode summary with outcome icon", () => {
    const memory: AgentMemory = {
      episodes: [{
        id: "ep1", run_id: null, project_id: "p1", seed_id: "sd-1",
        task_title: "Fix auth", task_description: null, role: "developer",
        outcome: "success", duration_ms: 5000, cost_usd: 0.05,
        key_learnings: "Used JWT strategy", created_at: "2026-01-01",
      }],
      patterns: [],
      skills: [],
    };
    const result = formatMemoryContext(memory);
    expect(result).toContain("✅");
    expect(result).toContain("Fix auth");
    expect(result).toContain("Used JWT strategy");
    expect(result).toContain("Past Learnings");
  });

  it("uses ❌ icon for failure episodes", () => {
    const memory: AgentMemory = {
      episodes: [{
        id: "ep1", run_id: null, project_id: "p1", seed_id: "sd-1",
        task_title: "Task", task_description: null, role: "qa",
        outcome: "failure", duration_ms: null, cost_usd: 0.01,
        key_learnings: null, created_at: "2026-01-01",
      }],
      patterns: [],
      skills: [],
    };
    expect(formatMemoryContext(memory)).toContain("❌");
  });

  it("includes patterns with success rate", () => {
    const memory: AgentMemory = {
      episodes: [],
      patterns: [{
        id: "p1", project_id: "proj", pattern_type: "naming",
        pattern_description: "Use kebab-case", success_count: 3, failure_count: 1,
        first_seen: "2026-01-01", last_used: "2026-01-02", created_at: "2026-01-01",
      }],
      skills: [],
    };
    const result = formatMemoryContext(memory);
    expect(result).toContain("Patterns That Have Worked");
    expect(result).toContain("Use kebab-case");
    expect(result).toContain("75%");
  });

  it("includes skills with confidence score", () => {
    const memory: AgentMemory = {
      episodes: [],
      patterns: [],
      skills: [{
        id: "s1", project_id: "proj", skill_name: "TS generics",
        skill_description: "Use generics for reuse", applicable_to_roles: '["developer"]',
        success_examples: null, confidence_score: 85, created_at: "2026-01-01",
      }],
    };
    const result = formatMemoryContext(memory);
    expect(result).toContain("Applicable Skills");
    expect(result).toContain("TS generics");
    expect(result).toContain("85%");
  });

  it("injects memory into explorerPrompt when provided", () => {
    const memory: AgentMemory = {
      episodes: [{
        id: "e1", run_id: null, project_id: "p", seed_id: "s",
        task_title: "Past task", task_description: null, role: "explorer",
        outcome: "success", duration_ms: null, cost_usd: 0.01,
        key_learnings: "Found relevant files", created_at: "2026-01-01",
      }],
      patterns: [],
      skills: [],
    };
    const prompt = explorerPrompt("sd-1", "New task", "description", memory);
    expect(prompt).toContain("Cross-Session Memory");
    expect(prompt).toContain("Past task");
  });

  it("omits memory block in developerPrompt when undefined", () => {
    const prompt = developerPrompt("sd-1", "Task", "desc", true, undefined, undefined);
    expect(prompt).not.toContain("Cross-Session Memory");
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
