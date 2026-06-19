import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as projectTaskSupport from "../commands/project-task-support.js";
import * as trpcClientModule from "../../lib/trpc-client.js";
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

  beforeEach(() => {
    vi.restoreAllMocks();
  });

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
    vi.restoreAllMocks();
  });

  it("imports beads statuses and dependencies through the daemon task API", async () => {
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

    const create = vi.fn().mockResolvedValue(undefined);
    const addDependency = vi.fn().mockResolvedValue({ added: true });
    vi.spyOn(projectTaskSupport, "listRegisteredProjects").mockResolvedValue([
      { id: "proj-1", name: "foreman", path: project },
    ]);
    vi.spyOn(trpcClientModule, "createTrpcClient").mockReturnValue({
      tasks: {
        list: vi.fn().mockResolvedValue([]),
        create,
        addDependency,
      },
    } as unknown as trpcClientModule.TrpcClient);

    const result = await performBeadsImport(project);
    expect(result.imported).toBe(3);
    expect(result.duplicateSkips).toBe(0);
    expect(result.unsupportedStatusSkips).toBe(0);
    expect(create).toHaveBeenCalledTimes(3);
    expect(create).toHaveBeenCalledWith(expect.objectContaining({
      projectId: "proj-1",
      title: "Open bead",
      type: "feature",
      status: "backlog",
      externalId: "bd-open",
    }));
    expect(create).toHaveBeenCalledWith(expect.objectContaining({
      projectId: "proj-1",
      title: "Ready bead",
      type: "task",
      status: "ready",
      approvedAt: "2026-04-01T02:00:00.000Z",
      externalId: "bd-ready",
    }));
    expect(create).toHaveBeenCalledWith(expect.objectContaining({
      projectId: "proj-1",
      title: "Closed bead",
      type: "bug",
      status: "merged",
      closedAt: "2026-04-01T04:00:00.000Z",
      externalId: "bd-closed",
    }));
    expect(addDependency).toHaveBeenCalledTimes(2);
    expect(addDependency).toHaveBeenCalledWith({
      projectId: "proj-1",
      fromTaskId: expect.any(String),
      toTaskId: expect.any(String),
      type: "blocks",
    });
    expect(addDependency).toHaveBeenCalledWith({
      projectId: "proj-1",
      fromTaskId: expect.any(String),
      toTaskId: expect.any(String),
      type: "parent-child",
    });

    const dependencyCalls = addDependency.mock.calls;
    const createdByExternalId = new Map(
      create.mock.calls.map(([input]) => [input.externalId, input.id]),
    );
    expect(dependencyCalls).toContainEqual([
      {
        projectId: "proj-1",
        fromTaskId: createdByExternalId.get("bd-open"),
        toTaskId: createdByExternalId.get("bd-ready"),
        type: "blocks",
      },
    ]);
    expect(dependencyCalls).toContainEqual([
      {
        projectId: "proj-1",
        fromTaskId: createdByExternalId.get("bd-ready"),
        toTaskId: createdByExternalId.get("bd-closed"),
        type: "parent-child",
      },
    ]);
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

    const create = vi.fn().mockResolvedValue(undefined);
    vi.spyOn(projectTaskSupport, "listRegisteredProjects").mockResolvedValue([
      { id: "proj-1", name: "foreman", path: project },
    ]);
    vi.spyOn(trpcClientModule, "createTrpcClient").mockReturnValue({
      tasks: {
        list: vi.fn().mockResolvedValue([]),
        create,
        addDependency: vi.fn(),
      },
    } as unknown as trpcClientModule.TrpcClient);

    const result = await performBeadsImport(project, { dryRun: true });
    expect(result.imported).toBe(1);
    expect(result.preview).toHaveLength(1);
    expect(create).not.toHaveBeenCalled();
  });

  it("skips duplicate imports when external_id already exists", async () => {
    const project = makeProject();
    writeBeadsJsonl(project, [
      {
        id: "bd-existing",
        title: "Existing bead",
        status: "open",
        priority: 2,
        issue_type: "task",
      },
    ]);

    const create = vi.fn().mockResolvedValue(undefined);
    vi.spyOn(projectTaskSupport, "listRegisteredProjects").mockResolvedValue([
      { id: "proj-1", name: "foreman", path: project },
    ]);
    vi.spyOn(trpcClientModule, "createTrpcClient").mockReturnValue({
      tasks: {
        list: vi.fn().mockResolvedValue([
          {
            id: "foreman-aaaaa",
            title: "Existing bead",
            external_id: "bd-existing",
          },
        ]),
        create,
        addDependency: vi.fn(),
      },
    } as unknown as trpcClientModule.TrpcClient);

    const result = await performBeadsImport(project);
    expect(result.imported).toBe(0);
    expect(result.duplicateSkips).toBe(1);
    expect(create).not.toHaveBeenCalled();
  });
});
