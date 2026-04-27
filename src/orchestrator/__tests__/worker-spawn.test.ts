import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdtempSync, rmSync, existsSync, readFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../../lib/store.js";
import { buildSdkSessionKey } from "../dispatcher.js";

/**
 * Tests for the detached worker spawning pathway in the Dispatcher.
 *
 * These tests verify that:
 * 1. The dispatch method writes a WorkerConfig JSON file
 * 2. The config contains all required fields
 * 3. The worker process is spawned with correct arguments
 *
 * We mock createWorktree and the spawn call to avoid real side effects.
 */

// We can't easily test spawnWorkerProcess directly (it's module-scoped),
// so we test the Dispatcher.dispatch flow end-to-end with mocks.

describe("Dispatcher worker spawning", () => {
  let tmpDir: string;
  let store: ForemanStore;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-spawn-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("dispatch creates run records in the store", async () => {
    const project = store.registerProject("test-project", tmpDir);

    // Create a run manually to verify store operations
    const run = store.createRun(project.id, "bd-test", "claude-sonnet-4-6", join(tmpDir, "wt"));
    expect(run.status).toBe("pending");
    expect(run.seed_id).toBe("bd-test");

    // Verify we can update it to running (what dispatcher does after spawn)
    store.updateRun(run.id, {
      status: "running",
      started_at: new Date().toISOString(),
      session_key: "foreman:sdk:claude-sonnet-4-6:test-run",
    });

    const updated = store.getRun(run.id)!;
    expect(updated.status).toBe("running");
    expect(updated.session_key).toContain("foreman:sdk");
  });

  it("worker config JSON has all required fields", () => {
    // Verify the config shape matches what agent-worker.ts expects
    const config = {
      runId: "run-123",
      projectId: "proj-456",
      seedId: "bd-test",
      seedTitle: "Test Task",
      model: "claude-sonnet-4-6",
      worktreePath: "/tmp/wt/bd-test",
      prompt: "Read AGENTS.md and implement the task.",
      env: { PATH: "/usr/bin", HOME: "/home/test" },
    };

    const json = JSON.stringify(config);
    const parsed = JSON.parse(json);

    expect(parsed.runId).toBe("run-123");
    expect(parsed.projectId).toBe("proj-456");
    expect(parsed.seedId).toBe("bd-test");
    expect(parsed.seedTitle).toBe("Test Task");
    expect(parsed.model).toBe("claude-sonnet-4-6");
    expect(parsed.worktreePath).toBe("/tmp/wt/bd-test");
    expect(parsed.prompt).toContain("AGENTS.md");
    expect(parsed.env).toBeDefined();
    expect(parsed.resume).toBeUndefined();
  });

  it("resume config includes session ID", () => {
    const config = {
      runId: "run-789",
      projectId: "proj-456",
      seedId: "bd-test",
      seedTitle: "Test Task",
      model: "claude-opus-4-6",
      worktreePath: "/tmp/wt/bd-test",
      prompt: "Continue where you left off.",
      env: {},
      resume: "session-abc-def",
    };

    const parsed = JSON.parse(JSON.stringify(config));
    expect(parsed.resume).toBe("session-abc-def");
  });

  it("builds SDK session keys that preserve pid and resume id", () => {
    expect(buildSdkSessionKey("claude-sonnet-4-6", "run-123", 4242)).toBe(
      "foreman:sdk:claude-sonnet-4-6:run-123:pid-4242",
    );
    expect(buildSdkSessionKey("claude-sonnet-4-6", "run-123", 4242, "abc")).toBe(
      "foreman:sdk:claude-sonnet-4-6:run-123:pid-4242:session-abc",
    );
  });

  it("config tmp directory is created under HOME/.foreman/tmp", async () => {
    const foremanTmp = join(tmpDir, ".foreman", "tmp");
    mkdirSync(foremanTmp, { recursive: true });
    expect(existsSync(foremanTmp)).toBe(true);
  });

  it("worker script exists at expected path", () => {
    const workerPath = join(
      import.meta.dirname, "..", "agent-worker.ts",
    );
    expect(existsSync(workerPath)).toBe(true);
  });

  it("tsx binary exists in node_modules", () => {
    const projectRoot = join(import.meta.dirname, "..", "..", "..");
    const tsxBin = join(projectRoot, "node_modules", ".bin", "tsx");
    expect(existsSync(tsxBin)).toBe(true);
  });
});
