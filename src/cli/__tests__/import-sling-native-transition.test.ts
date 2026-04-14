import { describe, it, expect, afterEach } from "vitest";
import { execFile } from "node:child_process";
import { cpSync, existsSync, mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const CLI = path.resolve(__dirname, "../index.ts");
const SOURCE_TRD = resolve(process.cwd(), "docs/TRD/sling-trd.md");

async function run(args: string[], cwd: string): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  try {
    const { stdout, stderr } = await execFileAsync("npx", ["tsx", CLI, ...args], { cwd, timeout: 30_000 });
    return { stdout, stderr, exitCode: 0 };
  } catch (err: any) {
    return {
      stdout: err.stdout ?? "",
      stderr: err.stderr ?? "",
      exitCode: err.code ?? err.status ?? 1,
    };
  }
}

describe("sling native task transition", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-sling-native-transition-"));
    tempDirs.push(dir);
    return dir;
  }

  function mkProject(baseDir: string): string {
    const dir = join(baseDir, "native-target");
    mkdirSync(join(dir, "docs", "TRD"), { recursive: true });
    cpSync(SOURCE_TRD, join(dir, "docs", "TRD", "sling-trd.md"));
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("dry-run reports native preview messaging instead of legacy tracker targeting", async () => {
    const tmpBase = makeTempDir();
    const targetProject = mkProject(tmpBase);

    const result = await run(
      ["sling", "trd", "docs/TRD/sling-trd.md", "--project-path", targetProject, "--dry-run"],
      tmpBase,
    );

    const output = result.stdout + result.stderr;
    expect(result.exitCode).toBe(0);
    expect(output).toContain("Migration note: sling is migrating task creation to the native task store.");
    expect(output).toContain("Dry run — native task store preview only; no tasks created.");
    expect(output).toContain("native backlog tasks that require explicit approval before dispatch");
    expect(output).not.toContain("Create in sd (beads)");
    expect(output).not.toContain("Create in br (beads_rust)");
    expect(existsSync(join(targetProject, ".beads"))).toBe(false);
    expect(existsSync(join(targetProject, ".foreman", "foreman.db"))).toBe(false);
  });
});
