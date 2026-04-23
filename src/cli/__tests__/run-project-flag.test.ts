/**
 * Tests for --project flag on foreman run command.
 */

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

describe("foreman run --project flag", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-run-project-test-"));
    tempDirs.push(dir);
    return dir;
  }

  function mkProject(baseDir: string, name: string): string {
    const dir = join(baseDir, name);
    mkdirSync(join(dir, ".foreman"), { recursive: true });
    return dir;
  }

  function setupRegistryWithProject(registryDir: string, projectPath: string, projectName: string): void {
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

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("run --project <registered-name> resolves project path correctly", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const registryDir = join(tmpBase, ".foreman", "projects");
    setupRegistryWithProject(registryDir, projectDir, "my-project");

    const result = await run(["run", "--project", "my-project", "--dry-run"], projectDir, {
      ...process.env,
      HOME: tmpBase,
    });

    expect(result.stdout + result.stderr).not.toContain("not found in registry");
  });

  it("run --project <unknown-name> exits with error", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "some-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const registryDir = join(tmpBase, ".foreman", "projects");
    mkdirSync(registryDir, { recursive: true });
    writeFileSync(join(registryDir, "projects.json"), JSON.stringify({ version: 1, projects: [] }, null, 2) + "\n");

    const result = await run(["run", "--project", "nonexistent-project", "--dry-run"], projectDir, {
      ...process.env,
      HOME: tmpBase,
    });

    expect(result.exitCode).toBe(1);
    const output = result.stdout + result.stderr;
    expect(output).toContain("nonexistent-project");
    expect(output).toMatch(/not found/i);
    expect(output).toContain("foreman project list");
  });

  it("run --dry-run (no --project) uses current directory", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const result = await run(["run", "--dry-run"], projectDir);
    expect(result.stdout + result.stderr).not.toContain("not found in registry");
  });


  it("run --project-path <absolute-path> resolves project path correctly", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const result = await run(["run", "--project-path", projectDir, "--dry-run"], projectDir, {
      ...process.env,
      HOME: tmpBase,
    });

    const output = result.stdout + result.stderr;
    expect(output).not.toContain("`--project-path` must be an absolute path.");
    expect(output).not.toContain("not found. Run 'foreman project list'");
  });

  it("run --project-path <relative-path> exits with error", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const result = await run(["run", "--project-path", "relative/path", "--dry-run"], projectDir, {
      ...process.env,
      HOME: tmpBase,
    });

    expect(result.exitCode).toBe(1);
    expect(result.stdout + result.stderr).toContain("`--project-path` must be an absolute path.");
  });

  it("run --project <absolute-path> warns about deprecation", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const result = await run(["run", "--project", projectDir, "--dry-run"], tmpBase, {
      ...process.env,
      HOME: tmpBase,
    });

    const output = result.stdout + result.stderr;
    expect(output).toContain("deprecated");
    expect(output).toContain("--project-path");
  });

});
