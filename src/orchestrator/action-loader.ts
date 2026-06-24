import { copyFileSync, existsSync, mkdirSync, readdirSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join } from "node:path";
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

export function findProjectActionPath(projectPath: string, actionType: string): string | undefined {
  return projectActionCandidates(projectPath, actionType).find((candidate) => existsSync(candidate));
}

export async function loadProjectAction<Context, Result = unknown>(projectPath: string, actionType: string): Promise<((ctx: Context) => Promise<Result> | Result) | undefined> {
  if (!isSafeActionName(actionType)) return undefined;
  for (const candidate of projectActionCandidates(projectPath, actionType)) {
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

export function installBundledActions(
  projectRoot: string,
  force = false,
): { installed: string[]; skipped: string[] } {
  const installed: string[] = [];
  const skipped: string[] = [];
  const destDir = join(projectRoot, ".foreman", "actions");
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
