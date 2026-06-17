import { describe, expect, it } from "vitest";
import { foremanBackendMode, migrationComplete, nodeDaemonAllowed, nodeDaemonDisabledMessage } from "../backend-mode.js";

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

  it("treats migration completion as an Elixir cutover gate", () => {
    const env = { FOREMAN_MIGRATION_COMPLETE: "true" };
    expect(migrationComplete(env)).toBe(true);
    expect(foremanBackendMode(env)).toBe("elixir");
    expect(nodeDaemonAllowed(env)).toBe(false);
    expect(nodeDaemonDisabledMessage(env)).toContain("FOREMAN_MIGRATION_COMPLETE");
  });
});
