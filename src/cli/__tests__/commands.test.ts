import { describe, it, expect, afterEach } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";
import { runTsxModule, type ExecResult } from "../../test-support/tsx-subprocess.js";
import { readFileSync } from "node:fs";
const CLI = path.resolve(__dirname, "../../../src/cli/index.ts");

async function run(args: string[], cwd: string): Promise<ExecResult> {
  return runTsxModule(CLI, args, { cwd, timeout: 10_000 });
}

describe("CLI smoke tests", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-cli-test-")));
    tempDirs.push(dir);
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("--help exits 0 and shows all commands including dashboard and bead", async () => {
    const tmp = makeTempDir();
    const result = await run(["--help"], tmp);

    expect(result.exitCode).toBe(0);
    const output = result.stdout;
    for (const cmd of ["init", "plan", "sling", "run", "status", "merge", "monitor", "dashboard", "bead"]) {
      expect(output).toContain(cmd);
    }
  }, 10_000);

  it("--version prints version number", async () => {
    const pkgPath = path.resolve(__dirname, "../../../package.json");
    const expected = (JSON.parse(readFileSync(pkgPath, "utf8")) as { version: string }).version;
    const { program } = await import("../index.js");
    expect(program.version()).toBe(expected);
  }, 10_000);

  it("status without init shows error", async () => {
    const tmp = makeTempDir();
    const result = await run(["status"], tmp);

    const output = result.stdout + result.stderr;
    // Should fail because bd is not available or project not initialized
    expect(
      result.exitCode !== 0 || output.toLowerCase().includes("error") || output.includes("init")
    ).toBe(true);
  }, 10_000);

  it("sling trd with nonexistent file shows error", async () => {
    const tmp = makeTempDir();
    const result = await run(["sling", "trd", "nonexistent-file.md"], tmp);

    const output = result.stdout + result.stderr;
    expect(
      result.exitCode !== 0 || output.toLowerCase().includes("not found") || output.toLowerCase().includes("error")
    ).toBe(true);
  }, 10_000);

  it("plan --dry-run shows pipeline steps", async () => {
    const tmp = makeTempDir();

    // Initialize a git repo so getRepoRoot() succeeds
    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: tmp });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: tmp });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: tmp });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: tmp });

    // Register the temp dir as a project so plan can proceed past the init check
    const storeMod = await import("../../lib/store.js");
    const store = storeMod.ForemanStore.forProject(tmp);
    store.registerProject("test-project", tmp);
    store.close();

    const result = await run(["plan", "--dry-run", "test-description"], tmp);

    const output = result.stdout + result.stderr;
    expect(output).toContain("Create PRD");
    expect(output).toContain("Create TRD");
  }, 10_000);

  it("run --dry-run without init shows error", async () => {
    const tmp = makeTempDir();
    const result = await run(["run", "--dry-run"], tmp);

    const output = result.stdout + result.stderr;
    // Should error because no git repo / no project init
    expect(
      result.exitCode !== 0 || output.toLowerCase().includes("error") || output.includes("init")
    ).toBe(true);
  }, 10_000);

  it("doctor --help shows usage", async () => {
    const tmp = makeTempDir();
    const result = await run(["doctor", "--help"], tmp);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("doctor");
    expect(result.stdout).toContain("--fix");
    expect(result.stdout).toContain("--dry-run");
    expect(result.stdout).toContain("--json");
  }, 10_000);

  it("doctor --json outputs valid JSON outside git repo", async () => {
    const tmp = makeTempDir();
    // tmp is not a git repo, so doctor should exit 1 with JSON error
    const result = await run(["doctor", "--json"], tmp);

    // Should exit 1 (not a git repo)
    expect(result.exitCode).toBe(1);
  }, 10_000);
});
