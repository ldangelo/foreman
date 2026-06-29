import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { runTsxModule } from "../../test-support/tsx-subprocess.js";

const CLI = path.resolve(__dirname, "../index.ts");

describe("default Elixir legacy command guards", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-elixir-legacy-guards-"));
    tempDirs.push(dir);
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
    tempDirs.length = 0;
  });

  it.each([
    { args: ["merge"], message: "foreman merge uses the legacy Refinery and merge queue" },
    { args: ["doctor", "--fix"], message: "foreman doctor --fix/--clean-logs run legacy Node/Postgres maintenance" },
  ])("fails fast before project/VCS resolution for $args", async ({ args, message }) => {
    const result = await runTsxModule(CLI, args, {
      cwd: makeTempDir(),
      timeout: 30_000,
      env: { FOREMAN_BACKEND: undefined },
    });

    const output = result.stdout + result.stderr;
    expect(result.exitCode).toBe(1);
    expect(output).toContain(message);
    expect(output).not.toContain("Not in a git repository");
    expect(output).not.toContain("Failed to resolve project");
  });
});
