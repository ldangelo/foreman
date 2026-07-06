import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { mockReadFileSync, mockResolve, mockEnsureRunning, mockStatus, mockSendCommand } = vi.hoisted(() => ({
  mockReadFileSync: vi.fn(),
  mockResolve: vi.fn((path: string) => `/repo/${path}`),
  mockEnsureRunning: vi.fn(),
  mockStatus: vi.fn(),
  mockSendCommand: vi.fn(),
}));

vi.mock("node:fs", () => ({
  readFileSync: mockReadFileSync,
}));

vi.mock("node:path", async (importOriginal) => ({
  ...(await importOriginal<typeof import("node:path")>()),
  resolve: mockResolve,
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn().mockImplementation(function MockElixirServerManager() {
    return {
      ensureRunning: mockEnsureRunning,
      status: mockStatus,
    };
  }),
}));

vi.mock("../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: vi.fn().mockImplementation(function MockElixirServerClient() {
    return {
      sendCommand: mockSendCommand,
    };
  }),
}));

import { importCommand } from "../commands/import.js";

describe("foreman import Elixir migration", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    process.exitCode = undefined;
    mockReadFileSync.mockReturnValue(JSON.stringify({
      migration_id: "migration-cli-1",
      source: "legacy-ts-store",
      projects: [],
      tasks: [],
      runs: [],
      workflows: [],
      inbox_messages: [],
    }));
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766" });
    mockStatus.mockReturnValue({ running: true, url: "http://127.0.0.1:4766" });
    mockSendCommand.mockResolvedValue({ ok: true, events: ["event-1"], projection_version: 1, correlation_id: "migration-cli-1" });
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("dispatches foreman import --to-elixir --file to migration.import", async () => {
    await importCommand.parseAsync([
      "--to-elixir",
      "--file",
      "migration.json",
      "--command-id",
      "migration-command-1",
    ], { from: "user" });

    expect(mockResolve).toHaveBeenCalledWith("migration.json");
    expect(mockReadFileSync).toHaveBeenCalledWith("/repo/migration.json", "utf8");
    expect(mockEnsureRunning).toHaveBeenCalledOnce();
    expect(mockSendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_id: "migration-command-1",
      command_type: "migration.import",
      payload: expect.objectContaining({ migration_id: "migration-cli-1" }),
      metadata: { correlation_id: "migration-command-1", source: "foreman-cli-import" },
    }));
    expect(process.exitCode).toBeUndefined();
  });
});
