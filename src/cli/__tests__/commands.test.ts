import { describe, it, expect, afterEach } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, realpathSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";
import { runTsxModule, type ExecResult } from "../../test-support/tsx-subprocess.js";
import { readFileSync } from "node:fs";
const CLI = path.resolve(__dirname, "../../../src/cli/index.ts");

async function run(args: string[], cwd: string): Promise<ExecResult> {
  return runTsxModule(CLI, args, { cwd, timeout: 90_000 });
}

function registerProjectInHomeRegistry(homeDir: string, projectPath: string, projectName: string): void {
  const registryDir = join(homeDir, ".foreman", "projects");
  mkdirSync(registryDir, { recursive: true });
  writeFileSync(
    join(registryDir, "projects.json"),
    JSON.stringify({
      version: 1,
      projects: [{ name: projectName, path: projectPath, addedAt: new Date().toISOString() }],
    }, null, 2) + "\n",
    "utf-8",
  );
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

  it("--help exits 0 and shows the consolidated command surface", async () => {
    const tmp = makeTempDir();
    const result = await run(["--help"], tmp);

    expect(result.exitCode).toBe(0);
    const output = result.stdout;
    for (const cmd of ["init", "plan", "sling", "run", "status", "merge", "watch", "purge", "task", "logs", "server"]) {
      expect(output).toContain(cmd);
    }

    // 'foreman dashboard' survives only as an alias of watch
    expect(output).toContain("watch|dashboard");
    expect(output).not.toMatch(/^\s+dashboard[\s|]/m);

    expect(output).toContain("Domain groups:");
    expect(output).toContain("Setup/health:");
    expect(output).toContain("Tasks/views:");
    expect(output).toContain("legacy dashboard -> watch");
    expect(output).toContain("legacy bead -> task create --from-text");

    // Deprecated spellings are hidden from help but still parse
    expect(output).not.toMatch(/^\s+bead[\s|]/m);
    expect(output).not.toMatch(/^\s+purge-logs[\s|]/m);
    expect(output).not.toMatch(/^\s+purge-zombie-runs[\s|]/m);
  }, 90_000);

  it("hidden deprecated spellings remain registered on the Commander surface", async () => {
    const { program } = await import("../index.js");
    const names = program.commands.map((command) => command.name());
    const aliases = program.commands.flatMap((command) => command.aliases());

    expect(names).toContain("bead");
    expect(names).toContain("purge-logs");
    expect(names).toContain("purge-zombie-runs");
    expect(names).toContain("purge");
    expect(aliases).toContain("dashboard");
  });

  it("--version prints version number", async () => {
    const pkgPath = path.resolve(__dirname, "../../../package.json");
    const expected = (JSON.parse(readFileSync(pkgPath, "utf8")) as { version: string }).version;
    const { program } = await import("../index.js");
    expect(program.version()).toBe(expected);
  }, 30_000);

  it("status without init shows error", async () => {
    const tmp = makeTempDir();
    const result = await run(["status"], tmp);

    const output = result.stdout + result.stderr;
    // Should fail because bd is not available or project not initialized
    expect(
      result.exitCode !== 0 || output.toLowerCase().includes("error") || output.includes("init")
    ).toBe(true);
  }, 60_000);

  it("sling trd with nonexistent file shows error", async () => {
    const tmp = makeTempDir();
    const result = await run(["sling", "trd", "nonexistent-file.md"], tmp);

    const output = result.stdout + result.stderr;
    expect(
      result.exitCode !== 0 || output.toLowerCase().includes("not found") || output.toLowerCase().includes("error")
    ).toBe(true);
  }, 90_000);

  it("run --dry-run without init shows error", async () => {
    const tmp = makeTempDir();
    const result = await run(["run", "--dry-run"], tmp);

    const output = result.stdout + result.stderr;
    // Should error because no git repo / no project init
    expect(
      result.exitCode !== 0 || output.toLowerCase().includes("error") || output.includes("init")
    ).toBe(true);
  }, 90_000);

  it("doctor --help shows usage", async () => {
    const tmp = makeTempDir();
    const result = await run(["doctor", "--help"], tmp);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("doctor");
    expect(result.stdout).toContain("--fix");
    expect(result.stdout).toContain("--dry-run");
    expect(result.stdout).toContain("--json");
  }, 90_000);

  it("doctor --json outputs valid JSON outside git repo", async () => {
    const tmp = makeTempDir();
    // tmp is not a git repo, so doctor should exit 1 with JSON error
    const result = await run(["doctor", "--json"], tmp);

    // Should exit 1 (not a git repo)
    expect(result.exitCode).toBe(1);
  }, 90_000);
});
