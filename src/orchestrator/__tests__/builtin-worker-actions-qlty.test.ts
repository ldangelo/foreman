import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { WorkerConfig } from "../agent-worker.js";
import { runQltyBuiltinPhase } from "../actions/builtin-worker-actions.js";

function makeConfig(worktreePath: string): WorkerConfig {
  return {
    runId: "run-qlty",
    projectId: "project-qlty",
    seedId: "seed-qlty",
    seedTitle: "Qlty action",
    model: "claude-sonnet-4-6",
    worktreePath,
    projectPath: worktreePath,
    prompt: "",
    env: {},
    taskMeta: { id: "seed-qlty", title: "Qlty action", description: "", type: "task", priority: 2, projectReportsDir: "." },
  };
}

describe("qlty builtin action", () => {
  const tempDirs: string[] = [];
  const originalPath = process.env.PATH;

  afterEach(() => {
    process.env.PATH = originalPath;
    for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  });

  function tempDir(prefix: string): string {
    const dir = mkdtempSync(join(tmpdir(), prefix));
    tempDirs.push(dir);
    return dir;
  }

  it("runs qlty check and writes QLTY_REPORT.md", async () => {
    const worktree = tempDir("foreman-qlty-worktree-");
    const bin = tempDir("foreman-qlty-bin-");
    const qlty = join(bin, "qlty");
    writeFileSync(qlty, "#!/bin/sh\necho qlty-ok:$*\n", "utf8");
    chmodSync(qlty, 0o755);
    process.env.PATH = `${bin}:${originalPath ?? ""}`;

    const result = await runQltyBuiltinPhase({
      config: makeConfig(worktree),
      phase: { name: "qlty", action: "qlty" },
      log: () => undefined,
    });

    expect(result.success).toBe(true);
    expect(result.outputText).toContain("qlty-ok:check");
    const report = join(worktree, "QLTY_REPORT.md");
    expect(existsSync(report)).toBe(true);
    expect(readFileSync(report, "utf8")).toContain("## Verdict: PASS");
  });

  it("fails clearly when qlty is unavailable", async () => {
    const worktree = tempDir("foreman-qlty-worktree-");
    const bin = tempDir("foreman-empty-bin-");
    process.env.PATH = bin;

    const result = await runQltyBuiltinPhase({
      config: makeConfig(worktree),
      phase: { name: "qlty", action: "qlty" },
      log: () => undefined,
    });

    expect(result.success).toBe(false);
    expect(result.error).toContain("qlty CLI not found");
    expect(readFileSync(join(worktree, "QLTY_REPORT.md"), "utf8")).toContain("## Verdict: FAIL");
  });
});
