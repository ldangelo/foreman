import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import type { Run } from "../../lib/store.js";
import { ForemanStore } from "../../lib/store.js";
import { NativeTaskStore, type TaskRow } from "../../lib/task-store.js";
import { MergeQueue, type MergeQueueEntry } from "../merge-queue.js";
import { Refinery } from "../refinery.js";

function git(cwd: string, args: string[]): string {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf-8",
    env: { ...process.env, GIT_EDITOR: "true" },
  }).trim();
}

function readRepoFile(repoDir: string, file: string): string {
  return readFileSync(join(repoDir, file), "utf-8");
}

interface ScenarioHarness {
  repoDir: string;
  store: ForemanStore;
  taskStore: NativeTaskStore;
  mergeQueue: MergeQueue;
  refinery: Refinery;
  projectId: string;
}

interface BranchRun {
  run: Run;
  task: TaskRow;
  entry: MergeQueueEntry;
}

describe("deterministic smoke e2e merge scenarios", () => {
  let harness: ScenarioHarness;

  beforeEach(() => {
    const repoDir = mkdtempSync(join(tmpdir(), "foreman-smoke-e2e-"));
    mkdirSync(join(repoDir, ".foreman"), { recursive: true });

    git(repoDir, ["init", "--initial-branch", "main"]);
    git(repoDir, ["config", "user.name", "Foreman Test"]);
    git(repoDir, ["config", "user.email", "foreman@example.com"]);

    writeFileSync(join(repoDir, "README.md"), "# smoke e2e\n");
    git(repoDir, ["add", "README.md"]);
    git(repoDir, ["commit", "-m", "init"]);

    const store = ForemanStore.forProject(repoDir);
    const project = store.registerProject("smoke-e2e", repoDir);
    const taskStore = new NativeTaskStore(store.getDb());
    const mergeQueue = new MergeQueue(store.getDb());
    const refinery = new Refinery(
      store,
      {
        async show(id: string) {
          return {
            title: `Smoke ${id}`,
            description: `Smoke scenario for ${id}`,
            status: "open",
            labels: [],
          };
        },
        async getGraph() {
          return { nodes: [], edges: [] };
        },
        async update() {
          return undefined;
        },
      },
      repoDir,
    );

    harness = {
      repoDir,
      store,
      taskStore,
      mergeQueue,
      refinery,
      projectId: project.id,
    };
  });

  afterEach(() => {
    harness.store.close();
    rmSync(harness.repoDir, { recursive: true, force: true });
  });

  function createTask(title: string, status: "ready" | "blocked" = "ready"): TaskRow {
    const task = harness.taskStore.create({ title });
    if (status === "ready") {
      harness.taskStore.approve(task.id);
    } else {
      harness.store.getDb().prepare("UPDATE tasks SET status = 'blocked' WHERE id = ?").run(task.id);
    }
    return harness.taskStore.get(task.id)!;
  }

  function enqueueCompletedBranch(opts: {
    seedId: string;
    task: TaskRow;
    commitMessage: string;
    filesModified?: string[];
    mutate: () => void;
  }): BranchRun {
    const { seedId, task, commitMessage, filesModified = ["test.txt"], mutate } = opts;
    const run = harness.store.createRun(harness.projectId, seedId, "claude-code");
    const branchName = `foreman/${seedId}`;

    harness.taskStore.claim(task.id, run.id);
    git(harness.repoDir, ["checkout", "-b", branchName, "main"]);
    mutate();
    git(harness.repoDir, ["add", "-A"]);
    git(harness.repoDir, ["commit", "-m", commitMessage]);
    git(harness.repoDir, ["checkout", "main"]);

    const completedAt = new Date().toISOString();
    harness.store.updateRun(run.id, {
      status: "completed",
      started_at: completedAt,
      completed_at: completedAt,
    });

    const entry = harness.mergeQueue.enqueue({
      branchName,
      seedId,
      runId: run.id,
      filesModified,
    });

    return {
      run: harness.store.getRun(run.id)!,
      task: harness.taskStore.get(task.id)!,
      entry,
    };
  }

  async function processNextEntry(): Promise<{
    entry: MergeQueueEntry;
    run: Run;
    report: Awaited<ReturnType<Refinery["mergeCompleted"]>>;
  }> {
    const entry = harness.mergeQueue.dequeue();
    expect(entry).not.toBeNull();
    const queueEntry = entry!;
    const report = await harness.refinery.mergeCompleted({
      seedId: queueEntry.seed_id,
      targetBranch: "main",
      runTests: false,
    });

    if (report.merged.length > 0) {
      harness.mergeQueue.updateStatus(queueEntry.id, "merged", {
        completedAt: new Date().toISOString(),
      });
    } else if (report.conflicts.length > 0 || report.prsCreated.length > 0) {
      harness.mergeQueue.updateStatus(queueEntry.id, "conflict", { error: "Code conflicts" });
    } else if (report.testFailures.length > 0 || report.unexpectedErrors.length > 0) {
      harness.mergeQueue.updateStatus(queueEntry.id, "failed", { error: "Merge failed" });
    } else {
      harness.mergeQueue.updateStatus(queueEntry.id, "failed", { error: "No completed run found" });
    }

    return {
      entry: queueEntry,
      run: harness.store.getRun(queueEntry.run_id)!,
      report,
    };
  }

  it("merges a single-write smoke branch and records test.txt in the queue", async () => {
    const singleTask = createTask("single write smoke task");
    const singleRun = enqueueCompletedBranch({
      seedId: "smoke-single",
      task: singleTask,
      commitMessage: "single write smoke",
      mutate: () => {
        writeFileSync(join(harness.repoDir, "test.txt"), "single write\n");
      },
    });

    expect(singleRun.entry.files_modified).toContain("test.txt");

    const processed = await processNextEntry();
    expect(processed.report.merged).toHaveLength(1);
    expect(processed.run.status).toBe("merged");
    expect(harness.mergeQueue.list("merged")).toHaveLength(1);
    expect(readRepoFile(harness.repoDir, "test.txt")).toBe("single write\n");
    expect(harness.taskStore.get(singleTask.id)?.status).toBe("merged");
  });

  it("unblocks a dependent append task after the create branch merges and preserves file order", async () => {
    const createTaskRow = createTask("create test.txt");
    const appendTaskRow = createTask("append test.txt", "blocked");
    harness.taskStore.addDependency(appendTaskRow.id, createTaskRow.id, "blocks");

    const readyBefore = await harness.taskStore.ready();
    expect(readyBefore.map((task) => task.id)).toContain(createTaskRow.id);
    expect(readyBefore.map((task) => task.id)).not.toContain(appendTaskRow.id);

    enqueueCompletedBranch({
      seedId: "smoke-create",
      task: createTaskRow,
      commitMessage: "create smoke file",
      mutate: () => {
        writeFileSync(join(harness.repoDir, "test.txt"), "created by task A\n");
      },
    });

    const createResult = await processNextEntry();
    expect(createResult.report.merged).toHaveLength(1);
    expect(readRepoFile(harness.repoDir, "test.txt")).toBe("created by task A\n");

    harness.taskStore.reevaluateBlockedTasks();
    expect(harness.taskStore.get(appendTaskRow.id)?.status).toBe("ready");

    enqueueCompletedBranch({
      seedId: "smoke-append",
      task: appendTaskRow,
      commitMessage: "append smoke file",
      mutate: () => {
        writeFileSync(
          join(harness.repoDir, "test.txt"),
          `${readRepoFile(harness.repoDir, "test.txt")}appended by task B\n`,
        );
      },
    });

    const appendResult = await processNextEntry();
    expect(appendResult.report.merged).toHaveLength(1);
    expect(appendResult.run.status).toBe("merged");
    expect(readRepoFile(harness.repoDir, "test.txt")).toBe(
      "created by task A\nappended by task B\n",
    );
    expect(harness.mergeQueue.list("merged")).toHaveLength(2);
  });

  it("serializes parallel same-file writes into one merged winner and one conflict loser", async () => {
    const winnerTask = createTask("parallel winner");
    const loserTask = createTask("parallel loser");

    enqueueCompletedBranch({
      seedId: "smoke-parallel-a",
      task: winnerTask,
      commitMessage: "parallel winner",
      mutate: () => {
        writeFileSync(join(harness.repoDir, "test.txt"), "winner branch\n");
      },
    });

    enqueueCompletedBranch({
      seedId: "smoke-parallel-b",
      task: loserTask,
      commitMessage: "parallel loser",
      mutate: () => {
        writeFileSync(join(harness.repoDir, "test.txt"), "loser branch\n");
      },
    });

    const first = await processNextEntry();
    expect(first.report.merged).toHaveLength(1);
    expect(first.run.status).toBe("merged");
    expect(readRepoFile(harness.repoDir, "test.txt")).toBe("winner branch\n");

    const second = await processNextEntry();
    expect(second.report.conflicts.length + second.report.prsCreated.length).toBeGreaterThan(0);
    expect(second.run.status).toBe("conflict");
    expect(harness.mergeQueue.list("merged")).toHaveLength(1);
    expect(harness.mergeQueue.list("conflict")).toHaveLength(1);
    expect(readRepoFile(harness.repoDir, "test.txt")).toBe("winner branch\n");
  });
});
