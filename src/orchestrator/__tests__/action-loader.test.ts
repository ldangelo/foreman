import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { mkdtempSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { existsSync } from "node:fs";
import { getForemanHomePath } from "../../lib/foreman-paths.js";
import { actionCandidates, installBundledActions, loadProjectAction, validateActionsInDir, validateProjectActions } from "../action-loader.js";

describe("project action loader", () => {
  it("loads editable project actions from .foreman/actions", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-"));
    mkdirSync(join(project, ".foreman", "actions"), { recursive: true });
    writeFileSync(join(project, ".foreman", "actions", "create-pr.js"), "export default async function run(ctx) { return { success: true, outputText: ctx.actionType }; }\n");

    const action = await loadProjectAction<{ actionType: string }, { success: boolean; outputText: string }>(project, "create-pr");
    expect(action).toBeDefined();
    await expect(action?.({ actionType: "create-pr" })).resolves.toEqual({ success: true, outputText: "create-pr" });
  });

  it("includes project actions before global actions in resolution candidates", () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-"));
    expect(actionCandidates(project, "create-pr")).toEqual([
      join(project, ".foreman", "actions", "create-pr.mjs"),
      join(project, ".foreman", "actions", "create-pr.js"),
      getForemanHomePath("actions", "create-pr.mjs"),
      getForemanHomePath("actions", "create-pr.js"),
    ]);
  });

  it("ignores unsafe action names", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-"));
    await expect(loadProjectAction(project, "../create-pr")).resolves.toBeUndefined();
  });

  it("validates action module names and exports", () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-validate-"));
    mkdirSync(join(project, ".foreman", "actions"), { recursive: true });
    writeFileSync(join(project, ".foreman", "actions", "good.js"), "export async function run(ctx) { return ctx.internal.runBuiltin(); }\n");
    writeFileSync(join(project, ".foreman", "actions", "bad.js"), "export const nope = 1;\n");
    writeFileSync(join(project, ".foreman", "actions", "bad$name.js"), "export default function run() {}\n");

    expect(validateProjectActions(project)).toEqual({
      invalidNames: ["bad$name.js"],
      invalidExports: ["bad.js"],
    });
    expect(validateActionsInDir(join(project, ".foreman", "actions"))).toEqual({
      invalidNames: ["bad$name.js"],
      invalidExports: ["bad.js"],
    });
  });

  it("installs bundled action stubs into project .foreman/actions", () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-install-"));
    const result = installBundledActions(project);
    expect(result.installed).toContain("create-pr.js");
    expect(existsSync(join(project, ".foreman", "actions", "create-pr.js"))).toBe(true);
  });
});
