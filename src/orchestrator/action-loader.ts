import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join } from "node:path";
import { getForemanHomePath } from "../lib/foreman-paths.js";
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

export const BUNDLED_ACTIONS_DIR = join(__dirname, "..", "defaults", "actions");

export interface ExternalActionModule<Context, Result> {
  default?: (ctx: Context) => Promise<Result> | Result;
  run?: (ctx: Context) => Promise<Result> | Result;
}

export function isSafeActionName(actionType: string): boolean {
  return /^[a-zA-Z0-9._-]+$/.test(actionType);
}

export function projectActionCandidates(projectPath: string, actionType: string): string[] {
  if (!isSafeActionName(actionType)) return [];
  return [
    join(projectPath, ".foreman", "actions", `${actionType}.mjs`),
    join(projectPath, ".foreman", "actions", `${actionType}.js`),
  ];
}

export function globalActionCandidates(actionType: string): string[] {
  if (!isSafeActionName(actionType)) return [];
  return [
    getForemanHomePath("actions", `${actionType}.mjs`),
    getForemanHomePath("actions", `${actionType}.js`),
  ];
}

export function actionCandidates(projectPath: string, actionType: string): string[] {
  return [...projectActionCandidates(projectPath, actionType), ...globalActionCandidates(actionType)];
}

export function findProjectActionPath(projectPath: string, actionType: string): string | undefined {
  return actionCandidates(projectPath, actionType).find((candidate) => existsSync(candidate));
}

export async function loadProjectAction<Context, Result = unknown>(projectPath: string, actionType: string): Promise<((ctx: Context) => Promise<Result> | Result) | undefined> {
  if (!isSafeActionName(actionType)) return undefined;
  for (const candidate of actionCandidates(projectPath, actionType)) {
    if (!existsSync(candidate)) continue;
    const mod = await import(`${pathToFileURL(candidate).href}?t=${Date.now()}`) as ExternalActionModule<Context, Result>;
    const runner = mod.default ?? mod.run;
    if (typeof runner !== "function") throw new Error(`Action ${actionType} at ${candidate} must export default(ctx) or run(ctx)`);
    return runner;
  }
  return undefined;
}

export function listBundledActionFiles(): string[] {
  try {
    return readdirSync(BUNDLED_ACTIONS_DIR).filter((file) => file.endsWith(".js") || file.endsWith(".mjs")).sort();
  } catch {
    return [];
  }
}

export function findMissingActions(projectRoot: string): string[] {
  return listBundledActionFiles().filter((file) => !existsSync(join(projectRoot, ".foreman", "actions", file)));
}

export interface ActionValidationResult {
  invalidNames: string[];
  invalidExports: string[];
  duplicateNames: string[];
}

export function validateActionsInDir(dir: string): ActionValidationResult {
  const invalidNames: string[] = [];
  const invalidExports: string[] = [];
  const duplicateNames: string[] = [];
  let files: string[] = [];
  try {
    files = readdirSync(dir).filter((file) => file.endsWith(".js") || file.endsWith(".mjs")).sort();
  } catch {
    return { invalidNames, invalidExports, duplicateNames };
  }
  const actionCounts = new Map<string, number>();
  for (const file of files) {
    const actionName = file.replace(/\.(mjs|js)$/i, "");
    actionCounts.set(actionName, (actionCounts.get(actionName) ?? 0) + 1);
  }
  for (const [actionName, count] of actionCounts.entries()) {
    if (count > 1) duplicateNames.push(actionName);
  }
  for (const file of files) {
    const actionName = file.replace(/\.(mjs|js)$/i, "");
    if (!isSafeActionName(actionName)) {
      invalidNames.push(file);
      continue;
    }
    const source = readFileSync(join(dir, file), "utf8");
    if (!/export\s+default\s+(async\s+)?function\b/.test(source)
      && !/export\s+default\s+(async\s+)?\([^)]*\)\s*=>/.test(source)
      && !/export\s+(async\s+)?function\s+run\b/.test(source)
      && !/export\s+(const|let|var)\s+run\s*=\s*(async\s*)?(function\b|\([^)]*\)\s*=>|[a-zA-Z_$][\w$]*\s*=>)/.test(source)
      && !/((async\s+)?function\s+run\b|(const|let|var)\s+run\s*=\s*(async\s*)?(function\b|\([^)]*\)\s*=>|[a-zA-Z_$][\w$]*\s*=>))[\s\S]*export\s*\{[^}]*\brun\b[^}]*\}/.test(source)) {
      invalidExports.push(file);
    }
  }
  return { invalidNames, invalidExports, duplicateNames };
}

export function validateProjectActions(projectRoot: string): ActionValidationResult {
  return validateActionsInDir(join(projectRoot, ".foreman", "actions"));
}

export function validateGlobalActions(): ActionValidationResult {
  return validateActionsInDir(getForemanHomePath("actions"));
}

export function installBundledActionsToDir(
  destDir: string,
  force = false,
): { installed: string[]; skipped: string[] } {
  const installed: string[] = [];
  const skipped: string[] = [];
  mkdirSync(destDir, { recursive: true });
  const files = listBundledActionFiles();
  for (const file of files) {
    const destPath = join(destDir, file);
    if (existsSync(destPath) && !force) {
      skipped.push(file);
    } else {
      copyFileSync(join(BUNDLED_ACTIONS_DIR, file), destPath);
      installed.push(file);
    }
  }
  return { installed, skipped };
}

export function installBundledActions(
  projectRoot: string,
  force = false,
): { installed: string[]; skipped: string[] } {
  return installBundledActionsToDir(join(projectRoot, ".foreman", "actions"), force);
}
