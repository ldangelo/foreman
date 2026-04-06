import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { ForemanStore } from "../../lib/store.js";
import { createTempProjectHarness, type TempProjectHarness } from "../../test-support/temp-project-harness.js";

const PHASE_RUNNER_MODULE = fileURLToPath(new URL("../../test-support/smoke-phase-runner.ts", import.meta.url));

async function waitFor<T>(fn: () => T | Promise<T>, predicate: (value: T) => boolean, timeoutMs = 20_000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  let lastValue = await fn();
  while (Date.now() < deadline) {
    if (predicate(lastValue)) return lastValue;
    await new Promise((resolve) => setTimeout(resolve, 200));
    lastValue = await fn();
  }
  return lastValue;
}

describe("foreman run test runtime happy path", () => {
  let harness: TempProjectHarness | null = null;
  let optionsPath: string;

  beforeEach(() => {
    harness = createTempProjectHarness({
      projectName: "full-run-smoke",
      initialFiles: {
        "README.md": "# full run smoke\n",
        ".foreman/config.json": JSON.stringify({
          vcs: { backend: "git" },
        }, null, 2),
        "package.json": JSON.stringify({
          name: "full-run-smoke",
          private: true,
          scripts: {
            test: "node -e \"process.exit(0)\"",
          },
        }, null, 2),
      },
    });
    optionsPath = join(mkdtempSync(join(tmpdir(), "foreman-phase-runner-options-")), "options.json");
    writeFileSync(optionsPath, JSON.stringify({
      developerFiles: [
        { path: "test.txt", content: "full run smoke output\n" },
      ],
    }, null, 2));
  });

  afterEach(() => {
    if (harness) {
      harness.cleanup();
      harness = null;
    }
    rmSync(join(optionsPath, ".."), { recursive: true, force: true });
  });

  it("runs the real detached foreman run path with test runtime and enqueues a smoke branch", async () => {
    const seeded = harness!.seedNativeTasks([
      {
        key: "smoke",
        title: "Full run smoke task",
        status: "ready",
        type: "smoke",
      },
    ]);

    const result = await harness!.runCli(["run", "--no-watch", "--max-agents", "1", "--runtime-mode", "test"], {
      timeout: 20_000,
      env: {
        PATH: process.env.PATH,
        FOREMAN_TASK_STORE: "native",
        FOREMAN_PHASE_RUNNER_MODULE: PHASE_RUNNER_MODULE,
        FOREMAN_PHASE_RUNNER_OPTIONS_PATH: optionsPath,
      },
    });

    expect(result.exitCode).toBe(0);
    expect(result.stdout + result.stderr).not.toMatch(/Error initialising task backend/i);

    const terminalRun = await waitFor(
      () => {
        const store = ForemanStore.forProject(harness!.projectRoot);
        try {
          return store.getRunsForSeed(seeded.byKey.smoke.id).at(0) ?? null;
        } finally {
          store.close();
        }
      },
      (run) => run !== null && ["merged", "completed"].includes(run.status),
    );

    expect(terminalRun).not.toBeNull();
    expect(terminalRun!.status).toBe("completed");
    expect(terminalRun!.worktree_path).toBeTruthy();

    const latestStore = ForemanStore.forProject(harness!.projectRoot);
    try {
      const queueRows = latestStore.getDb()
        .prepare("SELECT * FROM merge_queue WHERE seed_id = ? ORDER BY id DESC")
        .all(seeded.byKey.smoke.id) as Array<{ status: string; files_modified: string }>;
      expect(queueRows).toHaveLength(1);
      expect(["pending", "merging", "merged"]).toContain(queueRows[0].status);
      expect(JSON.parse(queueRows[0].files_modified)).toContain("test.txt");
    } finally {
      latestStore.close();
    }

    expect(readFileSync(join(terminalRun!.worktree_path!, "test.txt"), "utf-8")).toBe("full run smoke output\n");
  }, 30_000);
});
