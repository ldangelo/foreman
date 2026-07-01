import { describe, expect, it } from "vitest";
import { foremanBackendMode, migrationComplete, nodeDaemonAllowed, nodeDaemonDisabledMessage } from "../backend-mode.js";
import { createTrpcClient } from "../trpc-client.js";

describe("Foreman backend mode", () => {
  it("always selects Elixir after cutover", () => {
    expect(foremanBackendMode({})).toBe("elixir");
    expect(foremanBackendMode({ FOREMAN_BACKEND: "node" })).toBe("elixir");
    expect(nodeDaemonAllowed({ FOREMAN_BACKEND: "node" })).toBe(false);
  });

  it("reports migration as complete after cutover", () => {
    expect(migrationComplete({})).toBe(true);
    expect(migrationComplete({ FOREMAN_MIGRATION_COMPLETE: "false" })).toBe(true);
  });

  it("explains that the Node daemon scheduler was removed", () => {
    expect(nodeDaemonDisabledMessage({ FOREMAN_BACKEND: "node" })).toContain("removed after the Elixir backend cutover");
    expect(nodeDaemonDisabledMessage({})).toContain("foreman server start");
  });

  it("blocks implicit Node daemon tRPC clients before socket use", () => {
    const oldBackend = process.env.FOREMAN_BACKEND;
    process.env.FOREMAN_BACKEND = "node";
    try {
      expect(() => createTrpcClient()).toThrow(/removed legacy Node daemon tRPC API/);
    } finally {
      if (oldBackend === undefined) delete process.env.FOREMAN_BACKEND;
      else process.env.FOREMAN_BACKEND = oldBackend;
    }
  });
});
