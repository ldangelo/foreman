import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { AuditEntry, AuditFilter } from "../audit-reader.js";

// ── Mock better-sqlite3 ───────────────────────────────────────────────────────

const mockGet = vi.fn();
const mockAll = vi.fn();
const mockPrepare = vi.fn(() => ({ get: mockGet, all: mockAll }));
const mockClose = vi.fn();
const mockPragma = vi.fn();
const mockExec = vi.fn();

// better-sqlite3 is used as a constructor (new Database(...)), so the mock
// must be a class (or a function that returns an object and can be called
// with `new`).
vi.mock("better-sqlite3", () => {
  class MockDatabase {
    prepare = mockPrepare;
    close = mockClose;
    pragma = mockPragma;
    exec = mockExec;
  }
  return { default: MockDatabase };
});

// ── Mock node:fs/promises ─────────────────────────────────────────────────────

const mockReadFile = vi.fn();

vi.mock("node:fs/promises", () => ({
  readFile: mockReadFile,
}));

// ── Mock node:fs (mkdirSync used by ForemanStore) ─────────────────────────────

vi.mock("node:fs", () => ({
  mkdirSync: vi.fn(),
  existsSync: vi.fn(() => false),
}));

// ── Import subject under test (after mocks are set up) ───────────────────────

const { readAuditEntries } = await import("../audit-reader.js");

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeEntry(overrides: Partial<AuditEntry> = {}): AuditEntry {
  return {
    timestamp: "2025-01-15T10:00:00.000Z",
    runId: "run-abc123",
    seedId: "seed-001",
    phase: "developer",
    eventType: "tool_call",
    ...overrides,
  };
}

