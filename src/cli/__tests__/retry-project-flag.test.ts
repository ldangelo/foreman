/**
 * Tests for --project flag on foreman retry command.
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

describe("foreman retry --project flag", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-retry-project-test-"));
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

  it("retry --project <registered-name> resolves project path correctly", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const registryDir = join(tmpBase, ".foreman");
    setupRegistryWithProject(registryDir, projectDir, "my-project");

    const result = await run(["retry", "bd-missing", "--project", "my-project", "--dry-run"], projectDir, {
      ...process.env,
      HOME: tmpBase,
    });

    const output = result.stdout + result.stderr;
    expect(output).not.toContain("not found. Run 'foreman project list'");
    expect(output).toContain("(dry run — no changes will be made)");
  });

  it("retry --project-path <relative-path> exits with an error", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    const result = await run(["retry", "bd-missing", "--project-path", "relative/path", "--dry-run"], projectDir, {
      ...process.env,
      HOME: tmpBase,
    });

    expect(result.exitCode).toBe(1);
    expect(result.stdout + result.stderr).not.toContain("not found in registry");
  });

  it("retry --project <unknown-name> exits with error", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "some-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const registryDir = join(tmpBase, ".foreman");
    mkdirSync(registryDir, { recursive: true });
    writeFileSync(join(registryDir, "projects.json"), JSON.stringify({ version: 1, projects: [] }, null, 2) + "\n");

    const result = await run(["retry", "bd-test", "--project", "nonexistent-project", "--dry-run"], projectDir, {
      ...process.env,
      HOME: tmpBase,
    });

    expect(result.exitCode).toBe(1);
    const output = result.stdout + result.stderr;
    expect(output).toContain("nonexistent-project");
    expect(output).toMatch(/not found/i);
    expect(output).toContain("foreman project list");
  });

  it("retry --project /absolute/path warns and operates directly", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "absolute-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const result = await run(["retry", "bd-test", "--project", projectDir, "--dry-run"], projectDir, {
      ...process.env,
      HOME: tmpBase,
    });

    expect(result.exitCode).toBe(1);
    expect(result.stdout + result.stderr).toContain(
      "`--project` with an absolute path is deprecated; use `--project-path` instead.",
    );
    expect(result.stdout + result.stderr).not.toContain("not found in registry");
  });

  it("retry (no --project) uses current directory", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const result = await run(["retry", "bd-test", "--dry-run"], projectDir);

    expect(result.exitCode).toBe(1);
    expect(result.stdout + result.stderr).not.toContain("not found in registry");
  });
});
