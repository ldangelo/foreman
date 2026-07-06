import { describe, it, expect, afterEach } from "vitest";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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

  function createGitFixture(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-phase-runner-"));
    execFileSync("git", ["init", "-b", "main"], { cwd: dir, stdio: "pipe" });
    execFileSync("git", ["config", "user.email", "foreman-test@example.com"], { cwd: dir, stdio: "pipe" });
    execFileSync("git", ["config", "user.name", "Foreman Test"], { cwd: dir, stdio: "pipe" });
    writeFileSync(join(dir, "README.md"), "# tmp\n", "utf-8");
    execFileSync("git", ["add", "-A"], { cwd: dir, stdio: "pipe" });
    execFileSync("git", ["commit", "-m", "Initial"], { cwd: dir, stdio: "pipe" });
    return dir;
  }

  function configureTestRunner() {
    process.env.FOREMAN_RUNTIME_MODE = "test";
    process.env.FOREMAN_PHASE_RUNNER_MODULE = join(
      process.cwd(),
      "src/test-support/deterministic-phase-runner.ts",
    );
  }

  it("uses the configured deterministic runner in test runtime", async () => {
    tmpDir = createGitFixture();
    configureTestRunner();

    const result = await runPhaseSession({
      prompt: "deterministic prompt",
      systemPrompt: "system",
      cwd: tmpDir,
      model: "test/model",
      logFile: join(tmpDir, "phase.log"),
      context: {
        phaseName: "developer",
        taskId: "task-1",
        taskTitle: "Task 1",
        taskType: "smoke",
        taskDescription:
          'FOREMAN_TEST_SCENARIO={"kind":"create","file":"test.txt","content":"hello from deterministic runner\\n"}',
        worktreePath: tmpDir,
      },
    });

    expect(result.success).toBe(true);
    expect(readFileSync(join(tmpDir, "DEVELOPER_REPORT.md"), "utf-8")).toContain("## Verdict: PASS");
    expect(readFileSync(join(tmpDir, "test.txt"), "utf-8")).toContain("hello from deterministic runner");
  });

  it("writes command phase artifacts to quoted report paths", async () => {
    tmpDir = createGitFixture();
    configureTestRunner();
    const reportsDir = join(tmpDir, "reports");
    mkdirSync(reportsDir, { recursive: true });

    const result = await runPhaseSession({
      prompt: `mkdir -p "${reportsDir}" && /skill:ensemble-implement-trd && mv IMPLEMENT_REPORT.md "${reportsDir}/IMPLEMENT_REPORT.md" 2>/dev/null || true`,
      systemPrompt: "system",
      cwd: tmpDir,
      model: "test/model",
      logFile: join(tmpDir, "phase.log"),
      context: {
        phaseName: "implement",
        taskId: "task-1",
        taskTitle: "Task 1",
        taskType: "epic",
        taskDescription:
          'FOREMAN_TEST_SCENARIO={"kind":"create","file":"test.txt","content":"hello from command runner\\n"}',
        worktreePath: tmpDir,
      },
    });

    expect(result.success).toBe(true);
    expect(readFileSync(join(reportsDir, "IMPLEMENT_REPORT.md"), "utf-8")).toContain("## Verdict: PASS");
  });
});
