import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  mkdtempSync,
  rmSync,
  realpathSync,
  writeFileSync,
  mkdirSync,
  existsSync,
  readFileSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { BrIssue } from "../../lib/beads-rust.js";

// ── Test helpers ──────────────────────────────────────────────────────────

function makeTempDir(): string {
  return realpathSync(mkdtempSync(join(tmpdir(), "foreman-migrate-seeds-")));
}

function writeSeedsJsonl(dir: string, seeds: object[]): void {
  mkdirSync(join(dir, ".seeds"), { recursive: true });
  const content = seeds.map((s) => JSON.stringify(s)).join("\n") + "\n";
  writeFileSync(join(dir, ".seeds", "issues.jsonl"), content);
}

function makeClient(overrides: Partial<{
  ensureBrInstalled: () => Promise<void>;
  list: (opts?: { limit?: number }) => Promise<BrIssue[]>;
  create: (title: string, opts?: { type?: string; priority?: string; description?: string }) => Promise<BrIssue>;
  close: (id: string, reason?: string) => Promise<void>;
  addDependency: (childId: string, parentId: string) => Promise<void>;
}> = {}) {
  return {
    ensureBrInstalled: vi.fn().mockResolvedValue(undefined),
    list: vi.fn().mockResolvedValue([]),
    create: vi.fn().mockResolvedValue({ id: "BR-001", title: "default" } as BrIssue),
    close: vi.fn().mockResolvedValue(undefined),
    addDependency: vi.fn().mockResolvedValue(undefined),
    ...overrides,
  };
}

// ── Unit tests for exported helpers ──────────────────────────────────────

describe("migrate-seeds module exports", () => {
  it("migrateSeedsCommand is a Commander Command named 'migrate-seeds'", async () => {
    const { migrateSeedsCommand } = await import("../commands/migrate-seeds.js");
    expect(migrateSeedsCommand.name()).toBe("migrate-seeds");
  });

  it("migrateSeedsCommand has --dry-run option", async () => {
    const { migrateSeedsCommand } = await import("../commands/migrate-seeds.js");
    const optionNames = migrateSeedsCommand.options.map((o) => o.long);
    expect(optionNames).toContain("--dry-run");
  });

  it("migrateSeedsCommand has a meaningful description", async () => {
    const { migrateSeedsCommand } = await import("../commands/migrate-seeds.js");
    expect(migrateSeedsCommand.description()).toMatch(/seed|migrat/i);
  });
});

describe("normalizeSeedType", () => {
  it("passes through valid br types unchanged", async () => {
    const { normalizeSeedType } = await import("../commands/migrate-seeds.js");
    for (const t of ["task", "bug", "feature", "epic", "chore", "decision"]) {
      expect(normalizeSeedType(t)).toBe(t);
    }
  });

  it("defaults to 'task' for unknown type", async () => {
    const { normalizeSeedType } = await import("../commands/migrate-seeds.js");
    expect(normalizeSeedType("unknown_type")).toBe("task");
    expect(normalizeSeedType("")).toBe("task");
    expect(normalizeSeedType(undefined as unknown as string)).toBe("task");
  });
});

describe("parseSeedsJsonl", () => {
  let parseSeedsJsonl: (content: string) => unknown[];

  beforeEach(async () => {
    ({ parseSeedsJsonl } = await import("../commands/migrate-seeds.js"));
  });

  it("parses a single valid JSONL line", () => {
    const line = JSON.stringify({
      id: "sd-1",
      title: "Do a thing",
      type: "task",
      priority: "P2",
      status: "open",
    });
    const result = parseSeedsJsonl(line + "\n");
    expect(result).toHaveLength(1);
    expect((result[0] as { title: string }).title).toBe("Do a thing");
  });

  it("parses multiple JSONL lines", () => {
    const lines = [
      JSON.stringify({ id: "sd-1", title: "A", type: "task", priority: "P2", status: "open" }),
      JSON.stringify({ id: "sd-2", title: "B", type: "bug", priority: "P1", status: "closed" }),
    ].join("\n");
    const result = parseSeedsJsonl(lines);
    expect(result).toHaveLength(2);
  });

  it("skips blank lines gracefully", () => {
    const lines = [
      JSON.stringify({ id: "sd-1", title: "A", type: "task", priority: "P2", status: "open" }),
      "",
      "   ",
    ].join("\n");
    const result = parseSeedsJsonl(lines);
    expect(result).toHaveLength(1);
  });

  it("returns empty array for empty content", () => {
    expect(parseSeedsJsonl("")).toHaveLength(0);
    expect(parseSeedsJsonl("   \n  \n")).toHaveLength(0);
  });
});

