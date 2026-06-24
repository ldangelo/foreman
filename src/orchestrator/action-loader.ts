import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { buildSync } from "esbuild";
import { getForemanHomePath } from "../lib/foreman-paths.js";
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

export const BUNDLED_ACTIONS_DIR = join(__dirname, "..", "defaults", "actions");

export interface ExternalActionModule<Context, Result> {
  default?: (ctx: Context) => Promise<Result> | Result;
  run?: (ctx: Context) => Promise<Result> | Result;
}

export function isSafeActionName(actionType: string): boolean {
  return /^[a-zA-Z0-9._-]+$/.test(actionType) && /[a-zA-Z0-9]/.test(actionType);
}

export function projectActionCandidates(projectPath: string, actionType: string): string[] {
  if (!isSafeActionName(actionType)) return [];
  return [
    join(projectPath, ".foreman", "actions", `${actionType}.mjs`),
    join(projectPath, ".foreman", "actions", `${actionType}.js`),
    join(projectPath, ".foreman", "actions", `${actionType}.ts`),
  ];
}

export function globalActionCandidates(actionType: string): string[] {
  if (!isSafeActionName(actionType)) return [];
  return [
    getForemanHomePath("actions", `${actionType}.mjs`),
    getForemanHomePath("actions", `${actionType}.js`),
    getForemanHomePath("actions", `${actionType}.ts`),
  ];
}

export function actionCandidates(projectPath: string, actionType: string): string[] {
  return [...projectActionCandidates(projectPath, actionType), ...globalActionCandidates(actionType)];
}

export function findProjectActionPath(projectPath: string, actionType: string): string | undefined {
  return actionCandidates(projectPath, actionType).find((candidate) => existsSync(candidate));
}

async function importActionModule<Context, Result>(candidate: string): Promise<ExternalActionModule<Context, Result>> {
  if (!candidate.endsWith(".ts")) {
    return await import(`${pathToFileURL(candidate).href}?t=${Date.now()}`) as ExternalActionModule<Context, Result>;
  }
  const bundled = buildSync({
    entryPoints: [candidate],
    bundle: true,
    write: false,
    platform: "node",
    format: "esm",
    target: "node20",
    sourcemap: "inline",
  }).outputFiles[0]?.text;
  if (!bundled) throw new Error(`Action ${candidate} failed to compile`);
  const hash = createHash("sha256").update(candidate).update("\0").update(bundled).digest("hex").slice(0, 16);
  const compiledPath = join(tmpdir(), `foreman-action-${hash}.mjs`);
  await writeFile(compiledPath, bundled, "utf8");
  return await import(`${pathToFileURL(compiledPath).href}?t=${Date.now()}`) as ExternalActionModule<Context, Result>;
}

export async function loadProjectAction<Context, Result = unknown>(projectPath: string, actionType: string): Promise<((ctx: Context) => Promise<Result> | Result) | undefined> {
  if (!isSafeActionName(actionType)) return undefined;
  for (const candidate of actionCandidates(projectPath, actionType)) {
    if (!existsSync(candidate)) continue;
    const mod = await importActionModule<Context, Result>(candidate);
    const runner = typeof mod.default === "function" ? mod.default : typeof mod.run === "function" ? mod.run : undefined;
    if (!runner) throw new Error(`Action ${actionType} at ${candidate} must export a default function or named run function`);
    return runner;
  }
  return undefined;
}

