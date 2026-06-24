import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { Command } from "commander";
import chalk from "chalk";
import { getForemanHomePath } from "../../lib/foreman-paths.js";
import { actionCandidates, isSafeActionName, listBundledActionFiles, validateProjectActions } from "../../orchestrator/action-loader.js";

export interface ActionListRow {
  action: string;
  source: "project" | "global" | "bundled" | "missing";
  path: string | null;
}

function actionNameFromFile(file: string): string {
  return file.replace(/\.(mjs|js)$/i, "");
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
