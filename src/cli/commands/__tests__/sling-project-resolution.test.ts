import { describe, it, expect, afterEach } from "vitest";
import { execFileSync } from "node:child_process";
import { cpSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";
import { ForemanStore } from "../../../lib/store.js";
import { NativeTaskStore } from "../../../lib/task-store.js";
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

  it("resolves a registered project and creates native tasks there", async () => {
    const tmpBase = makeTempDir();
    const targetProject = mkProject(tmpBase, "registered-target");

    mkdirSync(join(tmpBase, ".foreman"), { recursive: true });
    writeFileSync(
      join(tmpBase, ".foreman", "projects.json"),
      JSON.stringify({
        version: 1,
        projects: [{
          name: "registered-target",
          path: targetProject,
          addedAt: new Date().toISOString(),
        }],
      }, null, 2) + "\n",
      "utf-8",
    );

    const result = await run(
      ["sling", "trd", "docs/TRD/sling-trd.md", "--project", "registered-target", "--auto"],
      tmpBase,
      { ...process.env, HOME: tmpBase },
    );

    expect(result.exitCode).toBe(0);

    const store = ForemanStore.forProject(targetProject);
    const taskStore = new NativeTaskStore(store.getDb());
    try {
      expect(taskStore.hasNativeTasks()).toBe(true);
      expect(taskStore.list().length).toBeGreaterThan(0);
    } finally {
      store.close();
    }
  });
});
