import { describe, expect, it } from "vitest";
import { foremanBackendMode, migrationComplete, nodeDaemonAllowed, nodeDaemonDisabledMessage } from "../backend-mode.js";
import { createTrpcClient } from "../trpc-client.js";

describe("Foreman backend mode", () => {
  it("defaults to Node until the migration is complete", () => {
    expect(foremanBackendMode({})).toBe("node");
    expect(nodeDaemonAllowed({})).toBe(true);
  });

  it("selects Elixir and disables the Node daemon scheduler when requested", () => {
    const env = { FOREMAN_BACKEND: "elixir" };
    expect(foremanBackendMode(env)).toBe("elixir");
    expect(nodeDaemonAllowed(env)).toBe(false);
    expect(nodeDaemonDisabledMessage(env)).toContain("FOREMAN_BACKEND=elixir");
  });

  it("blocks implicit Node daemon tRPC clients in Elixir mode before socket use", () => {
    const oldBackend = process.env.FOREMAN_BACKEND;
    process.env.FOREMAN_BACKEND = "elixir";
    try {
      expect(() => createTrpcClient()).toThrow(/Elixir backend parity gap/);
    } finally {
      if (oldBackend === undefined) delete process.env.FOREMAN_BACKEND;
      else process.env.FOREMAN_BACKEND = oldBackend;
    }
  });

  it("still allows explicit legacy tRPC clients in Node mode", () => {
    const oldBackend = process.env.FOREMAN_BACKEND;
    process.env.FOREMAN_BACKEND = "node";
    try {
      expect(() => createTrpcClient()).not.toThrow();
    } finally {
      if (oldBackend === undefined) delete process.env.FOREMAN_BACKEND;
      else process.env.FOREMAN_BACKEND = oldBackend;
    }
  });

  it("treats migration completion as an Elixir cutover gate", () => {
    const env = { FOREMAN_MIGRATION_COMPLETE: "true" };
    expect(migrationComplete(env)).toBe(true);
    expect(foremanBackendMode(env)).toBe("elixir");
    expect(nodeDaemonAllowed(env)).toBe(false);
    expect(nodeDaemonDisabledMessage(env)).toContain("FOREMAN_MIGRATION_COMPLETE");
  });
});
