import { describe, it, expect, afterEach } from "vitest";
import { execFileSync } from "node:child_process";
import { cpSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";
import { runTsxModule, type ExecResult } from "../../../test-support/tsx-subprocess.js";

const CLI = path.resolve(__dirname, "../../index.ts");
const SOURCE_TRD = path.resolve(process.cwd(), "docs/TRD/sling-trd.md");

async function run(
  args: string[],
  cwd: string,
  extraEnv?: Record<string, string>,
): Promise<ExecResult> {
  return runTsxModule(CLI, args, { cwd, timeout: 30_000, env: extraEnv });
}

describe("foreman sling trd --project", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-sling-project-test-"));
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
    mkdirSync(join(baseDir, ".foreman", "projects"), { recursive: true });
    writeFileSync(
      join(baseDir, ".foreman", "projects", "projects.json"),
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

  it("resolves a registered project and reads the TRD from that project", async () => {
    const tmpBase = makeTempDir();
    const targetProject = mkProject(tmpBase, "registered-target");
    writeRegistry(tmpBase, "registered-target", targetProject);

    const result = await run(
      ["sling", "trd", "docs/TRD/sling-trd.md", "--project", "registered-target", "--json"],
      tmpBase,
      { ...process.env, HOME: tmpBase },
    );

    expect(result.exitCode).toBe(0);
    expect(result.stdout + result.stderr).toContain("registered-target/docs/TRD/sling-trd.md");
  });

  it("reads the TRD from an explicit --project-path target", async () => {
    const tmpBase = makeTempDir();
    const targetProject = mkProject(tmpBase, "explicit-target");

    const result = await run(
      ["sling", "trd", "docs/TRD/sling-trd.md", "--project-path", targetProject, "--json"],
      tmpBase,
      { ...process.env, HOME: tmpBase },
    );

    expect(result.exitCode).toBe(0);
    expect(result.stdout + result.stderr).toContain("explicit-target/docs/TRD/sling-trd.md");
  });

  it("rejects relative --project-path values", async () => {
    const tmpBase = makeTempDir();
    const targetProject = mkProject(tmpBase, "relative-target");
    writeRegistry(tmpBase, "relative-target", targetProject);

    const result = await run(
      ["sling", "trd", "docs/TRD/sling-trd.md", "--project-path", "relative-target", "--json"],
      tmpBase,
      { ...process.env, HOME: tmpBase },
    );

    expect(result.exitCode).toBe(1);
    expect(result.stdout + result.stderr).toContain("--project-path must be an absolute path");
  });

  it("warns but still accepts legacy absolute paths under --project", async () => {
    const tmpBase = makeTempDir();
    const targetProject = mkProject(tmpBase, "legacy-target");

    const result = await run(
      ["sling", "trd", "docs/TRD/sling-trd.md", "--project", targetProject, "--json"],
      tmpBase,
      { ...process.env, HOME: tmpBase },
    );

    expect(result.exitCode).toBe(0);
    expect(result.stdout + result.stderr).toContain("deprecated; use `--project-path` instead");
    expect(result.stdout + result.stderr).toContain("legacy-target/docs/TRD/sling-trd.md");
  });

  it("rejects combining --project with --project-path", async () => {
    const tmpBase = makeTempDir();
    const targetProject = mkProject(tmpBase, "combined-target");
    writeRegistry(tmpBase, "combined-target", targetProject);

    const result = await run(
      [
        "sling",
        "trd",
        "docs/TRD/sling-trd.md",
        "--project",
        "combined-target",
        "--project-path",
        targetProject,
        "--json",
      ],
      tmpBase,
      { ...process.env, HOME: tmpBase },
    );

    expect(result.exitCode).toBe(1);
    expect(result.stdout + result.stderr).toContain("--project and --project-path cannot be used together");
  });
});