export function listBundledActionFiles(): string[] {
  try {
    return readdirSync(BUNDLED_ACTIONS_DIR).filter((file) => file.endsWith(".js") || file.endsWith(".mjs") || file.endsWith(".ts")).sort();
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

function stripJsNonCode(source: string): string {
  let output = "";
  let mode: "code" | "lineComment" | "blockComment" | "single" | "double" | "template" = "code";
  let escaped = false;
  for (let i = 0; i < source.length; i += 1) {
    const char = source[i] ?? "";
    const next = source[i + 1] ?? "";
    if (mode === "code") {
      if (char === "/" && next === "/") {
        mode = "lineComment";
        output += "  ";
        i += 1;
        continue;
      }
      if (char === "/" && next === "*") {
        mode = "blockComment";
        output += "  ";
        i += 1;
        continue;
      }
      if (char === "'") {
        mode = "single";
        escaped = false;
        output += " ";
        continue;
      }
      if (char === '"') {
        mode = "double";
        escaped = false;
        output += " ";
        continue;
      }
      if (char === "`") {
        mode = "template";
        escaped = false;
        output += " ";
        continue;
      }
      output += char;
      continue;
    }
    if (mode === "lineComment") {
      if (char === "\n") {
        mode = "code";
        output += "\n";
      } else {
        output += " ";
      }
      continue;
    }
    if (mode === "blockComment") {
      if (char === "*" && next === "/") {
        mode = "code";
        output += "  ";
        i += 1;
      } else {
        output += char === "\n" ? "\n" : " ";
      }
      continue;
    }
    const quote = mode === "single" ? "'" : mode === "double" ? '"' : "`";
    if (!escaped && char === quote) {
      mode = "code";
      output += " ";
      continue;
    }
    escaped = !escaped && char === "\\";
    if (char !== "\\") escaped = false;
    output += char === "\n" ? "\n" : " ";
  }
  return output;
}

function hasValidActionSyntax(filePath: string): boolean {
  try {
    buildSync({
      entryPoints: [filePath],
      bundle: true,
      write: false,
      platform: "node",
      format: "esm",
      target: "node20",
      logLevel: "silent",
    });
    return true;
  } catch {
    return false;
  }
}

function hasValidActionExport(source: string): boolean {
  if (/export\s+default\s+(async\s+)?function\b/.test(source)) return true;
  if (/export\s+default\s+(async\s+)?(\([^)]*\)|[a-zA-Z_$][\w$]*)\s*=>/.test(source)) return true;
  if (/export\s+(async\s+)?function\s+run\b/.test(source)) return true;
  if (/export\s+(const|let|var)\s+run\s*(?::[^=]+)?=\s*(async\s*)?(function\b|\([^)]*\)\s*=>|[a-zA-Z_$][\w$]*\s*=>)/.test(source)) return true;
  if (/((async\s+)?function\s+run\b|(const|let|var)\s+run\s*(?::[^=]+)?=\s*(async\s*)?(function\b|\([^)]*\)\s*=>|[a-zA-Z_$][\w$]*\s*=>))[\s\S]*export\s*\{[^}]*\brun\b[^}]*\}/.test(source)) return true;
  const callableNames = new Set<string>();
  for (const match of source.matchAll(/(?:async\s+)?function\s+([a-zA-Z_$][\w$]*)\b/g)) {
    callableNames.add(match[1] ?? "");
  }
  for (const match of source.matchAll(/(?:const|let|var)\s+([a-zA-Z_$][\w$]*)\s*(?::[^=]+)?=\s*(async\s*)?(?:function\b|\([^)]*\)\s*=>|[a-zA-Z_$][\w$]*\s*=>)/g)) {
    callableNames.add(match[1] ?? "");
  }
  for (const name of callableNames) {
    if (new RegExp(`export\\s+default\\s+${name}\\b`).test(source)) return true;
  }
  for (const exportBlock of source.matchAll(/export\s*\{([^}]*)\}/g)) {
    const exports = exportBlock[1] ?? "";
    if (callableNames.has("run") && /(^|,)\s*run\s*(,|$)/.test(exports)) return true;
    for (const name of callableNames) {
      if (new RegExp(`(^|,)\\s*${name}\\s+as\\s+(run|default)\\s*(,|$)`).test(exports)) return true;
    }
  }
  return false;
}

export function validateActionsInDir(dir: string): ActionValidationResult {
  const invalidNames: string[] = [];
  const invalidExports: string[] = [];
  const duplicateNames: string[] = [];
  let files: string[] = [];
  try {
    files = readdirSync(dir).filter((file) => file.endsWith(".js") || file.endsWith(".mjs") || file.endsWith(".ts")).sort();
  } catch {
    return { invalidNames, invalidExports, duplicateNames };
  }
  const actionCounts = new Map<string, number>();
  for (const file of files) {
    const actionName = file.replace(/\.(mjs|js|ts)$/i, "");
    actionCounts.set(actionName, (actionCounts.get(actionName) ?? 0) + 1);
  }
  for (const [actionName, count] of actionCounts.entries()) {
    if (count > 1) duplicateNames.push(actionName);
  }
  for (const file of files) {
    const actionName = file.replace(/\.(mjs|js|ts)$/i, "");
    if (!isSafeActionName(actionName)) {
      invalidNames.push(file);
      continue;
    }
    const filePath = join(dir, file);
    if (!hasValidActionSyntax(filePath)) {
      invalidExports.push(file);
      continue;
    }
    const source = stripJsNonCode(readFileSync(filePath, "utf8"));
    if (!hasValidActionExport(source)) invalidExports.push(file);
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
