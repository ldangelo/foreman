import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";
import { existsSync } from "node:fs";
import { actionsCommand, customActionStub, findUnresolvedWorkflowActions, listActions } from "../commands/actions.js";

describe("actions command helpers", () => {
  it("loads command with list/show/install subcommands", () => {
    expect(actionsCommand.name()).toBe("actions");
    expect(actionsCommand.commands.map((cmd) => cmd.name())).toEqual(["list", "show", "install", "validate", "create"]);
  });

  it("lists project overrides before bundled actions", () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-actions-list-"));
    mkdirSync(join(project, ".foreman", "actions"), { recursive: true });
    writeFileSync(join(project, ".foreman", "actions", "create-pr.js"), "export default function run(ctx) { return ctx.internal.runBuiltin(); }\n");

    const rows = listActions(project);
    expect(rows.find((row) => row.action === "create-pr")).toMatchObject({ source: "project" });
    expect(rows.some((row) => row.action === "finalize")).toBe(true);
  });

  it("reports no unresolved workflow actions for bundled workflows", () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-actions-unresolved-"));
    expect(findUnresolvedWorkflowActions(project)).toEqual([]);
  });

  it("renders a valid custom action stub", () => {
    expect(customActionStub("notify-slack")).toContain("export default async function run(ctx)");
    expect(customActionStub("notify-slack")).toContain("notify-slack completed");
  });

  it("installs bundled action stubs from the command", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-actions-install-"));
    const cwd = process.cwd();
    process.chdir(project);
    try {
      await actionsCommand.parseAsync(["node", "foreman", "install"]);
      expect(existsSync(join(project, ".foreman", "actions", "create-pr.js"))).toBe(true);
    } finally {
      process.chdir(cwd);
    }
  });

  it("installs global bundled action stubs from the command", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-actions-global-install-"));
    const cwd = process.cwd();
    const oldHome = process.env.FOREMAN_HOME;
    process.env.FOREMAN_HOME = join(project, "foreman-home");
    process.chdir(project);
    try {
      await actionsCommand.parseAsync(["node", "foreman", "install", "--global"]);
      expect(existsSync(join(project, "foreman-home", "actions", "create-pr.js"))).toBe(true);
    } finally {
      process.chdir(cwd);
      if (oldHome === undefined) delete process.env.FOREMAN_HOME;
      else process.env.FOREMAN_HOME = oldHome;
    }
  });

  it("creates a custom project action stub from the command", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-actions-create-"));
    const cwd = process.cwd();
    process.chdir(project);
    try {
      await actionsCommand.parseAsync(["node", "foreman", "create", "notify-slack"]);
      expect(existsSync(join(project, ".foreman", "actions", "notify-slack.js"))).toBe(true);
    } finally {
      process.chdir(cwd);
    }
  });

  it("creates a custom global action stub from the command", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-actions-global-create-"));
    const cwd = process.cwd();
    const oldHome = process.env.FOREMAN_HOME;
    process.env.FOREMAN_HOME = join(project, "foreman-home");
    process.chdir(project);
    try {
      await actionsCommand.parseAsync(["node", "foreman", "create", "notify-global", "--global", "--force"]);
      expect(existsSync(join(project, "foreman-home", "actions", "notify-global.js"))).toBe(true);
    } finally {
      process.chdir(cwd);
      if (oldHome === undefined) delete process.env.FOREMAN_HOME;
      else process.env.FOREMAN_HOME = oldHome;
    }
  });
});
