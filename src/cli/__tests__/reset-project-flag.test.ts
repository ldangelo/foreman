/**
 * Tests for --project flag on foreman reset command.
 */

import { describe, it, expect, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import type { ExecResult } from "../../test-support/tsx-subprocess.js";
import { ForemanStore } from "../../lib/store.js";
import { resolveProjectTarget } from "../../lib/project-targeting.js";
import { ProjectNotFoundError } from "../../lib/project-registry.js";

const CLI = path.resolve(__dirname, "../../cli/index.ts");

async function run(
  args: string[],
  cwd: string,
  extraEnv?: Record<string, string>,
): Promise<ExecResult> {
  const result = spawnSync("npx", ["tsx", CLI, ...args], {
    cwd,
    timeout: 60_000,
    env: {
      ...process.env,
      TSX_DISABLE_IPC: "1",
      NO_COLOR: "1",
      ...extraEnv,
    },
    encoding: "utf8",
  });

  return {
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
    exitCode: result.status ?? 1,
  };
}

describe("foreman reset --project flag", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-reset-project-test-"));
    tempDirs.push(dir);
    return dir;
  }

  function mkProject(baseDir: string, name: string): string {
    const dir = join(baseDir, name);
    mkdirSync(join(dir, ".foreman"), { recursive: true });
    return dir;
  }

  function initGitRepo(dir: string): void {
    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: dir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: dir, stdio: "ignore" });
  }

  function registerLocalProject(projectDir: string, projectName: string): void {
    const store = ForemanStore.forProject(projectDir);
    store.registerProject(projectName, projectDir);
    store.close();
  }

  function setupRegistryWithProject(registryDir: string, projectPath: string, projectName: string): void {
    mkdirSync(registryDir, { recursive: true });
    writeFileSync(
      join(registryDir, "projects.json"),
      JSON.stringify([
        {
          id: "11111111-1111-4111-8111-111111111111",
          name: projectName,
          path: projectPath,
          githubUrl: "",
          repoKey: null,
          defaultBranch: "main",
          status: "active",
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
          lastSyncAt: null,
        },
      ], null, 2) + "\n",
      "utf-8",
    );
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("reset --project <registered-name> resolves project path correctly", async () => {
    const tmpBase = makeTempDir();
    const targetDir = mkProject(tmpBase, "target-project");
    const cwdDir = mkProject(tmpBase, "cwd-repo");

    initGitRepo(targetDir);
    initGitRepo(cwdDir);
    writeFileSync(join(targetDir, ".env"), "DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/foreman\n", "utf-8");

    const registryDir = join(tmpBase, ".foreman", "projects");
    setupRegistryWithProject(registryDir, targetDir, "my-project");

    const result = await run(["reset", "--project", "my-project"], cwdDir, {
      ...process.env,
      HOME: tmpBase,
    });

    expect(result.exitCode).toBe(0);
    expect(result.stdout + result.stderr).not.toContain("No project registered for this path");
  }, 60_000);

  it("reset --project <unknown-name> exits with error", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "some-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const registryDir = join(tmpBase, ".foreman", "projects");
    mkdirSync(registryDir, { recursive: true });
    writeFileSync(join(registryDir, "projects.json"), JSON.stringify({ version: 1, projects: [] }, null, 2) + "\n");

    const registry = {
      resolve: () => {
        throw new ProjectNotFoundError("nonexistent-project");
      },
    };

    expect(() =>
      resolveProjectTarget(
        { project: "nonexistent-project", cwd: projectDir },
        {
          registry,
          cwd: projectDir,
          isAccessible: () => true,
        },
      ),
    ).toThrow(/project list/i);
  });

  it("reset (no --project) uses current directory", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    initGitRepo(projectDir);
    registerLocalProject(projectDir, "my-project");

    const result = await run(["reset"], projectDir, { ...process.env, HOME: tmpBase });
    expect(result.exitCode).toBe(0);
    expect(result.stdout + result.stderr).not.toContain("No project registered for this path");
  });


  it("reset --project-path <absolute-path> resolves project path correctly", async () => {
    const tmpBase = makeTempDir();
    const targetDir = mkProject(tmpBase, "my-project");
    const cwdDir = mkProject(tmpBase, "cwd-repo");

    initGitRepo(targetDir);
    initGitRepo(cwdDir);
    writeFileSync(join(targetDir, ".env"), "DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/foreman\n", "utf-8");

    const registryDir = join(tmpBase, ".foreman", "projects");
    setupRegistryWithProject(registryDir, targetDir, "my-project");

    const result = await run(["reset", "--project-path", targetDir], cwdDir, {
      ...process.env,
      HOME: tmpBase,
    });

    const output = result.stdout + result.stderr;
    expect(result.exitCode).toBe(0);
    expect(output).not.toContain("`--project-path` must be an absolute path.");
    expect(output).not.toContain("No project registered for this path");
  }, 60_000);

  it("reset --project-path <relative-path> exits with error", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const result = await run(["reset", "--project-path", "relative/path"], projectDir, {
      ...process.env,
      HOME: tmpBase,
    });

    expect(result.exitCode).toBe(1);
    expect(result.stdout + result.stderr).toContain("`--project-path` must be an absolute path.");
  });

  it("reset --project <absolute-path> warns about deprecation", async () => {
    const tmpBase = makeTempDir();
    const projectDir = mkProject(tmpBase, "my-project");

    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: projectDir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: projectDir });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectDir });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: projectDir, stdio: "ignore" });

    const result = await run(["reset", "--project", projectDir], tmpBase, {
      ...process.env,
      HOME: tmpBase,
    });

    const output = result.stdout + result.stderr;
    expect(output).toContain("deprecated");
    expect(output).toContain("--project-path");
  });

});
