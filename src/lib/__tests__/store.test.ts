import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, existsSync, mkdirSync, symlinkSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../store.js";

describe("ForemanStore", () => {
  let store: ForemanStore;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  // ── forProject factory ─────────────────────────────────────────────

  describe("forProject", () => {
    it("creates database at <projectPath>/.foreman/foreman.db", () => {
      const projectDir = mkdtempSync(join(tmpdir(), "foreman-project-"));
      try {
        const projectStore = ForemanStore.forProject(projectDir);
        // Verify the database file is at the project-local location
        const expectedDbPath = join(projectDir, ".foreman", "foreman.db");
        expect(existsSync(expectedDbPath)).toBe(true);
        // Verify it's functional — can register a project and retrieve it
        const project = projectStore.registerProject("my-project", projectDir);
        expect(project.name).toBe("my-project");
        expect(projectStore.getProjectByPath(projectDir)).toEqual(project);
        projectStore.close();
      } finally {
        rmSync(projectDir, { recursive: true, force: true });
      }
    });

    it("creates .foreman directory if it does not exist", () => {
      const projectDir = mkdtempSync(join(tmpdir(), "foreman-project-"));
      try {
        const foremanDir = join(projectDir, ".foreman");
        expect(existsSync(foremanDir)).toBe(false);
        const projectStore = ForemanStore.forProject(projectDir);
        expect(existsSync(foremanDir)).toBe(true);
        projectStore.close();
      } finally {
        rmSync(projectDir, { recursive: true, force: true });
      }
    });

    it("two stores for the same project share data", () => {
      const projectDir = mkdtempSync(join(tmpdir(), "foreman-project-"));
      try {
        const store1 = ForemanStore.forProject(projectDir);
        const project = store1.registerProject("shared-project", projectDir);
        store1.close();

        const store2 = ForemanStore.forProject(projectDir);
        const fetched = store2.getProjectByPath(projectDir);
        expect(fetched).not.toBeNull();
        expect(fetched!.id).toBe(project.id);
        store2.close();
      } finally {
        rmSync(projectDir, { recursive: true, force: true });
      }
    });
  });

  // ── Projects ──────────────────────────────────────────────────────

  describe("projects", () => {
    it("registers and retrieves a project", () => {
      const project = store.registerProject("my-app", "/home/user/my-app");
      expect(project.name).toBe("my-app");
      expect(project.status).toBe("active");

      const fetched = store.getProject(project.id);
      expect(fetched).toEqual(project);
    });

    it("retrieves a project by path", () => {
      const project = store.registerProject("my-app", "/home/user/my-app");
      const fetched = store.getProjectByPath("/home/user/my-app");
      expect(fetched).toEqual(project);
    });

    it("retrieves a project when registration and lookup use different path aliases", () => {
      const baseDir = mkdtempSync(join(tmpdir(), "foreman-project-alias-"));
      const realProjectDir = join(baseDir, "real");
      const aliasProjectDir = join(baseDir, "alias");

      mkdirSync(realProjectDir);
      symlinkSync(realProjectDir, aliasProjectDir);

      try {
        const project = store.registerProject("aliased-project", aliasProjectDir);
        const fetched = store.getProjectByPath(realProjectDir);
        expect(fetched).toEqual(project);
      } finally {
        rmSync(baseDir, { recursive: true, force: true });
      }
    });

    it("returns null for non-existent project", () => {
      expect(store.getProject("nonexistent")).toBeNull();
      expect(store.getProjectByPath("/nope")).toBeNull();
    });

    it("lists projects filtered by status", () => {
      store.registerProject("a", "/a");
      const b = store.registerProject("b", "/b");
      store.updateProject(b.id, { status: "archived" });

      expect(store.listProjects("active")).toHaveLength(1);
      expect(store.listProjects("archived")).toHaveLength(1);
      expect(store.listProjects()).toHaveLength(2);
    });

    it("updates project fields", () => {
      const project = store.registerProject("old", "/old");
      store.updateProject(project.id, { name: "new", status: "paused" });

      const updated = store.getProject(project.id)!;
      expect(updated.name).toBe("new");
      expect(updated.status).toBe("paused");
      expect(updated.updated_at).toBeDefined();
    });

    it("enforces unique path constraint", () => {
      store.registerProject("a", "/same/path");
      expect(() => store.registerProject("b", "/same/path")).toThrow();
    });
  });

  // ── Runs ──────────────────────────────────────────────────────────

  describe("runs", () => {
    it("creates and retrieves a run", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-a1b2", "claude-code", "/tmp/wt");

      expect(run.status).toBe("pending");
      expect(run.seed_id).toBe("bd-a1b2");
      // Verify core fields match; extra columns (commit_sha, pr_*, etc.) are
      // added by schema migrations and don't need explicit coverage here.
      const stored = store.getRun(run.id)!;
      expect(stored.status).toBe(run.status);
      expect(stored.seed_id).toBe(run.seed_id);
      expect(stored.id).toBe(run.id);
    });

    it("updates run status", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-x1", "pi");
      const now = new Date().toISOString();

      store.updateRun(run.id, { status: "running", started_at: now });
      const updated = store.getRun(run.id)!;
      expect(updated.status).toBe("running");
      expect(updated.started_at).toBe(now);
    });

    it("gets active runs filtered by project", () => {
      const p1 = store.registerProject("p1", "/p1");
      const p2 = store.registerProject("p2", "/p2");

      store.createRun(p1.id, "bd-1", "claude-code");
      store.createRun(p2.id, "bd-2", "codex");
      const completed = store.createRun(p1.id, "bd-3", "pi");
      store.updateRun(completed.id, { status: "completed" });

      expect(store.getActiveRuns(p1.id)).toHaveLength(1);
      expect(store.getActiveRuns()).toHaveLength(2);
    });
  });

  describe("getRunsForSeed", () => {
    it("returns runs for a seed sorted by created_at DESC", () => {
      const project = store.registerProject("p", "/p");
      const run1 = store.createRun(project.id, "bd-abc", "claude-sonnet-4-6", "/wt1");
      store.updateRun(run1.id, { status: "completed" });
      const run2 = store.createRun(project.id, "bd-abc", "claude-opus-4-6", "/wt1");

      const runs = store.getRunsForSeed("bd-abc", project.id);
      expect(runs).toHaveLength(2);
      // Most recent first
      expect(runs[0].id).toBe(run2.id);
      expect(runs[1].id).toBe(run1.id);
    });

    it("filters by project when projectId given", () => {
      const p1 = store.registerProject("p1", "/p1");
      const p2 = store.registerProject("p2", "/p2");
      store.createRun(p1.id, "bd-abc", "claude-code", "/wt1");
      store.createRun(p2.id, "bd-abc", "claude-code", "/wt2");

      expect(store.getRunsForSeed("bd-abc", p1.id)).toHaveLength(1);
      expect(store.getRunsForSeed("bd-abc")).toHaveLength(2);
    });

    it("returns empty array when no runs exist", () => {
      expect(store.getRunsForSeed("sd-nonexistent")).toEqual([]);
    });
  });

  // ── hasActiveOrPendingRun ──────────────────────────────────────────

  describe("hasActiveOrPendingRun", () => {
    it("returns false when no runs exist for seed", () => {
      const project = store.registerProject("p", "/p");
      expect(store.hasActiveOrPendingRun("bd-absent", project.id)).toBe(false);
    });

    it("returns true when a pending run exists", () => {
      const project = store.registerProject("p", "/p");
      store.createRun(project.id, "bd-x", "claude-code"); // status = pending
      expect(store.hasActiveOrPendingRun("bd-x", project.id)).toBe(true);
    });

    it("returns true when a running run exists", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-x", "claude-code");
      store.updateRun(run.id, { status: "running" });
      expect(store.hasActiveOrPendingRun("bd-x", project.id)).toBe(true);
    });

    it("returns true when a completed run exists (awaiting merge)", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-x", "claude-code");
      store.updateRun(run.id, { status: "completed" });
      expect(store.hasActiveOrPendingRun("bd-x", project.id)).toBe(true);
    });

    it("returns true when a stuck run exists", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-x", "claude-code");
      store.updateRun(run.id, { status: "stuck" });
      expect(store.hasActiveOrPendingRun("bd-x", project.id)).toBe(true);
    });

    it("returns false when the only run is failed (retry allowed)", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-x", "claude-code");
      store.updateRun(run.id, { status: "failed" });
      expect(store.hasActiveOrPendingRun("bd-x", project.id)).toBe(false);
    });

    it("returns false when the only run is merged (work done)", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-x", "claude-code");
      store.updateRun(run.id, { status: "merged" });
      expect(store.hasActiveOrPendingRun("bd-x", project.id)).toBe(false);
    });

    it("returns false when the only run is reset (retry allowed)", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-x", "claude-code");
      store.updateRun(run.id, { status: "reset" });
      expect(store.hasActiveOrPendingRun("bd-x", project.id)).toBe(false);
    });

    it("returns false when the only run is conflict", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-x", "claude-code");
      store.updateRun(run.id, { status: "conflict" });
      expect(store.hasActiveOrPendingRun("bd-x", project.id)).toBe(false);
    });

    it("returns false when the only run is test-failed", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-x", "claude-code");
      store.updateRun(run.id, { status: "test-failed" });
      expect(store.hasActiveOrPendingRun("bd-x", project.id)).toBe(false);
    });

    it("returns true if any blocking run exists alongside terminal runs", () => {
      const project = store.registerProject("p", "/p");
      const r1 = store.createRun(project.id, "bd-x", "claude-code");
      store.updateRun(r1.id, { status: "failed" });
      // Second attempt is now running
      const r2 = store.createRun(project.id, "bd-x", "claude-code");
      store.updateRun(r2.id, { status: "running" });
      expect(store.hasActiveOrPendingRun("bd-x", project.id)).toBe(true);
    });

    it("scopes correctly to projectId — different project does not block", () => {
      const p1 = store.registerProject("p1", "/p1");
      const p2 = store.registerProject("p2", "/p2");
      const run = store.createRun(p1.id, "bd-x", "claude-code"); // pending in p1
      void run;
      // p2 has no runs — should not be blocked
      expect(store.hasActiveOrPendingRun("bd-x", p2.id)).toBe(false);
      // p1 has a pending run — should be blocked
      expect(store.hasActiveOrPendingRun("bd-x", p1.id)).toBe(true);
    });

    it("checks across all projects when no projectId given", () => {
      const p1 = store.registerProject("p1", "/p1");
      store.createRun(p1.id, "bd-global", "claude-code"); // pending
      expect(store.hasActiveOrPendingRun("bd-global")).toBe(true);
    });
  });

  // ── Costs ─────────────────────────────────────────────────────────

  describe("costs", () => {
    it("records and retrieves costs", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-1", "claude-code");

      store.recordCost(run.id, 1000, 500, 200, 0.05);
      store.recordCost(run.id, 2000, 1000, 0, 0.10);

      const costs = store.getCosts(project.id);
      expect(costs).toHaveLength(2);
      expect(costs[0].tokens_in + costs[1].tokens_in).toBe(3000);
    });

    it("filters costs by since", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-1", "claude-code");
      store.recordCost(run.id, 100, 50, 0, 0.01);

      const future = new Date(Date.now() + 100000).toISOString();
      expect(store.getCosts(project.id, future)).toHaveLength(0);
    });
  });

  // ── Events ────────────────────────────────────────────────────────

  describe("events", () => {
    it("logs and retrieves events", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "bd-1", "claude-code");

      store.logEvent(project.id, "dispatch", { seed: "bd-1" }, run.id);
      store.logEvent(project.id, "complete", { result: "ok" }, run.id);

      const events = store.getEvents(project.id);
      expect(events).toHaveLength(2);
      const types = events.map((e) => e.event_type).sort();
      expect(types).toEqual(["complete", "dispatch"]);
    });

    it("filters events by type and limit", () => {
      const project = store.registerProject("p", "/p");
      store.logEvent(project.id, "dispatch");
      store.logEvent(project.id, "dispatch");
      store.logEvent(project.id, "complete");

      expect(store.getEvents(project.id, undefined, "dispatch")).toHaveLength(2);
      expect(store.getEvents(project.id, 1)).toHaveLength(1);
    });

    it("stores string details directly", () => {
      const project = store.registerProject("p", "/p");
      store.logEvent(project.id, "fail", "something broke");

      const events = store.getEvents(project.id);
      expect(events[0].details).toBe("something broke");
    });
  });

  // ── Messaging ─────────────────────────────────────────────────────

  describe("messaging", () => {
    it("sends and retrieves a message", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "sd-1", "claude-code");

      const msg = store.sendMessage(run.id, "explorer", "developer", "Ready", "Explorer done.");
      expect(msg.id).toBeDefined();
      expect(msg.sender_agent_type).toBe("explorer");
      expect(msg.recipient_agent_type).toBe("developer");
      expect(msg.subject).toBe("Ready");
      expect(msg.body).toBe("Explorer done.");
      expect(msg.read).toBe(0);
      expect(msg.deleted_at).toBeNull();

      const messages = store.getMessages(run.id, "developer");
      expect(messages).toHaveLength(1);
      expect(messages[0].id).toBe(msg.id);
    });

    it("markMessageRead returns true when message exists, false otherwise", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "sd-1", "claude-code");

      const msg = store.sendMessage(run.id, "explorer", "developer", "Hi", "body");
      expect(store.markMessageRead(msg.id)).toBe(true);
      expect(store.markMessageRead("non-existent-id")).toBe(false);
    });

    it("filters unread messages only", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "sd-1", "claude-code");

      const m1 = store.sendMessage(run.id, "explorer", "developer", "First", "body 1");
      const m2 = store.sendMessage(run.id, "qa", "developer", "Second", "body 2");

      store.markMessageRead(m1.id);

      const unread = store.getMessages(run.id, "developer", true);
      expect(unread).toHaveLength(1);
      expect(unread[0].id).toBe(m2.id);

      const all = store.getMessages(run.id, "developer", false);
      expect(all).toHaveLength(2);
    });

    it("marks all messages for an agent read", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "sd-1", "claude-code");

      store.sendMessage(run.id, "explorer", "developer", "A", "body");
      store.sendMessage(run.id, "qa", "developer", "B", "body");
      store.sendMessage(run.id, "developer", "qa", "C", "body"); // to qa, not developer

      store.markAllMessagesRead(run.id, "developer");

      const unread = store.getMessages(run.id, "developer", true);
      expect(unread).toHaveLength(0);

      // qa message unaffected
      const qaUnread = store.getMessages(run.id, "qa", true);
      expect(qaUnread).toHaveLength(1);
    });

    it("soft-deletes a message", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "sd-1", "claude-code");

      const msg = store.sendMessage(run.id, "explorer", "developer", "Delete me", "body");
      const deleted = store.deleteMessage(msg.id);
      expect(deleted).toBe(true);

      const messages = store.getMessages(run.id, "developer");
      expect(messages).toHaveLength(0);

      // Raw record still exists with deleted_at set
      const raw = store.getMessage(msg.id);
      expect(raw).not.toBeNull();
      expect(raw!.deleted_at).not.toBeNull();
    });

    it("deleteMessage returns false for a non-existent message id", () => {
      expect(store.deleteMessage("non-existent-id")).toBe(false);
    });

    it("scopes messages by run_id", () => {
      const project = store.registerProject("p", "/p");
      const run1 = store.createRun(project.id, "sd-1", "claude-code");
      const run2 = store.createRun(project.id, "sd-2", "claude-code");

      store.sendMessage(run1.id, "explorer", "developer", "Run 1", "body");
      store.sendMessage(run2.id, "explorer", "developer", "Run 2", "body");

      expect(store.getMessages(run1.id, "developer")).toHaveLength(1);
      expect(store.getMessages(run2.id, "developer")).toHaveLength(1);
    });

    it("getAllMessages returns all non-deleted messages for a run", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "sd-1", "claude-code");

      store.sendMessage(run.id, "explorer", "developer", "A", "body");
      const m2 = store.sendMessage(run.id, "developer", "qa", "B", "body");
      store.sendMessage(run.id, "qa", "developer", "C", "body");
      store.deleteMessage(m2.id);

      const all = store.getAllMessages(run.id);
      expect(all).toHaveLength(2);
      expect(all.map((m) => m.subject)).toEqual(["A", "C"]);
    });

    it("getMessage returns single message by id", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "sd-1", "claude-code");

      const msg = store.sendMessage(run.id, "explorer", "developer", "Hi", "body");
      const fetched = store.getMessage(msg.id);
      expect(fetched).toEqual(msg);
      expect(store.getMessage("nonexistent")).toBeNull();
    });

    it("orders messages by created_at ASC", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "sd-1", "claude-code");

      store.sendMessage(run.id, "explorer", "developer", "First", "body1");
      store.sendMessage(run.id, "qa", "developer", "Second", "body2");
      store.sendMessage(run.id, "lead", "developer", "Third", "body3");

      const messages = store.getMessages(run.id, "developer");
      expect(messages[0].subject).toBe("First");
      expect(messages[1].subject).toBe("Second");
      expect(messages[2].subject).toBe("Third");
    });
  });

  // ── Migration guard ───────────────────────────────────────────────

  describe("migration guard — messages survive store re-open", () => {
    it("does NOT drop the messages table when the store is re-opened", () => {
      // This guards against the regression where DROP TABLE IF EXISTS messages
      // was run unconditionally on every constructor call, wiping all messages.
      const dbPath = join(tmpDir, "reopen-test.db");

      // Open store #1, send a message, close it
      const store1 = new ForemanStore(dbPath);
      const project = store1.registerProject("reopen-project", "/reopen");
      const run = store1.createRun(project.id, "sd-reopen", "claude-code");
      store1.sendMessage(run.id, "explorer", "developer", "Persisted", "body");
      store1.close();

      // Open store #2 against the same DB — message must still be there
      const store2 = new ForemanStore(dbPath);
      const messages = store2.getMessages(run.id, "developer");
      store2.close();

      expect(messages).toHaveLength(1);
      expect(messages[0].subject).toBe("Persisted");
    });
  });

  // ── Metrics ───────────────────────────────────────────────────────

  describe("metrics", () => {
    it("aggregates costs and run statuses", () => {
      const project = store.registerProject("p", "/p");
      const r1 = store.createRun(project.id, "bd-1", "claude-code");
      const r2 = store.createRun(project.id, "bd-2", "pi");

      store.updateRun(r1.id, {
        status: "completed",
        started_at: "2025-01-01T00:00:00Z",
        completed_at: "2025-01-01T00:10:00Z",
      });
      store.updateRun(r2.id, { status: "failed" });

      store.recordCost(r1.id, 1000, 500, 0, 0.05);
      store.recordCost(r2.id, 2000, 1000, 0, 0.10);

      const metrics = store.getMetrics(project.id);
      expect(metrics.totalCost).toBeCloseTo(0.15);
      expect(metrics.totalTokens).toBe(4500);
      expect(metrics.tasksByStatus.completed).toBe(1);
      expect(metrics.tasksByStatus.failed).toBe(1);
      expect(metrics.costByRuntime).toHaveLength(2);

      const r1Metric = metrics.costByRuntime.find((r) => r.run_id === r1.id)!;
      expect(r1Metric.duration_seconds).toBe(600);
    });
  });
});
