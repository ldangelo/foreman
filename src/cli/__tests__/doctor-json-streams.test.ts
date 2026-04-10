import { describe, it, expect, afterEach } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";
import { runTsxModule, type ExecResult } from "../../test-support/tsx-subprocess.js";

const CLI = path.resolve(__dirname, "../index.ts");

async function run(args: string[], cwd: string): Promise<ExecResult> {
  return runTsxModule(CLI, args, { cwd, timeout: 20_000 });
}

describe("doctor --json stream contracts", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-doctor-json-streams-")));
    tempDirs.push(dir);
    return dir;
  }

  function makeGitRepo(dir: string): void {
    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: dir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
    writeFileSync(join(dir, "README.md"), "# test\n");
    execFileSync("git", ["add", "."], { cwd: dir });
    execFileSync("git", ["commit", "-m", "init"], { cwd: dir, stdio: "ignore" });
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("emits JSON errors on stderr outside a git repo", async () => {
    const tmp = makeTempDir();

    const result = await run(["doctor", "--json"], tmp);

    expect(result.exitCode).toBe(1);
    expect(result.stdout.trim()).toBe("");
    expect(JSON.parse(result.stderr)).toEqual({
      checks: [],
      summary: { pass: 0, warn: 0, fail: 1, fixed: 0, skip: 0 },
      error: "Not inside a git repository",
    });
  });

  it("keeps successful doctor JSON on stdout", async () => {
    const tmp = makeTempDir();
    makeGitRepo(tmp);

    const result = await run(["doctor", "--json"], tmp);

    expect(result.stdout.trim()).not.toBe("");
    expect(() => JSON.parse(result.stdout)).not.toThrow();
  });
});
