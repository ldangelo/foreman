import { execFile, execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const require = createRequire(import.meta.url);
const TSX_LOADER = require.resolve("tsx");

export interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

function toExecResultError(err: unknown): ExecResult {
  if (typeof err === "object" && err !== null) {
    const execErr = err as {
      stdout?: string;
      stderr?: string;
      code?: number | string;
      status?: number;
    };
    return {
      stdout: execErr.stdout ?? "",
      stderr: execErr.stderr ?? "",
      exitCode: typeof execErr.code === "number"
        ? execErr.code
        : execErr.status ?? 1,
    };
  }

  return { stdout: "", stderr: "", exitCode: 1 };
}

function buildEnv(extraEnv?: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  return {
    ...process.env,
    TSX_DISABLE_IPC: "1",
    NO_COLOR: "1",
    ...extraEnv,
  };
}

export async function runTsxModule(
  modulePath: string,
  args: string[],
  opts: {
    cwd: string;
    timeout?: number;
    env?: NodeJS.ProcessEnv;
  },
): Promise<ExecResult> {
  try {
    const { stdout, stderr } = await execFileAsync(
      process.execPath,
      ["--import", TSX_LOADER, modulePath, ...args],
      {
        cwd: opts.cwd,
        timeout: opts.timeout,
        env: buildEnv(opts.env),
      },
    );
    return { stdout, stderr, exitCode: 0 };
  } catch (err: unknown) {
    const error = err as { stdout?: string; stderr?: string; code?: number; status?: number };
    return {
      stdout: error.stdout ?? "",
      stderr: error.stderr ?? "",
      exitCode: error.code ?? error.status ?? 1,
    };
  }
}

export function execTsxModuleSync(
  modulePath: string,
  args: string[],
  opts?: {
    cwd?: string;
    timeout?: number;
    encoding?: BufferEncoding;
    env?: NodeJS.ProcessEnv;
  },
): string {
  return execFileSync(
    process.execPath,
    ["--import", TSX_LOADER, modulePath, ...args],
    {
      cwd: opts?.cwd,
      timeout: opts?.timeout,
      encoding: opts?.encoding ?? "utf-8",
      env: buildEnv(opts?.env),
    },
  );
}
