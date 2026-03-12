import { describe, it, expect } from "vitest";
import {
  explorerPrompt,
  developerPrompt,
  formatMemoryContext,
} from "../roles.js";
import type { AgentMemory, Episode, Pattern, Skill } from "../../lib/store.js";

const makeEpisode = (overrides: Partial<Episode> = {}): Episode => ({
  id: "ep-1",
  run_id: "run-1",
  project_id: "proj-1",
  seed_id: "seed-1",
  task_title: "Fix auth bug",
  task_description: "JWT token refresh broken",
  role: "developer",
  outcome: "success",
  duration_ms: 30000,
  cost_usd: 0.42,
  key_learnings: "Used existing JWT middleware in src/auth.ts",
  created_at: "2026-01-01T00:00:00Z",
  ...overrides,
});

const makePattern = (overrides: Partial<Pattern> = {}): Pattern => ({
  id: "pat-1",
  project_id: "proj-1",
  pattern_type: "testing-approach",
  pattern_description: "Use vitest with in-memory SQLite for store tests",
  success_count: 3,
  failure_count: 0,
  first_seen: "2026-01-01T00:00:00Z",
  last_used: "2026-03-01T00:00:00Z",
  created_at: "2026-01-01T00:00:00Z",
  ...overrides,
});

const makeSkill = (overrides: Partial<Skill> = {}): Skill => ({
  id: "skill-1",
  project_id: "proj-1",
  skill_name: "prepared-statements",
  skill_description: "Use parameterized SQL to prevent injection",
  applicable_to_roles: '["developer","qa"]',
  success_examples: null,
  confidence_score: 80,
  created_at: "2026-01-01T00:00:00Z",
  ...overrides,
});

const emptyMemory: AgentMemory = { episodes: [], patterns: [], skills: [] };

describe("formatMemoryContext", () => {
  it("returns empty string for empty memory", () => {
    expect(formatMemoryContext(emptyMemory)).toBe("");
  });

  it("includes episode title, role, cost, and learnings", () => {
    const memory: AgentMemory = {
      episodes: [makeEpisode()],
      patterns: [],
      skills: [],
    };
    const result = formatMemoryContext(memory);
    expect(result).toContain("Past Learnings");
    expect(result).toContain("Fix auth bug");
    expect(result).toContain("developer");
    expect(result).toContain("JWT middleware");
  });

  it("marks failure episodes with ❌", () => {
    const memory: AgentMemory = {
      episodes: [makeEpisode({ outcome: "failure" })],
      patterns: [],
      skills: [],
    };
    const result = formatMemoryContext(memory);
    expect(result).toContain("❌");
  });

  it("marks success episodes with ✅", () => {
    const memory: AgentMemory = {
      episodes: [makeEpisode({ outcome: "success" })],
      patterns: [],
      skills: [],
    };
    const result = formatMemoryContext(memory);
    expect(result).toContain("✅");
  });

  it("includes pattern type, description, and success rate", () => {
    const memory: AgentMemory = {
      episodes: [],
      patterns: [makePattern()],
      skills: [],
    };
    const result = formatMemoryContext(memory);
    expect(result).toContain("Patterns That Have Worked");
    expect(result).toContain("testing-approach");
    expect(result).toContain("vitest");
    expect(result).toContain("100%"); // 3/3 = 100%
  });

  it("includes skill name, confidence, and description", () => {
    const memory: AgentMemory = {
      episodes: [],
      patterns: [],
      skills: [makeSkill()],
    };
    const result = formatMemoryContext(memory);
    expect(result).toContain("Applicable Skills");
    expect(result).toContain("prepared-statements");
    expect(result).toContain("80%");
    expect(result).toContain("parameterized SQL");
  });

  it("truncates very long key_learnings to 300 chars", () => {
    const longLearnings = "x".repeat(1000);
    const memory: AgentMemory = {
      episodes: [makeEpisode({ key_learnings: longLearnings })],
      patterns: [],
      skills: [],
    };
    const result = formatMemoryContext(memory);
    // The truncated text should appear (300 chars of 'x')
    expect(result).toContain("x".repeat(300));
    // But not the full 1000 chars
    expect(result).not.toContain("x".repeat(400));
  });
});

describe("explorerPrompt with memory", () => {
  it("includes memory section when memory has content", () => {
    const memory: AgentMemory = {
      episodes: [makeEpisode()],
      patterns: [],
      skills: [],
    };
    const prompt = explorerPrompt("seed-1", "Fix auth", "JWT refresh", memory);
    expect(prompt).toContain("Cross-Session Memory");
    expect(prompt).toContain("Fix auth bug");
  });

  it("omits memory section when memory is empty", () => {
    const prompt = explorerPrompt("seed-1", "Fix auth", "JWT refresh", emptyMemory);
    expect(prompt).not.toContain("Cross-Session Memory");
  });

  it("omits memory section when memory is undefined", () => {
    const prompt = explorerPrompt("seed-1", "Fix auth", "JWT refresh");
    expect(prompt).not.toContain("Cross-Session Memory");
  });

  it("still includes seed context with memory present", () => {
    const memory: AgentMemory = {
      episodes: [makeEpisode()],
      patterns: [],
      skills: [],
    };
    const prompt = explorerPrompt("seed-abc", "Fix login", "Login fails", memory);
    expect(prompt).toContain("seed-abc");
    expect(prompt).toContain("Fix login");
    expect(prompt).toContain("DO NOT modify");
  });
});

describe("developerPrompt with memory", () => {
  it("includes memory section when memory has content", () => {
    const memory: AgentMemory = {
      episodes: [],
      patterns: [makePattern()],
      skills: [],
    };
    const prompt = developerPrompt("seed-1", "Fix auth", "JWT refresh", true, undefined, memory);
    expect(prompt).toContain("Cross-Session Memory");
    expect(prompt).toContain("vitest");
  });

  it("omits memory section when memory is empty", () => {
    const prompt = developerPrompt("seed-1", "Fix auth", "JWT refresh", true, undefined, emptyMemory);
    expect(prompt).not.toContain("Cross-Session Memory");
  });

  it("omits memory section when memory is undefined", () => {
    const prompt = developerPrompt("seed-1", "Fix auth", "JWT refresh", true);
    expect(prompt).not.toContain("Cross-Session Memory");
  });

  it("includes both feedback and memory when both provided", () => {
    const memory: AgentMemory = {
      episodes: [makeEpisode()],
      patterns: [],
      skills: [],
    };
    const prompt = developerPrompt("seed-1", "Fix auth", "JWT refresh", true, "Tests failed", memory);
    expect(prompt).toContain("Previous Feedback");
    expect(prompt).toContain("Tests failed");
    expect(prompt).toContain("Cross-Session Memory");
  });
});
