import { describe, expect, it, vi } from "vitest";
import {
  LEGACY_DELEGATABLE_COMMANDS,
  delegatableCommand,
  maybeDelegateToLegacyTs,
  shouldUseLegacyCompatibility,
} from "../legacy-coexistence.js";

const migrationCommands = [
  "run",
  "status",
  "watch",
  "reset",
  "retry",
  "stop",
  "merge",
  "pr",
  "attach",
  "inbox",
  "task",
  "plan",
  "sling",
  "doctor",
];

describe("legacy TS coexistence delegation", () => {
  it("enumerates the PRD migration compatibility command surface", () => {
    expect([...LEGACY_DELEGATABLE_COMMANDS]).toEqual(migrationCommands);
    for (const command of migrationCommands) {
      expect(delegatableCommand([command, "--help"])).toBe(command);
    }
  });

  it("enables delegation only while compatibility mode is active and migration is incomplete", () => {
    expect(shouldUseLegacyCompatibility({ FOREMAN_LEGACY_COMPATIBILITY_MODE: "1" })).toBe(true);
    expect(
      shouldUseLegacyCompatibility({
        FOREMAN_LEGACY_COMPATIBILITY_MODE: "1",
        FOREMAN_MIGRATION_COMPLETE: "true",
      }),
    ).toBe(false);
    expect(shouldUseLegacyCompatibility({})).toBe(false);
    expect(
      shouldUseLegacyCompatibility({
        FOREMAN_LEGACY_COMPATIBILITY_MODE: "1",
        FOREMAN_BACKEND: "elixir",
      }),
    ).toBe(false);
  });

  it("delegates supported commands to configured legacy TS binary", () => {
    const spawn = vi.fn(() => ({ status: 7 })) as any;

    const result = maybeDelegateToLegacyTs(
      ["run", "--dry-run"],
      {
        FOREMAN_LEGACY_COMPATIBILITY_MODE: "legacy",
        FOREMAN_LEGACY_TS_BIN: "/tmp/foreman-legacy",
      },
      spawn,
    );

    expect(result).toMatchObject({ delegated: true, command: "run", status: 7 });
    expect(spawn).toHaveBeenCalledWith(
      "/tmp/foreman-legacy",
      ["run", "--dry-run"],
      expect.objectContaining({ stdio: "inherit" }),
    );
  });

  it("fails with actionable diagnostics when compatibility mode lacks a legacy binary", () => {
    expect(() =>
      maybeDelegateToLegacyTs(["status"], { FOREMAN_LEGACY_COMPATIBILITY_MODE: "1" }, vi.fn() as any),
    ).toThrow(/FOREMAN_LEGACY_TS_BIN/);
  });

  it("does not delegate when Elixir backend mode is active", () => {
    expect(
      maybeDelegateToLegacyTs(
        ["run"],
        {
          FOREMAN_BACKEND: "elixir",
          FOREMAN_LEGACY_COMPATIBILITY_MODE: "1",
          FOREMAN_LEGACY_TS_BIN: "/tmp/legacy",
        },
        vi.fn() as any,
      ),
    ).toEqual({ delegated: false, reason: "migration-complete" });
  });

  it("does not delegate unsupported commands", () => {
    expect(
      maybeDelegateToLegacyTs(
        ["project", "list"],
        {
          FOREMAN_LEGACY_COMPATIBILITY_MODE: "1",
          FOREMAN_LEGACY_TS_BIN: "/tmp/legacy",
        },
        vi.fn() as any,
      ),
    ).toEqual({ delegated: false, reason: "not-delegatable" });
  });
});