function makeJSONL(entries: AuditEntry[]): string {
  return entries.map((e) => JSON.stringify(e)).join("\n") + "\n";
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("readAuditEntries", () => {
  beforeEach(() => {
    vi.clearAllMocks();

    // Default: DB returns a run for "seed-001"
    mockGet.mockReturnValue({ id: "run-abc123", seed_id: "seed-001" });

    // Default: JSONL file has a few entries
    const defaultEntries: AuditEntry[] = [
      makeEntry({ phase: "explorer", eventType: "tool_call", toolName: "Read" }),
      makeEntry({ phase: "developer", eventType: "tool_call", toolName: "Edit" }),
      makeEntry({ phase: "developer", eventType: "turn_end", turnNumber: 3 }),
      makeEntry({ phase: "qa", eventType: "tool_call", toolName: "Bash" }),
      makeEntry({ phase: "qa", eventType: "agent_end" }),
    ];
    mockReadFile.mockResolvedValue(makeJSONL(defaultEntries));
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  // ── Test 1: phase filter ────────────────────────────────────────────────────

  it("returns only entries matching the phase filter", async () => {
    const results = await readAuditEntries("seed-001", { phase: "developer" });

    expect(results).toHaveLength(2);
    expect(results.every((e) => e.phase === "developer")).toBe(true);
  });

  // ── Test 2: eventType filter ────────────────────────────────────────────────

  it("returns only entries matching the eventType filter", async () => {
    const results = await readAuditEntries("seed-001", { eventType: "tool_call" });

    expect(results).toHaveLength(3);
    expect(results.every((e) => e.eventType === "tool_call")).toBe(true);
  });

  // ── Test 3: since/until range filter ───────────────────────────────────────

  it("returns entries within the since/until timestamp range", async () => {
    const entries: AuditEntry[] = [
      makeEntry({ timestamp: "2025-01-10T00:00:00.000Z", eventType: "tool_call" }),
      makeEntry({ timestamp: "2025-01-15T00:00:00.000Z", eventType: "tool_call" }),
      makeEntry({ timestamp: "2025-01-20T00:00:00.000Z", eventType: "tool_call" }),
      makeEntry({ timestamp: "2025-01-25T00:00:00.000Z", eventType: "tool_call" }),
    ];
    mockReadFile.mockResolvedValue(makeJSONL(entries));

    const results = await readAuditEntries("seed-001", {
      since: "2025-01-12T00:00:00.000Z",
      until: "2025-01-22T00:00:00.000Z",
    });

    expect(results).toHaveLength(2);
    expect(results[0].timestamp).toBe("2025-01-15T00:00:00.000Z");
    expect(results[1].timestamp).toBe("2025-01-20T00:00:00.000Z");
  });

  // ── Test 4: search text filter ─────────────────────────────────────────────

  it("returns entries where the raw JSON line includes the search text (case-insensitive)", async () => {
    const entries: AuditEntry[] = [
      makeEntry({ toolName: "Read", eventType: "tool_call" }),
      makeEntry({ toolName: "EditFile", eventType: "tool_call" }),
      makeEntry({ eventType: "turn_end" }),
    ];
    mockReadFile.mockResolvedValue(makeJSONL(entries));

    const results = await readAuditEntries("seed-001", { search: "editfile" });

    expect(results).toHaveLength(1);
    expect(results[0].toolName).toBe("EditFile");
  });

  // ── Test 5: no run found for seedId ────────────────────────────────────────

  it("returns empty array when no run is found for the seedId", async () => {
    mockGet.mockReturnValue(undefined);

    const results = await readAuditEntries("seed-unknown");

    expect(results).toHaveLength(0);
    // Should not attempt to read any file
    expect(mockReadFile).not.toHaveBeenCalled();
  });

  // ── Test 6: JSONL file not found ───────────────────────────────────────────

  it("returns empty array when the JSONL audit file does not exist", async () => {
    const fileError = Object.assign(new Error("ENOENT"), { code: "ENOENT" });
    mockReadFile.mockRejectedValue(fileError);

    const results = await readAuditEntries("seed-001");

    expect(results).toHaveLength(0);
  });

  it("returns empty array for any file read error (not just ENOENT)", async () => {
    mockReadFile.mockRejectedValue(new Error("permission denied"));

    const results = await readAuditEntries("seed-001");

    expect(results).toHaveLength(0);
  });

  // ── Test 7: combined filters ────────────────────────────────────────────────

  it("applies multiple filters together (phase AND eventType)", async () => {
    const results = await readAuditEntries("seed-001", {
      phase: "qa",
      eventType: "tool_call",
    });

    expect(results).toHaveLength(1);
    expect(results[0].phase).toBe("qa");
    expect(results[0].eventType).toBe("tool_call");
    expect(results[0].toolName).toBe("Bash");
  });

  it("applies since filter together with phase filter", async () => {
    const entries: AuditEntry[] = [
      makeEntry({ phase: "developer", timestamp: "2025-01-10T00:00:00.000Z" }),
      makeEntry({ phase: "developer", timestamp: "2025-01-20T00:00:00.000Z" }),
      makeEntry({ phase: "qa",        timestamp: "2025-01-20T00:00:00.000Z" }),
    ];
    mockReadFile.mockResolvedValue(makeJSONL(entries));

    const results = await readAuditEntries("seed-001", {
      phase: "developer",
      since: "2025-01-15T00:00:00.000Z",
    });

    expect(results).toHaveLength(1);
    expect(results[0].timestamp).toBe("2025-01-20T00:00:00.000Z");
  });

  // ── Test 8: no filter returns all entries ──────────────────────────────────

  it("returns all entries when no filter is provided", async () => {
    const results = await readAuditEntries("seed-001");

    expect(results).toHaveLength(5);
  });

  // ── Test 9: skips malformed JSON lines gracefully ──────────────────────────

  it("skips malformed JSON lines and returns valid entries", async () => {
    const raw =
      JSON.stringify(makeEntry({ eventType: "tool_call" })) + "\n" +
      "this is not json\n" +
      JSON.stringify(makeEntry({ eventType: "turn_end" })) + "\n";
    mockReadFile.mockResolvedValue(raw);

    const results = await readAuditEntries("seed-001");

    expect(results).toHaveLength(2);
  });
});
