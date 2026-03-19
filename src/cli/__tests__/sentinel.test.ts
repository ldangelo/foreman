import { describe, it, expect, afterEach } from "vitest";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtempSync, rmSync, realpathSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";

const execFileAsync = promisify(execFile);

function findTsx(): string {
  // Search up the directory tree for node_modules/.bin/tsx.
  // Worktrees at .foreman-worktrees/<id>/ have their own node_modules (3 levels
  // up from src/cli/__tests__).  Worktrees at .claude/worktrees/<id>/ share the
  // main project's node_modules which lives 6 levels up.  We check both depths
  // plus intermediate levels to cover all layouts.
  const candidates = [
    path.resolve(__dirname, "../../../node_modules/.bin/tsx"),
    path.resolve(__dirname, "../../../../node_modules/.bin/tsx"),
    path.resolve(__dirname, "../../../../../node_modules/.bin/tsx"),
    path.resolve(__dirname, "../../../../../../node_modules/.bin/tsx"),
    path.resolve(__dirname, "../../../../../../../node_modules/.bin/tsx"),
  ];
  for (const p of candidates) {
    if (existsSync(p)) return p;
  }
  // Fall back to candidates[0] when none of the candidates exist. This path
  // may itself not exist, but the resulting spawn error ("tsx not found") will
  // be more informative than a confusing "TSX is undefined" failure.  The
  // 5-candidate list already covers all known worktree layouts, so in practice
  // this branch should never be reached.
  return candidates[0];
}

const TSX = findTsx();
const CLI = path.resolve(__dirname, "../../../src/cli/index.ts");

/** Per-subprocess timeout (ms). Generous to reduce flakiness under load. */
const SUBPROCESS_TIMEOUT_MS = 25_000;

/** Per-test timeout (ms): allows up to 2 attempts × subprocess timeout + margin. */
const TEST_TIMEOUT_MS = 30_000;

interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

async function run(args: string[], cwd: string): Promise<ExecResult> {
  try {
    const { stdout, stderr } = await execFileAsync(TSX, [CLI, ...args], {
      cwd,
      timeout: SUBPROCESS_TIMEOUT_MS,
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

/**
 * Retry wrapper for `run()`.  Retries once on subprocess-level failures
 * (timeout, spawn errors) to reduce flakiness under system load.
 * Only retries when the result looks like an infrastructure failure (no
 * useful stdout/stderr), not when the CLI itself produced output.
 */
async function runWithRetry(
  args: string[],
  cwd: string,
  maxAttempts = 2,
): Promise<ExecResult> {
  let last: ExecResult | undefined;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    last = await run(args, cwd);
    // Consider the run successful, or a meaningful CLI failure, if there is
    // any stdout/stderr output — those are real results worth asserting on.
    const hasOutput = last.stdout.length > 0 || last.stderr.length > 0;
    if (last.exitCode === 0 || hasOutput) return last;
    // No output and non-zero exit → likely a spawn/timeout failure; retry.
  }
  return last!;
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
    const result = await runWithRetry(["sentinel", "--help"], tmp);

    expect(result.exitCode).toBe(0);
    const output = result.stdout + result.stderr;
    expect(output).toContain("sentinel");
    expect(output).toContain("run-once");
    expect(output).toContain("start");
    expect(output).toContain("status");
    expect(output).toContain("stop");
  }, TEST_TIMEOUT_MS);

  it("sentinel stop --help shows options", async () => {
    const tmp = makeTempDir();
    const result = await runWithRetry(["sentinel", "stop", "--help"], tmp);

    expect(result.exitCode).toBe(0);
    const output = result.stdout + result.stderr;
    expect(output).toContain("stop");
    expect(output).toContain("--force");
  }, TEST_TIMEOUT_MS);

  it("sentinel run-once --help shows options", async () => {
    const tmp = makeTempDir();
    const result = await runWithRetry(["sentinel", "run-once", "--help"], tmp);

    expect(result.exitCode).toBe(0);
    const output = result.stdout + result.stderr;
    expect(output).toContain("--branch");
    expect(output).toContain("--test-command");
    expect(output).toContain("--dry-run");
  }, TEST_TIMEOUT_MS);

  it("sentinel status without init shows error", async () => {
    const tmp = makeTempDir();
    const result = await runWithRetry(["sentinel", "status"], tmp);

    const output = result.stdout + result.stderr;
    // Should fail (no git repo or no project init)
    expect(
      result.exitCode !== 0 ||
        output.toLowerCase().includes("error") ||
        output.includes("init"),
    ).toBe(true);
  }, TEST_TIMEOUT_MS);

  it("--help includes sentinel command", async () => {
    const tmp = makeTempDir();
    const result = await runWithRetry(["--help"], tmp);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("sentinel");
  }, TEST_TIMEOUT_MS);
});
