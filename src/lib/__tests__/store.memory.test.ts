import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../store.js";

describe("ForemanStore — CASS Memory", () => {
  let store: ForemanStore;
  let tmpDir: string;
  let projectId: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-memory-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
    const project = store.registerProject("memory-test", "/tmp/memory-test");
    projectId = project.id;
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  // ── Episodes ──────────────────────────────────────────────────────────

  describe("episodes", () => {
    it("stores and retrieves a successful episode", () => {
      const ep = store.storeEpisode(
        projectId,
        "run-1",
        "seed-abc",
        "Fix login bug",
        "JWT token refresh broken",
        "developer",
        "success",
        0.42,
        30000,
        "Used JWT middleware pattern from auth.ts",
      );

      expect(ep.id).toBeDefined();
      expect(ep.project_id).toBe(projectId);
      expect(ep.seed_id).toBe("seed-abc");
      expect(ep.task_title).toBe("Fix login bug");
      expect(ep.role).toBe("developer");
      expect(ep.outcome).toBe("success");
      expect(ep.cost_usd).toBeCloseTo(0.42);
      expect(ep.duration_ms).toBe(30000);
      expect(ep.key_learnings).toContain("JWT middleware");
    });

    it("stores a failure episode with no learnings", () => {
      const ep = store.storeEpisode(
        projectId,
        null,
        "seed-xyz",
        "Migrate DB",
        null,
        "explorer",
        "failure",
        0.10,
        undefined,
        undefined,
      );

      expect(ep.outcome).toBe("failure");
      expect(ep.run_id).toBeNull();
      expect(ep.task_description).toBeNull();
      expect(ep.duration_ms).toBeNull();
      expect(ep.key_learnings).toBeNull();
    });

    it("getRelevantEpisodes filters by projectId", () => {
      const p2 = store.registerProject("other", "/other");
      store.storeEpisode(projectId, null, "seed-1", "Task A", null, "developer", "success", 0.1);
      store.storeEpisode(p2.id, null, "seed-2", "Task B", null, "developer", "success", 0.2);

      const results = store.getRelevantEpisodes(projectId);
      expect(results).toHaveLength(1);
      expect(results[0].task_title).toBe("Task A");
    });

    it("getRelevantEpisodes filters by seedId", () => {
      store.storeEpisode(projectId, null, "seed-1", "Task A", null, "developer", "success", 0.1);
      store.storeEpisode(projectId, null, "seed-2", "Task B", null, "developer", "success", 0.2);

      const results = store.getRelevantEpisodes(projectId, "seed-1");
      expect(results).toHaveLength(1);
      expect(results[0].task_title).toBe("Task A");
    });

    it("getRelevantEpisodes filters by role", () => {
      store.storeEpisode(projectId, null, "seed-1", "Task A", null, "developer", "success", 0.1);
      store.storeEpisode(projectId, null, "seed-1", "Task A", null, "explorer", "success", 0.05);

      const devEps = store.getRelevantEpisodes(projectId, undefined, "developer");
      expect(devEps).toHaveLength(1);
      expect(devEps[0].role).toBe("developer");
    });

    it("getRelevantEpisodes returns most recent first", () => {
      store.storeEpisode(projectId, null, "seed-1", "Old Task", null, "developer", "success", 0.1);
      store.storeEpisode(projectId, null, "seed-2", "New Task", null, "developer", "success", 0.2);

      const results = store.getRelevantEpisodes(projectId);
      expect(results[0].task_title).toBe("New Task");
      expect(results[1].task_title).toBe("Old Task");
    });

    it("getRelevantEpisodes respects limit", () => {
      for (let i = 0; i < 10; i++) {
        store.storeEpisode(projectId, null, `seed-${i}`, `Task ${i}`, null, "developer", "success", 0.1);
      }

      const results = store.getRelevantEpisodes(projectId, undefined, undefined, 3);
      expect(results).toHaveLength(3);
    });

    it("getRelevantEpisodes returns empty array when none exist", () => {
      const results = store.getRelevantEpisodes(projectId);
      expect(results).toEqual([]);
    });
  });

  // ── Patterns ──────────────────────────────────────────────────────────

  describe("patterns", () => {
    it("stores a new pattern", () => {
      const p = store.storePattern(
        projectId,
        "testing-approach",
        "Use vitest with in-memory SQLite",
        "success",
      );

      expect(p.id).toBeDefined();
      expect(p.project_id).toBe(projectId);
      expect(p.pattern_type).toBe("testing-approach");
      expect(p.success_count).toBe(1);
      expect(p.failure_count).toBe(0);
    });

    it("increments success_count on duplicate success", () => {
      store.storePattern(projectId, "file-location", "Store ts in src/lib", "success");
      const updated = store.storePattern(projectId, "file-location", "Store ts in src/lib", "success");

      expect(updated.success_count).toBe(2);
      expect(updated.failure_count).toBe(0);
    });

    it("increments failure_count on duplicate failure", () => {
      store.storePattern(projectId, "error-recovery", "Retry 3 times", "success");
      const updated = store.storePattern(projectId, "error-recovery", "Retry 3 times", "failure");

      expect(updated.success_count).toBe(1);
      expect(updated.failure_count).toBe(1);
    });

    it("getPatterns filters by type", () => {
      store.storePattern(projectId, "testing", "Use vitest", "success");
      store.storePattern(projectId, "file-location", "src/lib/", "success");

      const testingPatterns = store.getPatterns(projectId, "testing");
      expect(testingPatterns).toHaveLength(1);
      expect(testingPatterns[0].pattern_type).toBe("testing");
    });

    it("getPatterns filters by minSuccessCount", () => {
      store.storePattern(projectId, "testing", "Pattern A", "success");
      store.storePattern(projectId, "testing", "Pattern B", "success");
      store.storePattern(projectId, "testing", "Pattern B", "success"); // 2 successes

      const frequent = store.getPatterns(projectId, undefined, 2);
      expect(frequent).toHaveLength(1);
      expect(frequent[0].pattern_description).toBe("Pattern B");
    });

    it("getPatterns returns all patterns for project sorted by success_count", () => {
      store.storePattern(projectId, "a", "Pattern 1", "success");
      store.storePattern(projectId, "b", "Pattern 2", "success");
      store.storePattern(projectId, "b", "Pattern 2", "success"); // 2 successes

      const all = store.getPatterns(projectId);
      expect(all).toHaveLength(2);
      expect(all[0].success_count).toBeGreaterThanOrEqual(all[1].success_count);
    });
  });

  // ── Skills ────────────────────────────────────────────────────────────

  describe("skills", () => {
    it("stores a skill with roles and examples", () => {
      const skill = store.storeSkill(
        projectId,
        "prepare-statements",
        "Use parameterized SQL queries to prevent injection",
        ["developer", "qa"],
        ["INSERT INTO ... VALUES (?, ?, ?)"],
        80,
      );

      expect(skill.id).toBeDefined();
      expect(skill.skill_name).toBe("prepare-statements");
      expect(skill.confidence_score).toBe(80);
      const roles = JSON.parse(skill.applicable_to_roles) as string[];
      expect(roles).toContain("developer");
      expect(roles).toContain("qa");
      const examples = JSON.parse(skill.success_examples ?? "[]") as string[];
      expect(examples).toHaveLength(1);
    });

    it("stores a skill without examples using default confidence", () => {
      const skill = store.storeSkill(
        projectId,
        "error-handling",
        "Always catch and log errors with context",
        ["developer"],
      );

      expect(skill.confidence_score).toBe(50);
      expect(skill.success_examples).toBeNull();
    });

    it("getSkills filters by role using JSON LIKE", () => {
      store.storeSkill(projectId, "dev-skill", "For developers", ["developer"], undefined, 70);
      store.storeSkill(projectId, "qa-skill", "For QA", ["qa"], undefined, 60);
      store.storeSkill(projectId, "shared-skill", "For all", ["developer", "qa", "explorer"], undefined, 90);

      const devSkills = store.getSkills(projectId, "developer");
      expect(devSkills).toHaveLength(2);
      const names = devSkills.map((s) => s.skill_name);
      expect(names).toContain("dev-skill");
      expect(names).toContain("shared-skill");
      expect(names).not.toContain("qa-skill");
    });

    it("getSkills returns all skills sorted by confidence", () => {
      store.storeSkill(projectId, "low", "Low confidence", ["developer"], undefined, 30);
      store.storeSkill(projectId, "high", "High confidence", ["developer"], undefined, 90);

      const skills = store.getSkills(projectId);
      expect(skills[0].confidence_score).toBeGreaterThanOrEqual(skills[1].confidence_score);
    });
  });

  // ── queryMemory ───────────────────────────────────────────────────────

  describe("queryMemory", () => {
    it("returns empty memory when nothing stored", () => {
      const memory = store.queryMemory(projectId);
      expect(memory.episodes).toEqual([]);
      expect(memory.patterns).toEqual([]);
      expect(memory.skills).toEqual([]);
    });

    it("returns relevant episodes, patterns, and skills together", () => {
      store.storeEpisode(projectId, null, "seed-1", "Task A", null, "developer", "success", 0.5);
      store.storePattern(projectId, "testing", "vitest pattern", "success");
      store.storePattern(projectId, "testing", "vitest pattern", "success"); // 2 successes now
      store.storeSkill(projectId, "type-safety", "Use TypeScript strictly", ["developer"], undefined, 75);

      const memory = store.queryMemory(projectId);
      expect(memory.episodes).toHaveLength(1);
      expect(memory.patterns).toHaveLength(1); // Only patterns with success_count >= 1
      expect(memory.skills).toHaveLength(1);
    });

    it("filters episodes by seedId when provided", () => {
      store.storeEpisode(projectId, null, "seed-1", "Matching Task", null, "developer", "success", 0.1);
      store.storeEpisode(projectId, null, "seed-2", "Different Task", null, "developer", "success", 0.1);

      const memory = store.queryMemory(projectId, "seed-1");
      expect(memory.episodes).toHaveLength(1);
      expect(memory.episodes[0].task_title).toBe("Matching Task");
    });

    it("filters skills by role when provided", () => {
      store.storeSkill(projectId, "dev-skill", "Developer only", ["developer"], undefined, 80);
      store.storeSkill(projectId, "explorer-skill", "Explorer only", ["explorer"], undefined, 80);

      const memory = store.queryMemory(projectId, undefined, "developer");
      const skillNames = memory.skills.map((s) => s.skill_name);
      expect(skillNames).toContain("dev-skill");
      expect(skillNames).not.toContain("explorer-skill");
    });

    it("memory from different project is isolated", () => {
      const p2 = store.registerProject("other-project", "/other");
      store.storeEpisode(p2.id, null, "seed-1", "Other project task", null, "developer", "success", 0.1);
      store.storePattern(p2.id, "testing", "Other pattern", "success");
      store.storeSkill(p2.id, "other-skill", "Other skill", ["developer"], undefined, 80);

      const memory = store.queryMemory(projectId);
      expect(memory.episodes).toHaveLength(0);
      expect(memory.patterns).toHaveLength(0);
      expect(memory.skills).toHaveLength(0);
    });
  });
});
