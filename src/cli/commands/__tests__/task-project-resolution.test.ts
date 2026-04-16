/**
 * Tests for src/cli/commands/task.ts project resolution.
 *
 * Covers REQ-016 AC-016.1, AC-016.2:
 *   - AC-016.1: --project <registered-name> resolves via ProjectRegistry.resolve()
 *   - AC-016.2: --project <unknown-name> exits with error
 *   - No flag → returns process.cwd()
 *   - Absolute path under --project → warns and proceeds during compatibility window
 *
 * Uses runTsxModule to invoke the CLI and capture output/exit code.
 */

import { describe, it, expect, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { runTsxModule, type ExecResult } from "../../../test-support/tsx-subprocess.js";

const CLI = path.resolve(__dirname, "../../index.ts");

async function run(
  args: string[],
  cwd: string,
  extraEnv?: Record<string, string>,
): Promise<ExecResult> {
  return runTsxModule(CLI, args, { cwd, timeout: 10_000, env: extraEnv });
}

describe("foreman task --project flag resolution", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-task-project-test-"));
    tempDirs.push(dir);
    return dir;
  }

  /** Create a fake project directory with .foreman/ sub-dir */
  function mkProject(baseDir: string, name: string): string {
    const dir = join(baseDir, name);
    mkdirSync(join(dir, ".foreman"), { recursive: true });
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  // ── Helper: create a registry with one registered project ──────────────────

  function setupRegistryWithProject(registryDir: string, projectPath: string, projectName: string): void {
    mkdirSync(registryDir, { recursive: true });
    writeFileSync(
      join(registryDir, "projects.json"),
      JSON.stringify({
        version: 1,
        projects: [
          {
            name: projectName,
            path: projectPath,
            addedAt: new Date().toISOString(),
          },
        ],
      }, null, 2) + "\n",
      "utf-8",
    );
  }

  // ── AC-016.1: Registered name resolves via ProjectRegistry.resolve() ──────

  it("task list --project <registered-name> resolves to correct path", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    // Initialize git repo (required by ForemanStore)
    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    // Set HOME to our temp dir so ProjectRegistry uses our test registry
    const registryDir = join(tmpBase, ".foreman");
    setupRegistryWithProject(registryDir, projectDir, "my-project");

    const env = {
      ...process.env,
      HOME: tmpBase,
    };

    // The command should succeed (not exit with project-not-found error)
    const result = await run(["task", "list", "--project", "my-project"], projectDir, env);

    // Should NOT contain the "not found" error
    const output = result.stdout + result.stderr;
    expect(output).not.toContain("not found");
    // Should contain the task list output (or "No tasks" message)
    expect(output).toMatch(/Tasks|No tasks/);
  });

  // ── AC-016.2: Unknown name exits with error ─────────────────────────────────

  it("task list --project <unknown-name> exits with error", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "some-project");

    // Initialize git repo
    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    // Set HOME to temp dir with empty registry
    const registryDir = join(tmpBase, ".foreman");
    mkdirSync(registryDir, { recursive: true });
    writeFileSync(
      join(registryDir, "projects.json"),
      JSON.stringify({ version: 1, projects: [] }, null, 2) + "\n",
      "utf-8",
    );

    const env = {
      ...process.env,
      HOME: tmpBase,
    };

    // Unknown project name should cause exit with error message
    const result = await run(["task", "list", "--project", "nonexistent-project"], projectDir, env);

    expect(result.exitCode).toBe(1);
    const output = result.stdout + result.stderr;
    expect(output).toContain("nonexistent-project");
    expect(output).toMatch(/not found/i);
    expect(output).toContain("foreman project list");
  });

  // ── Absolute path not in registry: warn and proceed ─────────────────────────

  it("task list --project <absolute-path> warns and proceeds during the compatibility window", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    // Initialize git repo
    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    // Set HOME to temp dir with empty registry
    const registryDir = join(tmpBase, ".foreman");
    mkdirSync(registryDir, { recursive: true });
    writeFileSync(
      join(registryDir, "projects.json"),
      JSON.stringify({ version: 1, projects: [] }, null, 2) + "\n",
      "utf-8",
    );

    const env = {
      ...process.env,
      HOME: tmpBase,
    };

    // Use an absolute path that's not in the registry
    const unregisteredPath = join(tmpBase, "other-project");
    mkdirSync(unregisteredPath, { recursive: true });

    const result = await run(["task", "list", "--project", unregisteredPath], projectDir, env);

    // Should NOT exit with error (warns but proceeds)
    const output = result.stdout + result.stderr;
    expect(output).toContain("--project");
    expect(output).toContain("--project-path");
    // Should still output task list or "No tasks"
    expect(output).toMatch(/Tasks|No tasks/);
  });

  // ── No --project flag: uses current directory ────────────────────────────────

  it("task list (no --project) uses current directory", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    // Initialize git repo
    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    // Run from the project directory without --project flag
    const result = await run(["task", "list"], projectDir);

    // Should succeed (uses current directory)
    const output = result.stdout + result.stderr;
    expect(result.exitCode).toBe(0);
    expect(output).toMatch(/Tasks|No tasks/);
  });

  // ── Edge cases ──────────────────────────────────────────────────────────────

  it("task list --project '' (empty string) falls back to current directory", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    // Initialize git repo
    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    // Empty string project name should behave like no --project flag
    const result = await run(["task", "list", "--project", ""], projectDir);

    // Should succeed (falls back to current directory)
    const output = result.stdout + result.stderr;
    expect(result.exitCode).toBe(0);
    expect(output).toMatch(/Tasks|No tasks/);
  });

  it("task list --project <relative-path> exits with error (not a registered name)", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    // Initialize git repo
    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    // Set HOME to temp dir with empty registry
    const registryDir = join(tmpBase, ".foreman");
    mkdirSync(registryDir, { recursive: true });
    writeFileSync(
      join(registryDir, "projects.json"),
      JSON.stringify({ version: 1, projects: [] }, null, 2) + "\n",
      "utf-8",
    );

    const env = {
      ...process.env,
      HOME: tmpBase,
    };

    // Relative paths should be treated as unknown names → exit with error
    const result = await run(["task", "list", "--project", "../relative-path"], projectDir, env);

    expect(result.exitCode).toBe(1);
    const output = result.stdout + result.stderr;
    expect(output).toMatch(/not found/i);
    expect(output).toContain("foreman project list");
  });

  it("task list --project <absolute-path-string> (not a real path) exits with an accessibility error", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    // Initialize git repo
    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    // Set HOME to temp dir with empty registry
    const registryDir = join(tmpBase, ".foreman");
    mkdirSync(registryDir, { recursive: true });
    writeFileSync(
      join(registryDir, "projects.json"),
      JSON.stringify({ version: 1, projects: [] }, null, 2) + "\n",
      "utf-8",
    );

    const env = {
      ...process.env,
      HOME: tmpBase,
    };

    // An absolute path string that's not a real directory should fail fast.
    const fakeAbsolutePath = join(tmpBase, "definitely-missing-project");
    const result = await run(["task", "list", "--project", fakeAbsolutePath], projectDir, env);

    expect(result.exitCode).toBe(1);
    const output = result.stdout + result.stderr;
    expect(output).toContain("does not exist or is not accessible");
  });
});
