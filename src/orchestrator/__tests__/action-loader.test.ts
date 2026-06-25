import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { mkdtempSync } from "node:fs";
import { afterEach, describe, expect, it } from "vitest";
import { existsSync } from "node:fs";
import { getForemanHomePath } from "../../lib/foreman-paths.js";
import { actionCandidates, findMissingActions, installBundledActions, loadProjectAction, validateActionsInDir, validateProjectActions } from "../action-loader.js";

describe("project action loader", () => {
  const oldHome = process.env.FOREMAN_HOME;

  afterEach(() => {
    if (oldHome === undefined) delete process.env.FOREMAN_HOME;
    else process.env.FOREMAN_HOME = oldHome;
  });

  it("loads editable project actions from .foreman/actions", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-"));
    mkdirSync(join(project, ".foreman", "actions"), { recursive: true });
    writeFileSync(join(project, ".foreman", "actions", "create-pr.js"), "export default async function run(ctx) { return { success: true, outputText: ctx.actionType }; }\n");

    const action = await loadProjectAction<{ actionType: string }, { success: boolean; outputText: string }>(project, "create-pr");
    expect(action).toBeDefined();
    await expect(action?.({ actionType: "create-pr" })).resolves.toEqual({ success: true, outputText: "create-pr" });
  });

  it("loads global actions when no project action exists", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-project-"));
    const home = mkdtempSync(join(tmpdir(), "foreman-action-home-"));
    process.env.FOREMAN_HOME = home;
    mkdirSync(join(home, "actions"), { recursive: true });
    writeFileSync(join(home, "actions", "notify.js"), "export const run = async (ctx) => ({ success: true, outputText: `global:${ctx.actionType}` });\n");

    const action = await loadProjectAction<{ actionType: string }, { success: boolean; outputText: string }>(project, "notify");
    await expect(action?.({ actionType: "notify" })).resolves.toEqual({ success: true, outputText: "global:notify" });
  });

  it("loads named run when a non-function default export is present", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-project-"));
    mkdirSync(join(project, ".foreman", "actions"), { recursive: true });
    writeFileSync(join(project, ".foreman", "actions", "notify.js"), "export default 1; export async function run(ctx) { return { success: true, outputText: ctx.actionType }; }\n");

    const action = await loadProjectAction<{ actionType: string }, { success: boolean; outputText: string }>(project, "notify");
    await expect(action?.({ actionType: "notify" })).resolves.toEqual({ success: true, outputText: "notify" });
  });

  it("loads TypeScript action modules", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-project-"));
    mkdirSync(join(project, ".foreman", "actions"), { recursive: true });
    writeFileSync(join(project, ".foreman", "actions", "typed.ts"), "type Ctx = { actionType: string };\nexport const run = async (ctx: Ctx): Promise<{ success: boolean; outputText: string }> => ({ success: true, outputText: `ts:${ctx.actionType}` });\n");

    const action = await loadProjectAction<{ actionType: string }, { success: boolean; outputText: string }>(project, "typed");
    await expect(action?.({ actionType: "typed" })).resolves.toEqual({ success: true, outputText: "ts:typed" });
  });

  it("bundles JavaScript action dependencies before loading", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-project-"));
    mkdirSync(join(project, ".foreman", "actions"), { recursive: true });
    mkdirSync(join(project, ".foreman", "action-lib"), { recursive: true });
    writeFileSync(join(project, ".foreman", "action-lib", "helper.ts"), "export const label = (value: string): string => `helper:${value}`;\n");
    writeFileSync(join(project, ".foreman", "actions", "notify.js"), "import { label } from '../action-lib/helper.ts';\nexport const run = async (ctx) => ({ success: true, outputText: label(ctx.actionType) });\n");

    const action = await loadProjectAction<{ actionType: string }, { success: boolean; outputText: string }>(project, "notify");
    await expect(action?.({ actionType: "notify" })).resolves.toEqual({ success: true, outputText: "helper:notify" });
  });

  it("prefers project actions over global actions", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-project-"));
    const home = mkdtempSync(join(tmpdir(), "foreman-action-home-"));
    process.env.FOREMAN_HOME = home;
    mkdirSync(join(project, ".foreman", "actions"), { recursive: true });
    mkdirSync(join(home, "actions"), { recursive: true });
    writeFileSync(join(project, ".foreman", "actions", "notify.js"), "export default async () => ({ success: true, outputText: 'project' });\n");
    writeFileSync(join(home, "actions", "notify.js"), "export default async () => ({ success: true, outputText: 'global' });\n");

    const action = await loadProjectAction<unknown, { success: boolean; outputText: string }>(project, "notify");
    await expect(action?.({})).resolves.toEqual({ success: true, outputText: "project" });
  });

  it("includes project actions before global actions in resolution candidates", () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-"));
    expect(actionCandidates(project, "create-pr")).toEqual([
      join(project, ".foreman", "actions", "create-pr.mjs"),
      join(project, ".foreman", "actions", "create-pr.js"),
      join(project, ".foreman", "actions", "create-pr.ts"),
      getForemanHomePath("actions", "create-pr.mjs"),
      getForemanHomePath("actions", "create-pr.js"),
      getForemanHomePath("actions", "create-pr.ts"),
    ]);
  });

  it("ignores unsafe action names", async () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-"));
    await expect(loadProjectAction(project, "../create-pr")).resolves.toBeUndefined();
    await expect(loadProjectAction(project, "...")).resolves.toBeUndefined();
  });

  it("validates action module names and exports", () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-validate-"));
    mkdirSync(join(project, ".foreman", "actions"), { recursive: true });
    writeFileSync(join(project, ".foreman", "actions", "good.js"), "export async function run(ctx) { return ctx.internal.runBuiltin(); }\n");
    writeFileSync(join(project, ".foreman", "actions", "arrow.js"), "export default async (ctx) => ctx.internal.runBuiltin();\n");
    writeFileSync(join(project, ".foreman", "actions", "identifier-arrow.js"), "export default async ctx => ctx.internal.runBuiltin();\n");
    writeFileSync(join(project, ".foreman", "actions", "const-run.js"), "export const run = async (ctx) => ctx.internal.runBuiltin();\n");
    writeFileSync(join(project, ".foreman", "actions", "typed.ts"), "export const run: unknown = async (ctx) => ctx;\n");
    writeFileSync(join(project, ".foreman", "actions", "typed-return.ts"), "type Result = { success: boolean }; export const run = async (ctx: unknown): Promise<Result> => ({ success: true });\n");
    writeFileSync(join(project, ".foreman", "actions", "typed-default.ts"), "type Result = { success: boolean }; export default async (ctx: unknown): Promise<Result> => ({ success: true });\n");
    writeFileSync(join(project, ".foreman", "actions", "re-export-run.js"), "const run = async (ctx) => ctx.internal.runBuiltin(); export { run };\n");
    writeFileSync(join(project, ".foreman", "actions", "re-export-before-run.js"), "export { run }; const run = async (ctx) => ctx.internal.runBuiltin();\n");
    writeFileSync(join(project, ".foreman", "actions", "alias-run.js"), "const execute = async (ctx) => ctx.internal.runBuiltin(); export { execute as run };\n");
    writeFileSync(join(project, ".foreman", "actions", "function-alias-run.js"), "function execute(ctx) { return ctx.internal.runBuiltin(); } export { execute as run };\n");
    writeFileSync(join(project, ".foreman", "actions", "alias-default.js"), "const execute = async (ctx) => ctx.internal.runBuiltin(); export { execute as default };\n");
    writeFileSync(join(project, ".foreman", "actions", "default-identifier.js"), "const execute = async (ctx) => ctx.internal.runBuiltin(); export default execute;\n");
    writeFileSync(join(project, ".foreman", "actions", "default-function-identifier.js"), "function execute(ctx) { return ctx.internal.runBuiltin(); } export default execute;\n");
    writeFileSync(join(project, ".foreman", "actions", "bad.js"), "export const nope = 1;\n");
    writeFileSync(join(project, ".foreman", "actions", "default-value.js"), "const run = 1; export default run;\n");
    writeFileSync(join(project, ".foreman", "actions", "run-value.js"), "export const run = 1;\n");
    writeFileSync(join(project, ".foreman", "actions", "missing-run.js"), "export { run };\n");
    writeFileSync(join(project, ".foreman", "actions", "commented-export.js"), "// export default async function run() {}\nconst nope = 1;\n");
    writeFileSync(join(project, ".foreman", "actions", "string-export.js"), "const sample = 'export async function run() {}';\n");
    writeFileSync(join(project, ".foreman", "actions", "syntax.js"), "export async function run(ctx) { return ctx.internal.runBuiltin();\n");
    writeFileSync(join(project, ".foreman", "actions", "syntax-ts.ts"), "export const run: = async (ctx) => ctx;\n");
    writeFileSync(join(project, ".foreman", "actions", "missing-import.js"), "import { helper } from './missing-helper.js'; export const run = async (ctx) => helper(ctx);\n");
    writeFileSync(join(project, ".foreman", "actions", "block-comment-export.js"), "/* export const run = async () => ({ success: true }); */\nconst nope = 1;\n");
    writeFileSync(join(project, ".foreman", "actions", "dup.js"), "export default async () => ({ success: true });\n");
    writeFileSync(join(project, ".foreman", "actions", "dup.mjs"), "export default async () => ({ success: true });\n");
    writeFileSync(join(project, ".foreman", "actions", "bad$name.js"), "export default function run() {}\n");

    expect(validateProjectActions(project)).toEqual({
      invalidNames: ["bad$name.js"],
      invalidExports: ["bad.js", "block-comment-export.js", "commented-export.js", "default-value.js", "missing-import.js", "missing-run.js", "run-value.js", "string-export.js", "syntax-ts.ts", "syntax.js"],
      duplicateNames: ["dup"],
    });
    expect(validateActionsInDir(join(project, ".foreman", "actions"))).toEqual({
      invalidNames: ["bad$name.js"],
      invalidExports: ["bad.js", "block-comment-export.js", "commented-export.js", "default-value.js", "missing-import.js", "missing-run.js", "run-value.js", "string-export.js", "syntax-ts.ts", "syntax.js"],
      duplicateNames: ["dup"],
    });
  });

  it("does not report bundled actions missing when another supported variant exists", () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-missing-"));
    mkdirSync(join(project, ".foreman", "actions"), { recursive: true });
    writeFileSync(join(project, ".foreman", "actions", "create-pr.ts"), "export const run = async (ctx) => ctx.internal.runBuiltin();\n");

    expect(findMissingActions(project)).not.toContain("create-pr.js");
  });

  it("installs bundled action stubs into project .foreman/actions", () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-action-install-"));
    const result = installBundledActions(project);
    expect(result.installed).toContain("create-pr.js");
    expect(existsSync(join(project, ".foreman", "actions", "create-pr.js"))).toBe(true);
  });
});
