import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { mkdtempSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { loadProjectAction } from "../action-loader.js";

describe("project action loader", () => {
  it("loads editable project actions from .foreman/actions", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-"));
    mkdirSync(join(project, ".foreman", "actions"), { recursive: true });
    writeFileSync(join(project, ".foreman", "actions", "create-pr.js"), "export default async function run(ctx) { return { success: true, outputText: ctx.actionType }; }\n");

    const action = await loadProjectAction<{ actionType: string }, { success: boolean; outputText: string }>(project, "create-pr");
    expect(action).toBeDefined();
    await expect(action?.({ actionType: "create-pr" })).resolves.toEqual({ success: true, outputText: "create-pr" });
  });

  it("ignores unsafe action names", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-"));
    await expect(loadProjectAction(project, "../create-pr")).resolves.toBeUndefined();
  });
});
