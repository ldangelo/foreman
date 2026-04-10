import { describe, it, expect, afterEach } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";
import { runTsxModule, type ExecResult } from "../../test-support/tsx-subprocess.js";

const CLI = path.resolve(__dirname, "../index.ts");

async function run(args: string[], cwd: string, extraEnv?: Record<string, string>): Promise<ExecResult> {
  return runTsxModule(CLI, args, { cwd, timeout: 30_000, env: extraEnv });
}

describe("foreman status --json project targeting", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-status-targeting-test-"));
    tempDirs.push(dir);
    return dir;
  }

  function mkProject(baseDir: string, name: string): string {
    const dir = join(baseDir, name);
    mkdirSync(join(dir, ".foreman"), { recursive: true });
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

  it("emits machine-readable JSON for invalid relative --project-path", async () => {
    const tmpBase = makeTempDir();
    const targetProject = mkProject(tmpBase, "relative-target");
    writeRegistry(tmpBase, "relative-target", targetProject);

    const result = await run(
      ["status", "--json", "--project-path", "relative-target"],
      tmpBase,
      { ...process.env, HOME: tmpBase },
    );

    expect(result.exitCode).toBe(1);
    expect(JSON.parse(result.stderr)).toEqual({
      error: "`--project-path` must be an absolute path.",
    });
  });

  it("emits machine-readable JSON for conflicting project selectors", async () => {
    const tmpBase = makeTempDir();
    const targetProject = mkProject(tmpBase, "combined-target");
    writeRegistry(tmpBase, "combined-target", targetProject);

    const result = await run(
      ["status", "--json", "--project", "combined-target", "--project-path", targetProject],
      tmpBase,
      { ...process.env, HOME: tmpBase },
    );

    expect(result.exitCode).toBe(1);
    expect(JSON.parse(result.stderr)).toEqual({
      error: "Specify either `--project <name>` or `--project-path <absolute-path>`, not both.",
    });
  });
});
