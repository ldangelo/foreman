import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path, { join } from "node:path";
import { runTsxModule, type ExecResult } from "../../test-support/tsx-subprocess.js";

const CLI = path.resolve(__dirname, "../../../src/cli/index.ts");

async function run(args: string[], cwd: string): Promise<ExecResult> {
  return runTsxModule(CLI, args, { cwd, timeout: 20_000 });
}

describe("native-task backend transition CLI regression targets", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-native-transition-")));
    tempDirs.push(dir);
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("top-level help exposes an import command for beads → native task migration", async () => {
    const tmp = makeTempDir();
    const result = await run(["--help"], tmp);

    expect(result.exitCode).toBe(0);
    expect(result.stdout + result.stderr).toContain("import");
  });

  it("import help exposes a dry-run migration surface", async () => {
    const tmp = makeTempDir();
    const result = await run(["import", "--help"], tmp);

    expect(result.exitCode).toBe(0);
    const output = result.stdout + result.stderr;
    expect(output).toContain("--dry-run");
    expect(output).toMatch(/external[_-]id|idempot/i);
  });

  it("sling dry-run advertises native task creation instead of sd/br tracker targets", async () => {
    const result = await run(
      ["sling", "trd", "docs/TRD/sling-trd.md", "--dry-run", "--auto"],
      process.cwd(),
    );

    expect(result.exitCode).toBe(0);
    const output = result.stdout + result.stderr;
    expect(output).toMatch(/native task/i);
    expect(output).not.toContain("sd (beads)");
    expect(output).not.toContain("br (beads_rust)");
    expect(output).toMatch(/migrat/i);
  });
});
