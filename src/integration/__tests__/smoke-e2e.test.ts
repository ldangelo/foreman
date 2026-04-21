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

async function waitForStatuses(
  getStatuses: () => string[],
  predicate: (statuses: string[]) => boolean,
  timeoutMs = 10_000,
): Promise<string[]> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const statuses = getStatuses();
    if (predicate(statuses)) {
      return statuses;
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  return getStatuses();
}

async function driveMergeQueueUntil(
  harness: { drainMergeQueue: () => Promise<void>; getRunStatuses: () => Promise<string[]> },
  predicate: (statuses: string[]) => boolean,
  timeoutMs = 60_000,
): Promise<string[]> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    await harness.drainMergeQueue();
    const statuses = await harness.getRunStatuses();
    if (predicate(statuses)) {
      return statuses;
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  return harness.getRunStatuses();
}

describe("deterministic smoke e2e", () => {
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

  it("merges a deterministic smoke task through the real run command", { timeout: 70_000 }, async () => {
    const harness = createTempProjectHarness();
    try {
      tempHome = mkdtempSync(join(tmpdir(), "foreman-test-home-"));
      mkdirSync(join(tempHome, ".foreman"), { recursive: true });
      process.env.HOME = tempHome;
      process.env.FOREMAN_RUNTIME_MODE = "test";
      process.env.FOREMAN_TASK_STORE = "native";
      process.env.FOREMAN_PHASE_RUNNER_MODULE = PHASE_RUNNER_MODULE;

      await harness.seedTask({
        title: "Smoke write test.txt",
        scenario: {
          kind: "create",
          file: "test.txt",
          content: "hello from smoke e2e\n",
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
      expect(harness.readRepoFile("test.txt")).toContain("hello from smoke e2e");
    } finally {
      harness.cleanup();
    }
  });

  it("surfaces a deterministic same-file conflict outcome", { timeout: 120_000 }, async () => {
    const harness = createTempProjectHarness();
    try {
      tempHome = mkdtempSync(join(tmpdir(), "foreman-test-home-"));
      mkdirSync(join(tempHome, ".foreman"), { recursive: true });
      process.env.HOME = tempHome;
      process.env.FOREMAN_RUNTIME_MODE = "test";
      process.env.FOREMAN_TASK_STORE = "native";
      process.env.FOREMAN_PHASE_RUNNER_MODULE = PHASE_RUNNER_MODULE;

      await harness.seedTask({
        title: "Conflict A",
        scenario: {
          kind: "replace",
          file: "test.txt",
          content: "conflict-a\n",
        },
      });
      await harness.seedTask({
        title: "Conflict B",
        scenario: {
          kind: "replace",
          file: "test.txt",
          content: "conflict-b\n",
        },
      });

      process.chdir(harness.projectPath);
      await invokeRun(["--runtime-mode", "test", "--no-watch", "--max-agents", "2"]);
      await harness.waitForRunCount(2, 20_000);
      const statuses = await driveMergeQueueUntil(
        harness,
        (values) => values.filter((status) => status === "merged").length === 1
          && values.some((status) => status === "failed" || status === "conflict" || status === "pr-created")
          && ["conflict-a\n", "conflict-b\n"].includes(harness.readRepoFile("test.txt")),
        90_000,
      );
      expect(statuses.filter((status) => status === "merged")).toHaveLength(1);
      expect(statuses.some((status) => status === "failed" || status === "conflict" || status === "pr-created")).toBe(true);
      expect(["conflict-a\n", "conflict-b\n"]).toContain(harness.readRepoFile("test.txt"));
    } finally {
      harness.cleanup();
    }
  });
});
