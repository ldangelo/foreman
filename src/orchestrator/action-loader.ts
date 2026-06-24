import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { join } from "node:path";
export interface ExternalActionModule<Context, Result> {
  default?: (ctx: Context) => Promise<Result> | Result;
  run?: (ctx: Context) => Promise<Result> | Result;
}

export async function loadProjectAction<Context, Result = unknown>(projectPath: string, actionType: string): Promise<((ctx: Context) => Promise<Result> | Result) | undefined> {
  const safeName = actionType.replace(/[^a-zA-Z0-9._-]/g, "");
  if (!safeName || safeName !== actionType) return undefined;
  const candidates = [
    join(projectPath, ".foreman", "actions", `${safeName}.mjs`),
    join(projectPath, ".foreman", "actions", `${safeName}.js`),
  ];
  for (const candidate of candidates) {
    if (!existsSync(candidate)) continue;
    const mod = await import(`${pathToFileURL(candidate).href}?t=${Date.now()}`) as ExternalActionModule<Context, Result>;
    const runner = mod.default ?? mod.run;
    if (typeof runner !== "function") throw new Error(`Action ${actionType} at ${candidate} must export default(ctx) or run(ctx)`);
    return runner;
  }
  return undefined;
}
