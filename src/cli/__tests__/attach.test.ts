import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../../lib/store.js";

describe("foreman attach", () => {
  let store: ForemanStore;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-attach-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  describe("session ID extraction", () => {
    // Test the session key format used throughout foreman
    it("extracts session ID from standard session key", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-abc", "claude-sonnet-4-6", "/wt");
      store.updateRun(run.id, {
        session_key: "foreman:sdk:claude-sonnet-4-6:run123:session-abc-def-123",
        status: "running",
      });

      const fetched = store.getRun(run.id)!;
      const match = fetched.session_key?.match(/session-(.+)$/);
      expect(match).toBeTruthy();
      expect(match![1]).toBe("abc-def-123");
    });

    it("returns null for session key without session ID", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-abc", "claude-sonnet-4-6", "/wt");
      store.updateRun(run.id, {
        session_key: "foreman:sdk:claude-sonnet-4-6:run123",
        status: "running",
      });

      const fetched = store.getRun(run.id)!;
      const match = fetched.session_key?.match(/session-(.+)$/);
      expect(match).toBeNull();
    });
  });

  describe("run lookup by seed ID", () => {
    it("finds the most recent run for a seed", () => {
      const project = store.registerProject("p", "/p");
      const run1 = store.createRun(project.id, "bd-xyz", "claude-sonnet-4-6", "/wt");
      store.updateRun(run1.id, { status: "completed" });
      const run2 = store.createRun(project.id, "bd-xyz", "claude-opus-4-6", "/wt");
      store.updateRun(run2.id, {
        status: "running",
        session_key: "foreman:sdk:claude-opus-4-6:run2:session-latest-session",
      });

      const runs = store.getRunsForSeed("bd-xyz", project.id);
      expect(runs.length).toBeGreaterThanOrEqual(2);
      // Most recent run first
      expect(runs[0].id).toBe(run2.id);
      expect(runs[0].agent_type).toBe("claude-opus-4-6");
    });

    it("returns empty for unknown seed", () => {
      const project = store.registerProject("p", "/p");
      const runs = store.getRunsForSeed("bd-nonexistent", project.id);
      expect(runs).toEqual([]);
    });
  });

  describe("attachable session listing", () => {
    it("lists runs across multiple statuses", () => {
      const project = store.registerProject("p", "/p");

      const r1 = store.createRun(project.id, "bd-1", "claude-sonnet-4-6", "/wt1");
      store.updateRun(r1.id, {
        status: "running",
        session_key: "foreman:sdk:sonnet:r1:session-s1",
      });

      const r2 = store.createRun(project.id, "bd-2", "claude-opus-4-6", "/wt2");
      store.updateRun(r2.id, {
        status: "completed",
        session_key: "foreman:sdk:opus:r2:session-s2",
      });

      const r3 = store.createRun(project.id, "bd-3", "claude-haiku-4-5-20251001", "/wt3");
      store.updateRun(r3.id, {
        status: "stuck",
        session_key: "foreman:sdk:haiku:r3:session-s3",
      });

      // Collect all attachable runs
      const statuses = ["running", "completed", "stuck", "failed"] as const;
      const allRuns = statuses.flatMap((s) => store.getRunsByStatus(s, project.id));
      expect(allRuns).toHaveLength(3);

      // All should have session IDs
      for (const run of allRuns) {
        const match = run.session_key?.match(/session-(.+)$/);
        expect(match).toBeTruthy();
      }
    });
  });
});
