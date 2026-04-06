import { execFile, execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, parse } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

function findNodeModuleUpwards(startDir: string): string | null {
  let current = startDir;
  while (true) {
    const candidate = join(current, "node_modules", "tsx", "dist", "loader.mjs");
    if (existsSync(candidate)) {
      return candidate;
    }
    const parent = dirname(current);
    if (parent === current || current === parse(current).root) {
      return null;
    }
    current = parent;
  }
}

function resolveTsxLoader(): string {
  const candidates = [
    findNodeModuleUpwards(__dirname),
    findNodeModuleUpwards(process.cwd()),
  ].filter((candidate): candidate is string => Boolean(candidate));

  try {
    const gitCommonDir = execFileSync(
      "git",
      ["rev-parse", "--path-format=absolute", "--git-common-dir"],
      { cwd: __dirname, encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"] },
    ).trim();
    if (gitCommonDir) {
      candidates.push(join(dirname(gitCommonDir), "node_modules", "tsx", "dist", "loader.mjs"));
    }
  } catch {
    // Not a git checkout or git unavailable — fall back to upward scans only.
  }

  for (const candidate of new Set(candidates)) {
    if (existsSync(candidate)) {
      return candidate;
    }
  }

  throw new Error(`Unable to locate tsx loader from ${__dirname}`);
}

const TSX_LOADER = resolveTsxLoader();

export interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
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
  } catch (err: any) {
    return {
      stdout: err.stdout ?? "",
      stderr: err.stderr ?? "",
      exitCode: err.code ?? err.status ?? 1,
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
