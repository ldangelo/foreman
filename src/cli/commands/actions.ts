import { existsSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Command } from "commander";
import chalk from "chalk";
import { getForemanHomePath } from "../../lib/foreman-paths.js";
import { actionCandidates, findProjectActionPath, installBundledActions, isSafeActionName, listBundledActionFiles, validateProjectActions } from "../../orchestrator/action-loader.js";

export interface ActionListRow {
  action: string;
  source: "project" | "global" | "bundled" | "missing";
  path: string | null;
}

function actionNameFromFile(file: string): string {
  return file.replace(/\.(mjs|js)$/i, "");
}

export function customActionStub(action: string): string {
  return `/**\n * Custom Foreman action: ${action}\n *\n * ctx fields include actionType, phase, config, workflowConfig, log, mail, and internal.runBuiltin().\n * Return { success: boolean, outputText?: string, error?: string, costUsd?: number, turns?: number }.\n */\nexport default async function run(ctx) {\n  ctx.log?.(\`[ACTION:${action}] custom action starting\`);\n  // Wrap existing built-in behavior when overriding bundled actions:\n  // return ctx.internal.runBuiltin();\n  return { success: true, costUsd: 0, turns: 0, tokensIn: 0, tokensOut: 0, outputText: \"${action} completed\" };\n}\n`;
}

function actionFiles(dir: string): string[] {
  try {
    return readdirSync(dir).filter((file) => file.endsWith(".js") || file.endsWith(".mjs"));
  } catch {
    return [];
  }
}

export function listActions(projectPath: string): ActionListRow[] {
  const names = new Set<string>();
  for (const file of listBundledActionFiles()) names.add(actionNameFromFile(file));
  for (const file of actionFiles(join(projectPath, ".foreman", "actions"))) names.add(actionNameFromFile(file));
  for (const file of actionFiles(getForemanHomePath("actions"))) names.add(actionNameFromFile(file));

  return [...names].sort().map((action) => {
    const [projectMjs, projectJs, globalMjs, globalJs] = actionCandidates(projectPath, action);
    const resolved = [projectMjs, projectJs, globalMjs, globalJs].find((candidate) => candidate && existsSync(candidate));
    if (resolved && (resolved === projectMjs || resolved === projectJs)) return { action, source: "project", path: resolved };
    if (resolved && (resolved === globalMjs || resolved === globalJs)) return { action, source: "global", path: resolved };
    const bundled = listBundledActionFiles().find((file) => actionNameFromFile(file) === action);
    return { action, source: bundled ? "bundled" : "missing", path: bundled ? `<bundled>/${bundled}` : null };
  });
}

export const actionsCommand = new Command("actions")
  .description("List and validate Foreman workflow action modules");

actionsCommand
  .command("list")
  .description("List bundled, project, and global action modules")
  .option("--json", "Output JSON")
  .action((opts: { json?: boolean }) => {
    const projectPath = process.cwd();
    const rows = listActions(projectPath);
    if (opts.json) {
      console.log(JSON.stringify(rows, null, 2));
      return;
    }
    for (const row of rows) {
      const sourceLabel = row.source.padEnd(10);
      const source = row.source === "project" ? chalk.green(sourceLabel) : row.source === "global" ? chalk.cyan(sourceLabel) : chalk.dim(sourceLabel);
      const unsafe = isSafeActionName(row.action) ? "" : chalk.red(" unsafe-name");
      console.log(`${row.action.padEnd(22)} ${source} ${row.path ?? ""}${unsafe}`);
    }
    const invalid = validateProjectActions(projectPath);
    if (invalid.invalidNames.length || invalid.invalidExports.length) {
      console.error(chalk.red(`\nInvalid project actions: names=${invalid.invalidNames.join(", ") || "none"} exports=${invalid.invalidExports.join(", ") || "none"}`));
      process.exitCode = 1;
    }
  });

actionsCommand
  .command("show")
  .description("Show the resolved module path for one action")
  .argument("<action>", "Action name")
  .option("--json", "Output JSON")
  .action((action: string, opts: { json?: boolean }) => {
    const projectPath = process.cwd();
    const row = listActions(projectPath).find((candidate) => candidate.action === action);
    const resolvedPath = findProjectActionPath(projectPath, action);
    const result = row ?? { action, source: resolvedPath ? "project" : "missing", path: resolvedPath ?? null };
    if (opts.json) {
      console.log(JSON.stringify(result, null, 2));
      return;
    }
    if (!isSafeActionName(action)) {
      console.error(chalk.red(`Unsafe action name: ${action}`));
      process.exitCode = 1;
      return;
    }
    if (!row && !resolvedPath) {
      console.error(chalk.red(`Action not found: ${action}`));
      process.exitCode = 1;
      return;
    }
    console.log(`${result.action}: ${result.path ?? result.source}`);
  });

actionsCommand
  .command("install")
  .description("Install bundled editable action stubs into .foreman/actions")
  .option("--force", "Overwrite existing project action files")
  .option("--json", "Output JSON")
  .action((opts: { force?: boolean; json?: boolean }) => {
    const result = installBundledActions(process.cwd(), !!opts.force);
    if (opts.json) {
      console.log(JSON.stringify(result, null, 2));
      return;
    }
    console.log(`Installed ${result.installed.length} action module(s); skipped ${result.skipped.length}.`);
  });

actionsCommand
  .command("create")
  .description("Create a new project action stub in .foreman/actions")
  .argument("<action>", "Action name")
  .option("--force", "Overwrite an existing project action file")
  .option("--json", "Output JSON")
  .action((action: string, opts: { force?: boolean; json?: boolean }) => {
    if (!isSafeActionName(action)) {
      console.error(chalk.red(`Unsafe action name: ${action}`));
      process.exitCode = 1;
      return;
    }
    const projectPath = process.cwd();
    const dir = join(projectPath, ".foreman", "actions");
    const file = join(dir, `${action}.js`);
    mkdirSync(dir, { recursive: true });
    if (existsSync(file) && !opts.force) {
      const result = { action, path: file, created: false, reason: "exists" };
      if (opts.json) console.log(JSON.stringify(result, null, 2));
      else console.error(chalk.yellow(`Action already exists: ${file} (use --force to overwrite)`));
      process.exitCode = 1;
      return;
    }
    writeFileSync(file, customActionStub(action), "utf8");
    const result = { action, path: file, created: true };
    if (opts.json) console.log(JSON.stringify(result, null, 2));
    else console.log(`Created action: ${file}`);
  });
