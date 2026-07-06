import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export interface GraphifyIndexResult {
  command: "extract" | "update";
  graphPath: string;
}

function graphifyEnv(): NodeJS.ProcessEnv {
  return {
    ...process.env,
    FOREMAN_SERVER_HTTP_ENABLED: "false",
    FOREMAN_SERVER_HTTP_PORT: "0",
  };
}

export async function ensureGraphifyIndex(projectPath: string): Promise<GraphifyIndexResult> {
  const graphPath = join(projectPath, "graphify-out", "graph.json");
  const hasGraph = existsSync(graphPath);
  const command = hasGraph ? "update" : "extract";
  const args = hasGraph
    ? ["update", projectPath, "--no-cluster"]
    : ["extract", projectPath, "--no-cluster", "--out", projectPath];

  try {
    await execFileAsync("graphify", args, {
      cwd: projectPath,
      timeout: 10 * 60_000,
      maxBuffer: 4 * 1024 * 1024,
      env: graphifyEnv(),
    });
  } catch (err: unknown) {
    const failure = err as { stdout?: string; stderr?: string; message?: string };
    const output = [failure.stdout, failure.stderr, failure.message].filter(Boolean).join("\n").trim();
    throw new Error(`Graphify ${command} failed: ${output || String(err)}`);
  }

  return { command, graphPath };
}

export async function runGraphifyQuery(projectPath: string, query: string, options?: { dfs?: boolean; budget?: number }): Promise<string> {
  const args = ["query", query];
  if (options?.dfs) args.push("--dfs");
  if (options?.budget) args.push("--budget", String(options.budget));

  const { stdout, stderr } = await execFileAsync("graphify", args, {
    cwd: projectPath,
    timeout: 2 * 60_000,
    maxBuffer: 2 * 1024 * 1024,
    env: graphifyEnv(),
  });
  return [stdout, stderr].filter(Boolean).join("\n").trim();
}

export async function runGraphifyExplain(projectPath: string, node: string): Promise<string> {
  const { stdout, stderr } = await execFileAsync("graphify", ["explain", node], {
    cwd: projectPath,
    timeout: 2 * 60_000,
    maxBuffer: 2 * 1024 * 1024,
    env: graphifyEnv(),
  });
  return [stdout, stderr].filter(Boolean).join("\n").trim();
}
