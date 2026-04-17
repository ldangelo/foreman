import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it } from "vitest";
import { ForemanStore } from "../../lib/store.js";
import { NativeTaskStore, isCompactTaskId } from "../../lib/task-store.js";
import { performBeadsImport } from "../commands/task.js";

function writeBeadsJsonl(projectPath: string, records: unknown[]): void {
  mkdirSync(join(projectPath, ".beads"), { recursive: true });
  writeFileSync(
    join(projectPath, ".beads", "issues.jsonl"),
    records.map((record) => JSON.stringify(record)).join("\n") + "\n",
    "utf8",
  );
}

describe("foreman task import --from-beads", () => {
  const tempDirs: string[] = [];

  function makeProject(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-task-import-"));
    tempDirs.push(dir);
    mkdirSync(join(dir, ".foreman"), { recursive: true });
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("imports beads statuses and dependencies into native tasks", async () => {
    const project = makeProject();
    writeBeadsJsonl(project, [
      {
        id: "bd-open",
        title: "Open bead",
        description: "Open description",
        status: "open",
        priority: 2,
        issue_type: "feature",
        created_at: "2026-04-01T00:00:00.000Z",
        updated_at: "2026-04-01T01:00:00.000Z",
      },
      {
        id: "bd-ready",
        title: "Ready bead",
        description: "Ready description",
        status: "in_progress",
        priority: 1,
        issue_type: "task",
        created_at: "2026-04-01T00:00:00.000Z",
        updated_at: "2026-04-01T02:00:00.000Z",
        dependencies: [
          { issue_id: "bd-ready", depends_on_id: "bd-open", type: "blocks" },
        ],
      },
      {
        id: "bd-closed",
        title: "Closed bead",
        description: "Closed description",
        status: "closed",
        priority: 0,
        issue_type: "bug",
        created_at: "2026-04-01T00:00:00.000Z",
        updated_at: "2026-04-01T03:00:00.000Z",
        closed_at: "2026-04-01T04:00:00.000Z",
        dependencies: [
          { issue_id: "bd-closed", depends_on_id: "bd-ready", type: "parent-child" },
        ],
      },
    ]);

    const result = performBeadsImport(project);
    expect(result.imported).toBe(3);
    expect(result.duplicateSkips).toBe(0);
    expect(result.unsupportedStatusSkips).toBe(0);

    const store = ForemanStore.forProject(project);
    store.registerProject("foreman", project);
    const taskStore = new NativeTaskStore(store.getDb(), { projectKey: "foreman" });
    const openTask = store.getTaskByExternalId("bd-open");
    const readyTask = store.getTaskByExternalId("bd-ready");
    const closedTask = store.getTaskByExternalId("bd-closed");

    expect(openTask && isCompactTaskId(openTask.id)).toBe(true);
    expect(readyTask && isCompactTaskId(readyTask.id)).toBe(true);
    expect(closedTask && isCompactTaskId(closedTask.id)).toBe(true);
    expect(openTask?.status).toBe("backlog");
    expect(readyTask?.status).toBe("ready");
    expect(readyTask?.approved_at).toBeTruthy();
    expect(closedTask?.status).toBe("merged");
    expect(closedTask?.closed_at).toBe("2026-04-01T04:00:00.000Z");
    expect(openTask?.type).toBe("feature");
    expect(closedTask?.type).toBe("bug");

    const readyDeps = taskStore.getDependencies(readyTask!.id, "outgoing");
    const closedDeps = taskStore.getDependencies(closedTask!.id, "outgoing");
    expect(readyDeps).toEqual([
      expect.objectContaining({
        from_task_id: readyTask!.id,
        to_task_id: openTask!.id,
        type: "blocks",
      }),
    ]);
    expect(closedDeps).toEqual([
      expect.objectContaining({
        from_task_id: closedTask!.id,
        to_task_id: readyTask!.id,
        type: "parent-child",
      }),
    ]);

    store.close();
  });

  it("supports dry-run without writing rows", async () => {
    const project = makeProject();
    writeBeadsJsonl(project, [
      {
        id: "bd-preview",
        title: "Preview bead",
        status: "open",
        priority: 3,
        issue_type: "docs",
      },
    ]);

    const result = performBeadsImport(project, { dryRun: true });
    expect(result.imported).toBe(1);
    expect(result.preview).toHaveLength(1);

    const store = ForemanStore.forProject(project);
    expect(store.hasNativeTasks()).toBe(false);
    store.close();
  });

  it("skips duplicate imports when external_id already exists", async () => {
    const project = makeProject();
    const store = ForemanStore.forProject(project);
    store.registerProject("foreman", project);
    const taskStore = new NativeTaskStore(store.getDb(), { projectKey: "foreman" });
    taskStore.create({
      title: "Existing bead",
      externalId: "bd-existing",
    });
    store.close();

    writeBeadsJsonl(project, [
      {
        id: "bd-existing",
        title: "Existing bead",
        status: "open",
        priority: 2,
        issue_type: "task",
      },
    ]);

    const result = performBeadsImport(project);
    expect(result.imported).toBe(0);
    expect(result.duplicateSkips).toBe(1);

    const verifyStore = ForemanStore.forProject(project);
    const count = verifyStore
      .getDb()
      .prepare("SELECT COUNT(*) as cnt FROM tasks WHERE external_id = 'bd-existing'")
      .get() as { cnt: number };
    expect(count.cnt).toBe(1);
    verifyStore.close();
  });
});
