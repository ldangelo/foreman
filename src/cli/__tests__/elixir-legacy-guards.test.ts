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
    { args: ["run", "--dry-run"], message: "foreman run uses the legacy Node dispatcher" },
    { args: ["reset", "--dry-run"], message: "foreman reset mutates legacy run/task/merge-queue stores" },

    { args: ["merge", "--list"], message: "foreman merge uses the legacy Refinery and merge queue" },
    { args: ["pr"], message: "foreman pr uses the legacy Refinery PR path" },
    { args: ["run", "task", "foreman-12345", "task"], message: "foreman run task uses the legacy Node worker bridge directly" },
    { args: ["run", "task", "foreman-12345", "task", "--run-id", "run-123"], message: "foreman run task uses the legacy Node worker bridge directly" },
    { args: ["sentinel", "status"], message: "foreman sentinel uses the legacy SentinelAgent" },
    { args: ["worktree", "clean", "--dry-run"], message: "foreman worktree clean uses legacy run stores" },
    { args: ["purge", "logs", "--dry-run"], message: "foreman purge logs uses legacy run stores" },
    { args: ["purge", "runs", "--dry-run"], message: "foreman purge runs mutates legacy run stores" },
    { args: ["doctor"], message: "foreman doctor runs legacy Node/Postgres/daemon checks" },
    { args: ["daemon", "stop"], message: "FOREMAN_BACKEND=elixir; the Node daemon scheduler is disabled" },
    { args: ["daemon", "status"], message: "FOREMAN_BACKEND=elixir; the Node daemon scheduler is disabled" },
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
