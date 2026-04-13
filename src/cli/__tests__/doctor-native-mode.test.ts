import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const { mockAccess } = vi.hoisted(() => {
  const mockAccess = vi.fn().mockRejectedValue(Object.assign(new Error("ENOENT"), { code: "ENOENT" }));
  return { mockAccess };
});

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal();
  return {
    ...actual,
    access: mockAccess,
  };
});

describe("doctor native-mode regression targets", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-doctor-native-")));
    tempDirs.push(dir);
    return dir;
  }

  afterEach(() => {
    vi.clearAllMocks();
    vi.unstubAllEnvs();
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("native task mode downgrades missing br/bv binaries from hard failure", async () => {
    vi.stubEnv("FOREMAN_TASK_STORE", "native");

    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    const tmp = makeTempDir();
    const store = new ForemanStore(join(tmp, "foreman.db"));
    store.getDb()
      .prepare(`INSERT INTO tasks (id, title, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`)
      .run("native-1", "Imported native task", "backlog", new Date().toISOString(), new Date().toISOString());

    const doctor = new Doctor(store, tmp);
    const results = await doctor.checkSystem();
    const brResult = results.find((result) => result.name.includes("br (beads_rust)"));
    const bvResult = results.find((result) => result.name.includes("bv (beads_viewer)"));

    expect(brResult?.status).not.toBe("fail");
    expect(bvResult?.status).not.toBe("fail");

    store.close();
  });
});
