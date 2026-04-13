import { describe, it, expect, afterEach } from "vitest";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createTempProjectHarness } from "../../test-support/temp-project-harness.js";
import { runCommand } from "../../cli/commands/run.js";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const PHASE_RUNNER_MODULE = join(
  PROJECT_ROOT,
  "src",
  "test-support",
  "deterministic-phase-runner.ts",
);

async function invokeRun(args: string[]): Promise<void> {
  await runCommand.parseAsync(args, { from: "user" });
}

async function driveMergeQueueUntil(
  harness: { drainMergeQueue: () => Promise<void>; getRunStatuses: () => string[] },
  predicate: (statuses: string[]) => boolean,
  timeoutMs = 10_000,
): Promise<string[]> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    await harness.drainMergeQueue();
    const statuses = harness.getRunStatuses();
    if (predicate(statuses)) {
      return statuses;
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  return harness.getRunStatuses();
}

describe("full-run test runtime e2e", () => {
  const originalCwd = process.cwd();
  let tempHome: string | undefined;

  afterEach(() => {
    process.chdir(originalCwd);
    delete process.env.FOREMAN_RUNTIME_MODE;
    delete process.env.FOREMAN_TASK_STORE;
    delete process.env.FOREMAN_PHASE_RUNNER_MODULE;
    if (tempHome) {
      rmSync(tempHome, { recursive: true, force: true });
      tempHome = undefined;
    }
  });

  it("runs a detached native-task flow in test runtime without br installed", { timeout: 70_000 }, async () => {
    const harness = createTempProjectHarness();
    try {
      tempHome = mkdtempSync(join(tmpdir(), "foreman-no-br-home-"));
      mkdirSync(join(tempHome, ".foreman"), { recursive: true });
      process.env.HOME = tempHome;
      process.env.FOREMAN_RUNTIME_MODE = "test";
      process.env.FOREMAN_TASK_STORE = "native";
      process.env.FOREMAN_PHASE_RUNNER_MODULE = PHASE_RUNNER_MODULE;

      harness.seedTask({
        title: "Full run deterministic happy path",
        scenario: {
          kind: "create",
          file: "test.txt",
          content: "full-run path\n",
        },
      });

      process.chdir(harness.projectPath);
      await invokeRun(["--runtime-mode", "test", "--no-watch", "--max-agents", "1"]);
      await harness.waitForTerminalRuns(1, 20_000);
      const statuses = await driveMergeQueueUntil(
        harness,
        (values) => values.includes("merged"),
      );

      expect(statuses).toContain("merged");
      expect(harness.readRepoFile("test.txt")).toContain("full-run path");
    } finally {
      harness.cleanup();
    }
  });
});
