/**
 * Tests for src/cli/commands/task.ts project resolution.
 *
 * The public `foreman task` surface is now bounded to transitional import helpers,
 * so resolution coverage exercises `task import --from-beads --dry-run`.
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

describe("foreman task import --project flag resolution", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-task-project-test-"));
    tempDirs.push(dir);
    return dir;
  }

  function mkProject(baseDir: string, name: string): string {
    const dir = join(baseDir, name);
    mkdirSync(join(dir, ".foreman"), { recursive: true });
    mkdirSync(join(dir, ".beads"), { recursive: true });
    writeFileSync(
      join(dir, ".beads", "issues.jsonl"),
      JSON.stringify({ id: "bd-demo", title: "Demo", issue_type: "task", status: "open" }) + "\n",
      "utf-8",
    );
    return dir;
  }

  function initRepo(projectDir: string): void {
    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });
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

  it("task import --project <registered-name> resolves to correct path", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");
    initRepo(projectDir);

    const registryDir = join(tmpBase, ".foreman");
    setupRegistryWithProject(registryDir, projectDir, "my-project");

    const env = { ...process.env, HOME: tmpBase };
    const result = await run(["task", "import", "--from-beads", "--dry-run", "--project", "my-project"], projectDir, env);

    const output = result.stdout + result.stderr;
    expect(result.exitCode).toBe(0);
    expect(output).not.toContain("not found");
    expect(output).toContain("Dry run: would import 1 task");
  });

  it("task import --project <unknown-name> exits with error", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "some-project");
    initRepo(projectDir);

    const registryDir = join(tmpBase, ".foreman");
    mkdirSync(registryDir, { recursive: true });
    writeFileSync(join(registryDir, "projects.json"), JSON.stringify({ version: 1, projects: [] }, null, 2) + "\n", "utf-8");

    const env = { ...process.env, HOME: tmpBase };
    const result = await run(["task", "import", "--from-beads", "--dry-run", "--project", "nonexistent-project"], projectDir, env);

    expect(result.exitCode).toBe(1);
    const output = result.stdout + result.stderr;
    expect(output).toContain("nonexistent-project");
    expect(output).toMatch(/not found/i);
    expect(output).toContain("foreman project list");
  });

  it("task import --project <absolute-path> warns and proceeds", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");
    const unregisteredPath = mkProject(tmpBase, "other-project");
    initRepo(projectDir);
    initRepo(unregisteredPath);

    const registryDir = join(tmpBase, ".foreman");
    mkdirSync(registryDir, { recursive: true });
    writeFileSync(join(registryDir, "projects.json"), JSON.stringify({ version: 1, projects: [] }, null, 2) + "\n", "utf-8");

    const env = { ...process.env, HOME: tmpBase };
    const result = await run(["task", "import", "--from-beads", "--dry-run", "--project", unregisteredPath], projectDir, env);

    const output = result.stdout + result.stderr;
    expect(result.exitCode).toBe(0);
    expect(output).toContain("--project");
    expect(output).toContain("--project-path");
    expect(output).toContain("Dry run: would import 1 task");
  });

  it("task import without --project uses current directory", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");
    initRepo(projectDir);

    const result = await run(["task", "import", "--from-beads", "--dry-run"], projectDir);

    expect(result.exitCode).toBe(0);
    const output = result.stdout + result.stderr;
    expect(output).toContain("Dry run: would import 1 task");
  });
});
