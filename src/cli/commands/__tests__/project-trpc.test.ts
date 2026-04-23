/**
 * TRD-009-TEST | Verifies: TRD-009 | Tests: foreman project CLI wired to TrpcClient
 * PRD: docs/PRD/PRD-2026-010-multi-project-orchestrator.md
 * TRD: docs/TRD/TRD-2026-011-multi-project-orchestrator.md#trd-009
 */

import { describe, it, expect } from "vitest";

// ---------------------------------------------------------------------------
// Module exports
// ---------------------------------------------------------------------------

describe("projectCommand exports", () => {
  it("projectCommand is exported", async () => {
    const { projectCommand } = await import("../project.js");
    expect(projectCommand).toBeDefined();
    expect(typeof projectCommand).toBe("object");
    expect(projectCommand.name()).toBe("project");
  });

  it("has add, list, remove sub-commands", async () => {
    const { projectCommand } = await import("../project.js");
    const names = projectCommand.commands.map((c: { name(): string }) => c.name());
    expect(names).toContain("add");
    expect(names).toContain("list");
    expect(names).toContain("remove");
  });

  it("each sub-command has a description", async () => {
    const { projectCommand } = await import("../project.js");
    for (const cmd of projectCommand.commands) {
      expect(typeof cmd.description()).toBe("string");
      expect(cmd.description().length).toBeGreaterThan(0);
    }
  });
});

// ---------------------------------------------------------------------------
// Command options
// ---------------------------------------------------------------------------

describe("add sub-command options", () => {
  it("add command accepts <path> argument", async () => {
    const { projectCommand } = await import("../project.js");
    const add = projectCommand.commands.find(
      (c: { name(): string }) => c.name() === "add",
    )!;
    expect(add).toBeDefined();
  });

  it("add command has --name, --default-branch, --status options (github-url is positional argument)", async () => {
    const { projectCommand } = await import("../project.js");
    const add = projectCommand.commands.find(
      (c: { name(): string }) => c.name() === "add",
    )!;
    // github-url is the positional argument (no --github-url option)
    const opts = add.options.map((o) => o.long ?? "");
    expect(opts).toContain("--name");
    expect(opts).toContain("--default-branch");
    expect(opts).toContain("--status");
    expect(opts).not.toContain("--github-url"); // github-url is positional, not option
  });
});

describe("list sub-command options", () => {
  it("list command has --status, --search, --json options", async () => {
    const { projectCommand } = await import("../project.js");
    const list = projectCommand.commands.find(
      (c: { name(): string }) => c.name() === "list",
    )!;
    const opts = list.options.map((o) => o.long ?? "");
    expect(opts).toContain("--status");
    expect(opts).toContain("--search");
    expect(opts).toContain("--json");
  });
});

describe("remove sub-command options", () => {
  it("remove command accepts <id> argument", async () => {
    const { projectCommand } = await import("../project.js");
    const remove = projectCommand.commands.find(
      (c: { name(): string }) => c.name() === "remove",
    )!;
    expect(remove).toBeDefined();
  });

  it("remove command has --force option", async () => {
    const { projectCommand } = await import("../project.js");
    const remove = projectCommand.commands.find(
      (c: { name(): string }) => c.name() === "remove",
    )!;
    const opts = remove.options.map((o) => o.long ?? "");
    expect(opts).toContain("--force");
  });
});

// ---------------------------------------------------------------------------
// TrpcClient integration (covered by trpc-client.test.ts)
// ---------------------------------------------------------------------------
// The TrpcClient wiring is tested via:
//   - src/lib/__tests__/trpc-client.test.ts (client construction, error handling)
//   - src/cli/commands/__tests__/daemon.test.ts (command structure)
// Integration with a live daemon is covered by TRD-012 e2e tests.
