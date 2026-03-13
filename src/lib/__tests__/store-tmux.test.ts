import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../store.js";

describe("ForemanStore — tmux_session support", () => {
  let store: ForemanStore;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-tmux-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  // ── AT-T010: Migration idempotency ──────────────────────────────────

  describe("tmux_session migration", () => {
    it("adds tmux_session column without error on fresh database", () => {
      // The store constructor runs migrations. If we got here, the column was added.
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "sd-1", "claude-code");
      const fetched = store.getRun(run.id)!;
      expect(fetched.tmux_session).toBeNull();
    });

    it("is idempotent — re-opening the store does not throw", () => {
      const dbPath = join(tmpDir, "idempotent.db");
      const store1 = new ForemanStore(dbPath);
      store1.close();

      // Second open re-runs migrations; ALTER TABLE should silently fail
      const store2 = new ForemanStore(dbPath);
      const project = store2.registerProject("p", "/p");
      const run = store2.createRun(project.id, "sd-1", "claude-code");
      const fetched = store2.getRun(run.id)!;
      expect(fetched.tmux_session).toBeNull();
      store2.close();
    });
  });

  // ── AT-T011: updateRun with tmux_session ────────────────────────────

  describe("updateRun with tmux_session", () => {
    it("persists and retrieves tmux_session", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "sd-1", "claude-code");

      store.updateRun(run.id, { tmux_session: "foreman-sd-1" });

      const fetched = store.getRun(run.id)!;
      expect(fetched.tmux_session).toBe("foreman-sd-1");
    });

    it("can update tmux_session alongside other fields", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "sd-1", "claude-code");
      const now = new Date().toISOString();

      store.updateRun(run.id, {
        status: "running",
        started_at: now,
        tmux_session: "foreman-sd-1",
      });

      const fetched = store.getRun(run.id)!;
      expect(fetched.status).toBe("running");
      expect(fetched.started_at).toBe(now);
      expect(fetched.tmux_session).toBe("foreman-sd-1");
    });

    it("can clear tmux_session by setting it to null", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "sd-1", "claude-code");

      store.updateRun(run.id, { tmux_session: "foreman-sd-1" });
      expect(store.getRun(run.id)!.tmux_session).toBe("foreman-sd-1");

      store.updateRun(run.id, { tmux_session: null });
      expect(store.getRun(run.id)!.tmux_session).toBeNull();
    });
  });

  // ── AT-T012: Existing runs default to null ──────────────────────────

  describe("backward compatibility", () => {
    it("existing runs without tmux_session return null", () => {
      const project = store.registerProject("p", "/p");
      const run = store.createRun(project.id, "sd-1", "claude-code");

      // createRun does not set tmux_session — it should default to null
      expect(run.tmux_session).toBeNull();

      const fetched = store.getRun(run.id)!;
      expect(fetched.tmux_session).toBeNull();
    });
  });
});
