import { describe, it, expect, afterEach } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";
import { ForemanStore } from "../../../lib/store.js";
import { runTsxModule, type ExecResult } from "../../../test-support/tsx-subprocess.js";

const CLI = path.resolve(__dirname, "../../index.ts");

async function run(
  args: string[],
  cwd: string,
  extraEnv?: Record<string, string>,
): Promise<ExecResult> {
  return runTsxModule(CLI, args, { cwd, timeout: 15_000, env: extraEnv });
}

describe("foreman plan --project", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-plan-project-test-"));
    tempDirs.push(dir);
    return dir;
  }

  function mkProject(baseDir: string, name: string): string {
    const dir = join(baseDir, name);
    mkdirSync(join(dir, ".foreman"), { recursive: true });
    mkdirSync(join(dir, "docs"), { recursive: true });
    execFileSync("git", ["init", "--initial-branch", "main"], { cwd: dir, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir, stdio: "ignore" });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: dir, stdio: "ignore" });
    execFileSync("git", ["commit", "--allow-empty", "-m", "init"], { cwd: dir, stdio: "ignore" });
    const store = ForemanStore.forProject(dir);
    try {
      store.registerProject(name, dir);
    } finally {
      store.close();
    }
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("runs dry-run lifecycle against a registered target project from another cwd", async () => {
    const tmpBase = makeTempDir();
    const targetProject = mkProject(tmpBase, "target-project");

    mkdirSync(join(tmpBase, ".foreman"), { recursive: true });
    writeFileSync(
      join(tmpBase, ".foreman", "projects.json"),
      JSON.stringify({
        version: 1,
        projects: [{
          name: "target-project",
          path: targetProject,
          addedAt: new Date().toISOString(),
        }],
      }, null, 2) + "\n",
      "utf-8",
    );

    const result = await run(
      ["plan", "--dry-run", "--project", "target-project", "test-description"],
      tmpBase,
      { ...process.env, HOME: tmpBase },
    );

    const output = result.stdout + result.stderr;
    expect(result.exitCode).toBe(0);
    expect(output).toContain("Create PRD");
    expect(output).toContain("Create TRD");
    expect(output).toContain(targetProject);
  });

  it("resolves --from-prd relative to the target project root", async () => {
    const tmpBase = makeTempDir();
    const targetProject = mkProject(tmpBase, "target-project");
    writeFileSync(join(targetProject, "docs", "PRD.md"), "# PRD\n\nExisting\n", "utf-8");

    mkdirSync(join(tmpBase, ".foreman"), { recursive: true });
    writeFileSync(
      join(tmpBase, ".foreman", "projects.json"),
      JSON.stringify({
        version: 1,
        projects: [{
          name: "target-project",
          path: targetProject,
          addedAt: new Date().toISOString(),
        }],
      }, null, 2) + "\n",
      "utf-8",
    );

    const result = await run(
      ["plan", "--dry-run", "--project", "target-project", "--from-prd", "docs/PRD.md", "unused"],
      tmpBase,
      { ...process.env, HOME: tmpBase },
    );

    const output = result.stdout + result.stderr;
    expect(result.exitCode).toBe(0);
    expect(output).toContain(`Using existing PRD: ${realpathSync(join(targetProject, "docs", "PRD.md"))}`);
  });
});
