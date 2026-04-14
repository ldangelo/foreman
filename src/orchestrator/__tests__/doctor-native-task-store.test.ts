import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it, vi } from "vitest";

const { mockAccess } = vi.hoisted(() => {
  return {
    mockAccess: vi.fn().mockResolvedValue(undefined),
  };
});

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = (await importOriginal()) as Record<string, unknown>;
  return {
    ...actual,
    access: mockAccess,
  };
});

describe("Doctor native task store awareness", () => {
  const tempDirs: string[] = [];

  function makeProject(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-doctor-native-"));
    tempDirs.push(dir);
    mkdirSync(join(dir, ".foreman"), { recursive: true });
    return dir;
  }

  afterEach(() => {
    vi.clearAllMocks();
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("reports native task store mode and migration warning when beads data also exists", async () => {
    const { ForemanStore } = await import("../../lib/store.js");
    const { NativeTaskStore } = await import("../../lib/task-store.js");
    const { Doctor } = await import("../doctor.js");

    const project = makeProject();
    mkdirSync(join(project, ".beads"), { recursive: true });
    writeFileSync(
      join(project, ".beads", "issues.jsonl"),
      `${JSON.stringify({ id: "bd-1", title: "Legacy bead", status: "open" })}\n`,
      "utf8",
    );

    const store = ForemanStore.forProject(project);
    new NativeTaskStore(store.getDb()).create({ title: "Native task", externalId: "bd-native" });

    const result = await new Doctor(store, project).checkTaskStoreMode();

    expect(result.status).toBe("warn");
    expect(result.message).toBe("Task store: native (1 tasks)");
    expect(result.details).toContain("Both native task store and beads data exist");
    store.close();
  });

  it("treats missing br as informational when native task store is active", async () => {
    const { ForemanStore } = await import("../../lib/store.js");
    const { NativeTaskStore } = await import("../../lib/task-store.js");
    const { Doctor } = await import("../doctor.js");

    mockAccess.mockRejectedValueOnce(Object.assign(new Error("ENOENT"), { code: "ENOENT" }));

    const project = makeProject();
    const store = ForemanStore.forProject(project);
    new NativeTaskStore(store.getDb()).create({ title: "Native task" });

    const result = await new Doctor(store, project).checkBrBinary();

    expect(result.status).toBe("pass");
    expect(result.message).toContain("native task store active");
    store.close();
  });

  it("skips beads initialization failure when native task store is active", async () => {
    const { ForemanStore } = await import("../../lib/store.js");
    const { NativeTaskStore } = await import("../../lib/task-store.js");
    const { Doctor } = await import("../doctor.js");

    const project = makeProject();
    const store = ForemanStore.forProject(project);
    new NativeTaskStore(store.getDb()).create({ title: "Native task" });

    const result = await new Doctor(store, project).checkBeadsInitialized();

    expect(result.status).toBe("skip");
    expect(result.message).toContain("Native task store active");
    store.close();
  });
});
