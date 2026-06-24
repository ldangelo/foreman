import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";
import { existsSync } from "node:fs";
import { actionsCommand, listActions } from "../commands/actions.js";

describe("actions command helpers", () => {
  it("loads command with list/show/install subcommands", () => {
    expect(actionsCommand.name()).toBe("actions");
    expect(actionsCommand.commands.map((cmd) => cmd.name())).toEqual(["list", "show", "install"]);
  });

  it("lists project overrides before bundled actions", () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-actions-list-"));
    mkdirSync(join(project, ".foreman", "actions"), { recursive: true });
    writeFileSync(join(project, ".foreman", "actions", "create-pr.js"), "export default function run(ctx) { return ctx.internal.runBuiltin(); }\n");

    const rows = listActions(project);
    expect(rows.find((row) => row.action === "create-pr")).toMatchObject({ source: "project" });
    expect(rows.some((row) => row.action === "finalize")).toBe(true);
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
});
