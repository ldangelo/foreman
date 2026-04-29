/**
 * Tests for --project/--all on foreman status.
 */

import { describe, it, expect, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, readFileSync } from "node:fs";
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
  const registryBaseDir = extraEnv?.HOME ? join(extraEnv.HOME, ".foreman") : undefined;
  return runTsxModule(CLI, args, {
    cwd,
    timeout: 15_000,
    env: {
      PATH: process.env.PATH,
      HOME: extraEnv?.HOME,
      TMPDIR: process.env.TMPDIR,
      TMP: process.env.TMP,
      TEMP: process.env.TEMP,
      TSX_DISABLE_IPC: "1",
      NO_COLOR: "1",
      FOREMAN_HOME: undefined,
      FOREMAN_TASK_STORE: undefined,
      FOREMAN_TASK_BACKEND: undefined,
      DATABASE_URL: undefined,
      FOREMAN_REGISTRY_BASE_DIR: registryBaseDir,
    },
  });
}

describe("foreman status --project flag", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-status-project-test-"));
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

  it("status --project <registered-name> resolves to correct path", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const registryDir = join(tmpBase, ".foreman", "projects");
    setupRegistryWithProject(registryDir, projectDir, "my-project");

    const result = await run(["status", "--project", "my-project"], projectDir, {
      ...process.env,
      HOME: tmpBase,
    });

    const output = result.stdout + result.stderr;
    expect(output).not.toContain("not found");
    expect(output).toMatch(/Tasks|Project Status/);
  });

  it("status --project <unknown-name> exits with error", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "some-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const registryDir = join(tmpBase, ".foreman", "projects");
    mkdirSync(registryDir, { recursive: true });
    writeFileSync(join(registryDir, "projects.json"), JSON.stringify({ version: 1, projects: [] }, null, 2) + "\n");

    const result = await run(["status", "--project", "nonexistent-project"], projectDir, {
      ...process.env,
      HOME: tmpBase,
    });

    expect(result.exitCode).toBe(1);
    const output = result.stdout + result.stderr;
    expect(output).toContain("nonexistent-project");
    expect(output).toMatch(/not found/i);
    expect(output).toContain("foreman project list");
  });

  it("status (no --project) uses current directory", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    // Set up a local registry with only this project so isMultiProjectMode() returns false
    const registryDir = join(tmpBase, ".foreman", "projects");
    setupRegistryWithProject(registryDir, projectDir, "my-project");

    const result = await run(["status"], projectDir, {
      ...process.env,
      HOME: tmpBase,
    });
    const output = result.stdout + result.stderr;
    expect(result.exitCode).toBe(0);
    expect(output).toMatch(/Tasks|Project Status/);
  });

  it("status --all shows aggregated status across all registered projects", async () => {
    const tmpBase = makeTempDir();
    const projectDir1 = mkProject(tmpBase, "project-1");
    const projectDir2 = mkProject(tmpBase, "project-2");

    for (const dir of [projectDir1, projectDir2]) {
      execFileSync("git", ["init", "--initial-branch", "main"], { cwd: dir, stdio: "ignore" });
      execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
      execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
      execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: dir, stdio: "ignore" });
    }

    const registryDir = join(tmpBase, ".foreman", "projects");
    setupRegistryWithProject(registryDir, projectDir1, "project-1");
    const registryPath = join(registryDir, "projects.json");
    const registry = JSON.parse(readFileSync(registryPath, "utf-8")) as {
      version: number;
      projects: Array<{ name: string; path: string; addedAt: string }>;
    };
    registry.projects.push({
      name: "project-2",
      path: projectDir2,
      addedAt: new Date().toISOString(),
    });
    writeFileSync(registryPath, JSON.stringify(registry, null, 2) + "\n", "utf-8");

    const result = await run(["status", "--all"], tmpBase, {
      ...process.env,
      HOME: tmpBase,
    });

    expect(result.exitCode).toBe(0);
    const output = result.stdout + result.stderr;
    expect(output).toContain("All Projects");
    expect(output).toContain("project-1");
    expect(output).toContain("project-2");
  });

  it("status --all with no registered projects shows warning", async () => {
    const tmpBase = makeTempDir();
    const registryDir = join(tmpBase, ".foreman", "projects");
    mkdirSync(registryDir, { recursive: true });
    writeFileSync(join(registryDir, "projects.json"), JSON.stringify({ version: 1, projects: [] }, null, 2) + "\n");

    const result = await run(["status", "--all"], tmpBase, {
      ...process.env,
      HOME: tmpBase,
    });

    expect(result.exitCode).toBe(0);
    expect(result.stdout + result.stderr).toMatch(/No registered projects/i);
  });


  it("status --project-path <absolute-path> resolves project path correctly", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const result = await run(["status", "--project-path", projectDir], projectDir, {
      ...process.env,
      HOME: tmpBase,
    });

    const output = result.stdout + result.stderr;
    expect(output).not.toContain("`--project-path` must be an absolute path.");
    expect(output).not.toContain("not found. Run 'foreman project list'");
  });

  it("status --project-path <relative-path> exits with error", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const result = await run(["status", "--project-path", "relative/path"], projectDir, {
      ...process.env,
      HOME: tmpBase,
    });

    expect(result.exitCode).toBe(1);
    expect(result.stdout + result.stderr).toContain("`--project-path` must be an absolute path.");
  });

  it("status --project <absolute-path> warns about deprecation", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const result = await run(["status", "--project", projectDir], tmpBase, {
      ...process.env,
      HOME: tmpBase,
    });

    const output = result.stdout + result.stderr;
    expect(output).toContain("deprecated");
    expect(output).toContain("--project-path");
  });

});
