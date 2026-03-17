import { describe, it, expect, afterEach } from "vitest";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtempSync, rmSync, realpathSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";

const execFileAsync = promisify(execFile);

function findTsx(): string {
  const candidates = [
    path.resolve(__dirname, "../../../node_modules/.bin/tsx"),
    path.resolve(__dirname, "../../../../../node_modules/.bin/tsx"),
  ];
  for (const p of candidates) {
    if (existsSync(p)) return p;
  }
  return candidates[0];
}

const TSX = findTsx();
const CLI = path.resolve(__dirname, "../../../src/cli/index.ts");

interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

async function run(args: string[], cwd: string): Promise<ExecResult> {
  try {
    const { stdout, stderr } = await execFileAsync(TSX, [CLI, ...args], {
      cwd,
      timeout: 15_000,
      env: { ...process.env, NO_COLOR: "1" },
    });
    return { stdout, stderr, exitCode: 0 };
  } catch (err: any) {
    return {
      stdout: err.stdout ?? "",
      stderr: err.stderr ?? "",
      exitCode: err.code ?? 1,
    };
  }
}

describe("sentinel CLI smoke tests", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-sentinel-test-")));
    tempDirs.push(dir);
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("sentinel --help shows subcommands", async () => {
    const tmp = makeTempDir();
    const result = await run(["sentinel", "--help"], tmp);

    expect(result.exitCode).toBe(0);
    const output = result.stdout + result.stderr;
    expect(output).toContain("sentinel");
    expect(output).toContain("run-once");
    expect(output).toContain("start");
    expect(output).toContain("status");
  }, 15_000);

  it("sentinel run-once --help shows options", async () => {
    const tmp = makeTempDir();
    const result = await run(["sentinel", "run-once", "--help"], tmp);

    expect(result.exitCode).toBe(0);
    const output = result.stdout + result.stderr;
    expect(output).toContain("--branch");
    expect(output).toContain("--test-command");
    expect(output).toContain("--dry-run");
  }, 15_000);

  it("sentinel status without init shows error", async () => {
    const tmp = makeTempDir();
    const result = await run(["sentinel", "status"], tmp);

    const output = result.stdout + result.stderr;
    // Should fail (no git repo or no project init)
    expect(
      result.exitCode !== 0 ||
        output.toLowerCase().includes("error") ||
        output.includes("init"),
    ).toBe(true);
  }, 15_000);

  it("--help includes sentinel command", async () => {
    const tmp = makeTempDir();
    const result = await run(["--help"], tmp);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("sentinel");
  }, 15_000);
});