// ── Integration-style tests using injected client ─────────────────────────

describe("runMigration (unit-level via injected client)", () => {
  let tmpDir: string;
  let runMigration: (
    projectPath: string,
    opts: { dryRun: boolean; client?: ReturnType<typeof makeClient> },
  ) => Promise<import("../commands/migrate-seeds.js").MigrationResult>;

  beforeEach(async () => {
    tmpDir = makeTempDir();
    // Create .beads so real BeadsRustClient.isInitialized() would pass
    mkdirSync(join(tmpDir, ".beads"), { recursive: true });
    ({ runMigration } = await import("../commands/migrate-seeds.js"));
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    vi.restoreAllMocks();
  });

  it("dry-run prints planned actions without creating anything", async () => {
    writeSeedsJsonl(tmpDir, [
      { id: "sd-1", title: "Task Alpha", type: "task", priority: "P2", status: "open" },
      { id: "sd-2", title: "Task Beta", type: "bug", priority: "P1", status: "open" },
    ]);

    const client = makeClient({
      create: vi.fn().mockRejectedValue(new Error("should not be called in dry-run")),
      close: vi.fn().mockRejectedValue(new Error("should not be called in dry-run")),
      addDependency: vi.fn().mockRejectedValue(new Error("should not be called in dry-run")),
    });

    const result = await runMigration(tmpDir, { dryRun: true, client });

    expect(client.create).not.toHaveBeenCalled();
    expect(result.created).toBe(0);
    expect(result.planned).toBe(2);
    expect(result.skipped).toBe(0);
    expect(result.failed).toBe(0);
  });

  it("creates seeds with correct br fields (title, type, priority)", async () => {
    writeSeedsJsonl(tmpDir, [
      {
        id: "sd-1",
        title: "Implement login",
        type: "feature",
        priority: "P1",
        status: "open",
        description: "Add user login flow",
      },
    ]);

    const mockCreate = vi.fn().mockResolvedValue({ id: "BR-001", title: "Implement login" } as BrIssue);
    const client = makeClient({ create: mockCreate });

    await runMigration(tmpDir, { dryRun: false, client });

    expect(mockCreate).toHaveBeenCalledOnce();
    const [title, opts] = mockCreate.mock.calls[0] as [string, Record<string, unknown>];
    expect(title).toBe("Implement login");
    expect(opts.type).toBe("feature");
    expect(opts.priority).toBe("1"); // formatPriorityForBr("P1") = "1"
    expect(opts.description).toBe("Add user login flow");
  });

  it("creates 'in_progress' seeds as status: open (no close call)", async () => {
    writeSeedsJsonl(tmpDir, [
      { id: "sd-1", title: "WIP task", type: "task", priority: "P2", status: "in_progress" },
    ]);

    const mockCreate = vi.fn().mockResolvedValue({ id: "BR-010", title: "WIP task" } as BrIssue);
    const mockClose = vi.fn().mockResolvedValue(undefined);
    const client = makeClient({ create: mockCreate, close: mockClose });

    const result = await runMigration(tmpDir, { dryRun: false, client });

    expect(mockCreate).toHaveBeenCalledOnce();
    // in_progress → created as open (no close call)
    expect(mockClose).not.toHaveBeenCalled();
    expect(result.created).toBe(1);
  });

  it("creates 'closed' seeds then immediately closes them", async () => {
    writeSeedsJsonl(tmpDir, [
      { id: "sd-1", title: "Done task", type: "task", priority: "P3", status: "closed" },
    ]);

    const mockCreate = vi.fn().mockResolvedValue({ id: "BR-020", title: "Done task" } as BrIssue);
    const mockClose = vi.fn().mockResolvedValue(undefined);
    const client = makeClient({ create: mockCreate, close: mockClose });

    const result = await runMigration(tmpDir, { dryRun: false, client });

    expect(mockCreate).toHaveBeenCalledOnce();
    expect(mockClose).toHaveBeenCalledWith("BR-020", expect.any(String));
    expect(result.created).toBe(1);
    expect(result.closed).toBe(1);
  });

  it("replays dependency edges after all creates", async () => {
    writeSeedsJsonl(tmpDir, [
      { id: "sd-1", title: "Base task", type: "task", priority: "P2", status: "open", dependencies: [] },
      { id: "sd-2", title: "Dependent task", type: "task", priority: "P2", status: "open", dependencies: ["sd-1"] },
    ]);

    let callCount = 0;
    const mockCreate = vi.fn().mockImplementation(async (title: string) => {
      callCount++;
      return { id: `BR-0${callCount}0`, title } as BrIssue;
    });
    const mockAddDependency = vi.fn().mockResolvedValue(undefined);
    const client = makeClient({ create: mockCreate, addDependency: mockAddDependency });

    await runMigration(tmpDir, { dryRun: false, client });

    expect(mockCreate).toHaveBeenCalledTimes(2);
    // Dependent task (BR-020) should depend on Base task (BR-010)
    expect(mockAddDependency).toHaveBeenCalledWith("BR-020", "BR-010");
    expect(mockAddDependency).toHaveBeenCalledTimes(1);
  });

  it("skips seeds whose title already exists in br (idempotency)", async () => {
    writeSeedsJsonl(tmpDir, [
      { id: "sd-1", title: "Existing task", type: "task", priority: "P2", status: "open" },
      { id: "sd-2", title: "New task", type: "task", priority: "P2", status: "open" },
    ]);

    const mockCreate = vi.fn().mockResolvedValue({ id: "BR-002", title: "New task" } as BrIssue);
    const client = makeClient({
      list: vi.fn().mockResolvedValue([
        { id: "BR-001", title: "Existing task", type: "task", priority: "2", status: "open" } as BrIssue,
      ]),
      create: mockCreate,
    });

    const result = await runMigration(tmpDir, { dryRun: false, client });

    // Only "New task" should be created; "Existing task" is skipped
    expect(mockCreate).toHaveBeenCalledOnce();
    expect(mockCreate).toHaveBeenCalledWith("New task", expect.anything());
    expect(result.created).toBe(1);
    expect(result.skipped).toBe(1);
  });

  it("handles missing .seeds/ directory gracefully", async () => {
    // tmpDir has no .seeds directory
    const client = makeClient();

    await expect(runMigration(tmpDir, { dryRun: false, client })).rejects.toThrow(
      /\.seeds.*not found|no seeds|seeds.*not exist|not.*initialized/i,
    );
  });

  it("writes migration report to docs/seeds-migration-report.md", async () => {
    writeSeedsJsonl(tmpDir, [
      { id: "sd-1", title: "Report test task", type: "task", priority: "P2", status: "open" },
    ]);

    const client = makeClient({
      create: vi.fn().mockResolvedValue({ id: "BR-001", title: "Report test task" } as BrIssue),
    });

    const result = await runMigration(tmpDir, { dryRun: false, client });

    const reportPath = join(tmpDir, "docs", "seeds-migration-report.md");
    expect(existsSync(reportPath)).toBe(true);

    const reportContent = readFileSync(reportPath, "utf-8");
    expect(reportContent).toMatch(/migration/i);
    expect(reportContent).toContain("Report test task");
    expect(result.reportPath).toBe(reportPath);
  });

  it("records failed count when create throws", async () => {
    writeSeedsJsonl(tmpDir, [
      { id: "sd-1", title: "Failing task", type: "task", priority: "P2", status: "open" },
      { id: "sd-2", title: "Good task", type: "task", priority: "P2", status: "open" },
    ]);

    let callIndex = 0;
    const mockCreate = vi.fn().mockImplementation(async () => {
      callIndex++;
      if (callIndex === 1) throw new Error("br create failed: some error");
      return { id: "BR-002", title: "Good task" } as BrIssue;
    });
    const client = makeClient({ create: mockCreate });

    const result = await runMigration(tmpDir, { dryRun: false, client });

    expect(result.failed).toBe(1);
    expect(result.created).toBe(1);
  });

  it("dry-run does not write report file", async () => {
    writeSeedsJsonl(tmpDir, [
      { id: "sd-1", title: "Some task", type: "task", priority: "P2", status: "open" },
    ]);

    const client = makeClient();

    await runMigration(tmpDir, { dryRun: true, client });

    const reportPath = join(tmpDir, "docs", "seeds-migration-report.md");
    expect(existsSync(reportPath)).toBe(false);
  });
});
