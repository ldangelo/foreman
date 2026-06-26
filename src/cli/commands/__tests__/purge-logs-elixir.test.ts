import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it, vi } from "vitest";

const { mockStatus, mockHealth, mockListRuns, mockElixirClientCtor } = vi.hoisted(() => ({
  mockStatus: vi.fn(() => ({ running: true, url: "http://127.0.0.1:4777", pidPath: "/tmp/pid" })),
  mockHealth: vi.fn(async () => ({ ok: true })),
  mockListRuns: vi.fn(async () => []),
  mockElixirClientCtor: vi.fn(),
}));

vi.mock("../../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: class MockElixirServerManager {
    authToken = "token";
    status = mockStatus;
    health = mockHealth;
  },
}));

vi.mock("../../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: class MockElixirServerClient {
    constructor(url: string, token?: string) {
      mockElixirClientCtor(url, token);
    }
    listRuns = mockListRuns;
  },
}));

import { purgeLogsAction } from "../purge-logs.js";

describe("Elixir purge logs dry-run", () => {
  const tempDirs: string[] = [];

  afterEach(async () => {
    vi.clearAllMocks();
    vi.restoreAllMocks();
    await Promise.all(tempDirs.map((dir) => rm(dir, { recursive: true, force: true })));
    tempDirs.length = 0;
  });

  it("previews terminal Elixir run logs without deleting files", async () => {
    const dir = mkdtempSync(join(tmpdir(), "foreman-purge-logs-elixir-"));
    tempDirs.push(dir);
    const runId = "550e8400-e29b-41d4-a716-446655440000";
    const file = join(dir, `${runId}.log`);
    writeFileSync(file, "log");
    const old = Date.now() - 10 * 24 * 60 * 60 * 1000;
    await import("node:fs/promises").then((fs) => fs.utimes(file, old / 1000, old / 1000));

    const result = await purgeLogsAction(
      { dryRun: true, days: 7 },
      { getRun: async () => ({ id: runId, project_id: "proj-1", seed_id: "task-1", agent_type: "elixir", session_key: null, worktree_path: null, status: "completed", started_at: new Date(old).toISOString(), completed_at: new Date(old).toISOString(), created_at: new Date(old).toISOString(), progress: null }) },
      dir,
    );

    expect(result.deleted).toBe(1);
    expect(result.freedBytes).toBeGreaterThan(0);
    expect(existsSync(file)).toBe(true);
  });
});
