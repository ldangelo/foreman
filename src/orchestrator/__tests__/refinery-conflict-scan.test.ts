import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdtempSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// ── Module mocks ─────────────────────────────────────────────────────────────

vi.mock("../../lib/git.js", () => ({
  mergeWorktree: vi.fn(),
  removeWorktree: vi.fn(),
  detectDefaultBranch: vi.fn().mockResolvedValue("main"),
}));

vi.mock("../task-backend-ops.js", () => ({
  resetSeedToOpen: vi.fn().mockResolvedValue(undefined),
  closeSeed: vi.fn().mockResolvedValue(undefined),
}));

import { Refinery } from "../refinery.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeMocks() {
  const store = {
    getRunsByStatus: vi.fn(() => []),
    getRunsByStatuses: vi.fn(() => []),
    getRun: vi.fn(() => null),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
  };
  const seeds = {
    getGraph: vi.fn(async () => ({ edges: [] })),
    show: vi.fn(async () => null),
    update: vi.fn(async () => undefined),
  };
  const refinery = new Refinery(store as any, seeds as any, "/tmp/project");
  return { store, seeds, refinery };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("Refinery.scanForConflictMarkers", () => {
  let tmpDir: string;
  let refinery: Refinery;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "refinery-conflict-scan-"));
    const { refinery: r } = makeMocks();
    refinery = r;
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  // Access private method via type assertion
  function scanForConflictMarkers(dir: string): Promise<string[]> {
    return (refinery as any).scanForConflictMarkers(dir);
  }

  it("returns [] for a clean directory with no source files", async () => {
    const result = await scanForConflictMarkers(tmpDir);
    expect(result).toEqual([]);
  });

  it("returns [] for a clean .ts file with no conflict markers", async () => {
    writeFileSync(join(tmpDir, "clean.ts"), "export const x = 1;\n");
    const result = await scanForConflictMarkers(tmpDir);
    expect(result).toEqual([]);
  });

  it("returns the file path when <<<<<<< is present in a .ts file", async () => {
    writeFileSync(
      join(tmpDir, "conflict.ts"),
      "export const x = 1;\n<<<<<<< HEAD\nconst a = 1;\n=======\nconst a = 2;\n>>>>>>> branch\n",
    );
    const result = await scanForConflictMarkers(tmpDir);
    expect(result).toHaveLength(1);
    expect(result[0]).toBe("conflict.ts");
  });

  it("returns the file path when ||||||| (diff3 marker) is present in a .ts file", async () => {
    writeFileSync(
      join(tmpDir, "diff3.ts"),
      "export const y = 2;\n||||||| base\nconst y = 0;\n=======\nconst y = 3;\n>>>>>>> branch\n",
    );
    const result = await scanForConflictMarkers(tmpDir);
    expect(result).toHaveLength(1);
    expect(result[0]).toBe("diff3.ts");
  });

  it("excludes files inside node_modules/", async () => {
    const nmDir = join(tmpDir, "node_modules", "some-pkg");
    mkdirSync(nmDir, { recursive: true });
    writeFileSync(
      join(nmDir, "index.ts"),
      "<<<<<<< HEAD\nconflict here\n=======\n>>>>>>> branch\n",
    );
    const result = await scanForConflictMarkers(tmpDir);
    expect(result).toEqual([]);
  });

  it("excludes non-source files (.md)", async () => {
    writeFileSync(
      join(tmpDir, "README.md"),
      "<<<<<<< HEAD\nsome content\n=======\nother content\n>>>>>>> branch\n",
    );
    const result = await scanForConflictMarkers(tmpDir);
    expect(result).toEqual([]);
  });

  it("returns [] for a missing/non-existent directory", async () => {
    const result = await scanForConflictMarkers("/tmp/this-does-not-exist-foreman-test-12345");
    expect(result).toEqual([]);
  });

  it("returns multiple files when several source files have conflict markers", async () => {
    writeFileSync(
      join(tmpDir, "alpha.ts"),
      "<<<<<<< HEAD\nconst a = 1;\n=======\nconst a = 2;\n>>>>>>> branch\n",
    );
    writeFileSync(
      join(tmpDir, "beta.tsx"),
      "||||||| base\nconst b = 0;\n=======\nconst b = 3;\n>>>>>>> branch\n",
    );
    writeFileSync(join(tmpDir, "clean.js"), "const c = 3;\n");
    const result = await scanForConflictMarkers(tmpDir);
    expect(result).toHaveLength(2);
    expect(result).toContain("alpha.ts");
    expect(result).toContain("beta.tsx");
  });
});
