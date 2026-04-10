import { describe, it, expect, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { runTsxModule, type ExecResult } from "../../test-support/tsx-subprocess.js";

const CLI = path.resolve(__dirname, "../../cli/index.ts");

async function run(
  args: string[],
  cwd: string,
  extraEnv?: Record<string, string>,
): Promise<ExecResult> {
  return runTsxModule(CLI, args, { cwd, timeout: 15_000, env: extraEnv });
}

describe("foreman run control-plane mode", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-run-control-plane-test-"));
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

  function setupRegistry(registryDir: string, projects: Array<{ name: string; path: string }>): void {
    mkdirSync(registryDir, { recursive: true });
    writeFileSync(
      join(registryDir, "projects.json"),
      JSON.stringify({
        version: 1,
        projects: projects.map((project) => ({
          ...project,
          addedAt: new Date().toISOString(),
        })),
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

  it("run --help describes control-plane scheduling", async () => {
    const tmpBase = makeTempDir();
    const result = await run(["run", "--help"], tmpBase);

    expect(result.exitCode).toBe(0);
    const output = result.stdout + result.stderr;
    expect(output).toContain("Schedule ready work across registered projects from the control plane");
    expect(output).toContain("Scope scheduling/execution to one registered");
  });

  it("run --dry-run schedules across registered projects from any cwd", async () => {
    const tmpBase = makeTempDir();
    const projectDir1 = mkProject(tmpBase, "project-1");
    const projectDir2 = mkProject(tmpBase, "project-2");
    const outsideCwd = join(tmpBase, "outside");
    mkdirSync(outsideCwd, { recursive: true });

    setupRegistry(join(tmpBase, ".foreman"), [
      { name: "project-1", path: projectDir1 },
      { name: "project-2", path: projectDir2 },
    ]);

    const result = await run(["run", "--dry-run"], outsideCwd, {
      ...process.env,
      HOME: tmpBase,
    });

    expect(result.exitCode).toBe(0);
    const output = result.stdout + result.stderr;
    expect(output).toContain("Scheduling across 2 registered project(s)");
    expect(output).toContain("Project: project-1");
    expect(output).toContain("Project: project-2");
    expect(output).toContain("Control Plane Summary");
  });
});
