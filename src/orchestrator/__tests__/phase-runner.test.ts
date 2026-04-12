import { describe, it, expect, afterEach } from "vitest";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import { runPhaseSession } from "../phase-runner.js";

describe("phase-runner", () => {
  let tmpDir: string | undefined;

  afterEach(() => {
    if (tmpDir) {
      rmSync(tmpDir, { recursive: true, force: true });
      tmpDir = undefined;
    }
    delete process.env.FOREMAN_RUNTIME_MODE;
    delete process.env.FOREMAN_PHASE_RUNNER_MODULE;
    delete process.env.FOREMAN_PHASE_RUNNER_EXPORT;
  });

  it("uses the configured deterministic runner in test runtime", async () => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-phase-runner-"));
    execFileSync("git", ["init", "-b", "main"], { cwd: tmpDir, stdio: "pipe" });
    execFileSync("git", ["config", "user.email", "foreman-test@example.com"], { cwd: tmpDir, stdio: "pipe" });
    execFileSync("git", ["config", "user.name", "Foreman Test"], { cwd: tmpDir, stdio: "pipe" });
    writeFileSync(join(tmpDir, "README.md"), "# tmp\n", "utf-8");
    execFileSync("git", ["add", "-A"], { cwd: tmpDir, stdio: "pipe" });
    execFileSync("git", ["commit", "-m", "Initial"], { cwd: tmpDir, stdio: "pipe" });

    process.env.FOREMAN_RUNTIME_MODE = "test";
    process.env.FOREMAN_PHASE_RUNNER_MODULE = join(
      process.cwd(),
      "src/test-support/deterministic-phase-runner.ts",
    );

    const result = await runPhaseSession({
      prompt: "deterministic prompt",
      systemPrompt: "system",
      cwd: tmpDir,
      model: "test/model",
      logFile: join(tmpDir, "phase.log"),
      context: {
        phaseName: "developer",
        seedId: "task-1",
        seedTitle: "Task 1",
        seedType: "smoke",
        seedDescription:
          'FOREMAN_TEST_SCENARIO={"kind":"create","file":"test.txt","content":"hello from deterministic runner\\n"}',
        worktreePath: tmpDir,
      },
    });

    expect(result.success).toBe(true);
    expect(readFileSync(join(tmpDir, "DEVELOPER_REPORT.md"), "utf-8")).toContain("## Verdict: PASS");
    expect(readFileSync(join(tmpDir, "test.txt"), "utf-8")).toContain("hello from deterministic runner");
  });
});
