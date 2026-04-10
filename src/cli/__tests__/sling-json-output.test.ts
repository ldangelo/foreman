import { describe, it, expect, afterEach } from "vitest";
import { execFileSync } from "node:child_process";
import { cpSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";
import { runTsxModule, type ExecResult } from "../../test-support/tsx-subprocess.js";

const CLI = path.resolve(__dirname, "../index.ts");
const SOURCE_TRD = path.resolve(process.cwd(), "docs/TRD/sling-trd.md");

async function run(args: string[], cwd: string, extraEnv?: Record<string, string>): Promise<ExecResult> {
  return runTsxModule(CLI, args, { cwd, timeout: 30_000, env: extraEnv });
}

describe("foreman sling trd --json", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-sling-json-test-"));
    tempDirs.push(dir);
    return dir;
  }

  function mkProject(baseDir: string, name: string): string {
    const dir = join(baseDir, name);
    mkdirSync(join(dir, ".foreman"), { recursive: true });
    mkdirSync(join(dir, "docs", "TRD"), { recursive: true });
    cpSync(SOURCE_TRD, join(dir, "docs", "TRD", "sling-trd.md"));
    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: dir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: dir, stdio: "ignore" });
    return dir;
  }

  function writeRegistry(baseDir: string, projectName: string, projectPath: string): void {
    mkdirSync(join(baseDir, ".foreman"), { recursive: true });
    writeFileSync(
      join(baseDir, ".foreman", "projects.json"),
      JSON.stringify({
        version: 1,
        projects: [{
          name: projectName,
          path: projectPath,
          addedAt: new Date().toISOString(),
        }],
      }, null, 2) + "\n",
      "utf-8",
    );
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("emits pure JSON on stdout for successful --json output", async () => {
    const tmpBase = makeTempDir();
    const targetProject = mkProject(tmpBase, "registered-target");
    writeRegistry(tmpBase, "registered-target", targetProject);

    const result = await run(
      ["sling", "trd", "docs/TRD/sling-trd.md", "--project", "registered-target", "--json"],
      tmpBase,
      { ...process.env, HOME: tmpBase },
    );

    expect(result.exitCode).toBe(0);
    expect(() => JSON.parse(result.stdout)).not.toThrow();
    expect(result.stdout).not.toContain("Reading TRD:");
  });

  it("emits machine-readable JSON error when TRD file is missing", async () => {
    const tmpBase = makeTempDir();
    const targetProject = mkProject(tmpBase, "registered-target");
    writeRegistry(tmpBase, "registered-target", targetProject);

    const result = await run(
      ["sling", "trd", "docs/TRD/missing.md", "--project", "registered-target", "--json"],
      tmpBase,
      { ...process.env, HOME: tmpBase },
    );

    expect(result.exitCode).toBe(1);
    expect(JSON.parse(result.stderr)).toEqual({
      error: `SLING-001: TRD file not found: ${path.resolve(targetProject, "docs/TRD/missing.md")}`,
    });
  });

  it("emits machine-readable JSON error for invalid --project-path", async () => {
    const tmpBase = makeTempDir();
    const targetProject = mkProject(tmpBase, "relative-target");
    writeRegistry(tmpBase, "relative-target", targetProject);

    const result = await run(
      ["sling", "trd", "docs/TRD/sling-trd.md", "--project-path", "relative-target", "--json"],
      tmpBase,
      { ...process.env, HOME: tmpBase },
    );

    expect(result.exitCode).toBe(1);
    expect(JSON.parse(result.stderr)).toEqual({
      error: "SLING-007: --project-path must be an absolute path.",
    });
  });
});
