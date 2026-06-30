import { afterEach, describe, expect, it, vi } from "vitest";
import { existsSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  allocateTaskId,
  colorPriority,
  formatTaskIdDisplay,
  isBackwardStatusTransition,
  mapImportedBeadStatus,
  normalizeImportedBeadPriority,
  normalizeImportedBeadType,
  normalizeTaskIdPrefix,
  parseBeadsJsonl,
  priorityLabel,
  renderPrBadge,
  renderRunStatusBadge,
  renderRunStatusLine,
  resolveBeadsImportPath,
  resolveTaskId,
  statusChalk,
  summarizeImportPreview,
} from "../commands/task.js";

describe("task import/status helpers", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-task-import-helpers-"));
    tempDirs.push(dir);
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
    vi.restoreAllMocks();
  });

  it("renders run status badges and lines across branchy states", () => {
    expect(renderRunStatusBadge(null)).toContain("—");
    expect(renderRunStatusBadge({ isStuck: true, isStale: false, status: "running" } as any)).toContain("stuck");
    expect(renderRunStatusBadge({ isStuck: false, isStale: true, status: "running" } as any)).toContain("stale");
    expect(renderRunStatusBadge({ isStuck: false, isStale: false, status: "running", currentPhase: "qa" } as any)).toContain("qa");
    expect(renderRunStatusBadge({ isStuck: false, isStale: false, status: "running" } as any)).toContain("run");
    expect(renderRunStatusBadge({ isStuck: false, isStale: false, status: "completed" } as any)).toContain("done");
    expect(renderRunStatusBadge({ isStuck: false, isStale: false, status: "merged" } as any)).toContain("merged");
    expect(renderRunStatusBadge({ isStuck: false, isStale: false, status: "failed" } as any)).toContain("fail");
    expect(renderRunStatusBadge({ isStuck: false, isStale: false, status: "test-failed" } as any)).toContain("fail");
    expect(renderRunStatusBadge({ isStuck: false, isStale: false, status: "stuck" } as any)).toContain("stuck");
    expect(renderRunStatusBadge({ isStuck: false, isStale: false, status: "conflict" } as any)).toContain("conflict");
    expect(renderRunStatusBadge({ isStuck: false, isStale: false, status: "mystery" } as any)).toContain("mystery");

    expect(renderRunStatusLine({ isStuck: true, status: "running", currentPhase: null, lastActivityElapsed: null, toolCalls: 0, turns: 0, costUsd: 0, startedAt: null, completedAt: null } as any)).toContain("STUCK");
    expect(renderRunStatusLine({ isStuck: false, status: "running", currentPhase: "reviewer", lastActivityElapsed: "5m", toolCalls: 3, turns: 2, costUsd: 1.25, startedAt: null, completedAt: null } as any)).toContain("reviewer");
    expect(renderRunStatusLine({ isStuck: false, status: "failed", currentPhase: null, lastActivityElapsed: "5m", toolCalls: 3, turns: 2, costUsd: 1.25, startedAt: null, completedAt: null } as any)).toContain("FAILED");
    expect(renderRunStatusLine({ isStuck: false, status: "completed", currentPhase: null, lastActivityElapsed: "5m", toolCalls: 3, turns: 2, costUsd: 1.25, startedAt: null, completedAt: null } as any)).toContain("COMPLETED");
    expect(renderRunStatusLine({ isStuck: false, status: "merged", currentPhase: null, lastActivityElapsed: "5m", toolCalls: 3, turns: 2, costUsd: 1.25, startedAt: null, completedAt: null } as any)).toContain("MERGED");
    expect(renderRunStatusLine({ isStuck: false, status: "conflict", currentPhase: null, lastActivityElapsed: "5m", toolCalls: 3, turns: 2, costUsd: 1.25, startedAt: null, completedAt: null } as any)).toContain("CONFLICT");
  });

  it("parses beads JSONL and reports invalid JSON with line numbers", () => {
    const dir = makeTempDir();
    const good = join(dir, "good.jsonl");
    const bad = join(dir, "bad.jsonl");
    writeFileSync(good, '{"id":"bd-1","title":"One"}\n{"id":"bd-2","title":"Two"}\n');
    writeFileSync(bad, '{"id":"bd-1"}\n{broken\n');

    expect(parseBeadsJsonl(good)).toHaveLength(2);
    expect(() => parseBeadsJsonl(bad)).toThrow(/line 2/i);
  });

  it("normalizes task id prefixes, imported bead priority/type defaults, and import statuses", () => {
    expect(normalizeTaskIdPrefix("My Project")).toBe("my-project");
    expect(normalizeTaskIdPrefix("***")).toBe("task");
    expect(normalizeTaskIdPrefix(undefined)).toBe("task");

    expect(normalizeImportedBeadPriority({ id: "bd-1", title: "One", priority: 0 } as any)).toBe(0);
    expect(normalizeImportedBeadPriority({ id: "bd-2", title: "Two", priority: "p0" } as any)).toBe(0);
    expect(normalizeImportedBeadPriority({ id: "bd-3", title: "Three" } as any)).toBe(2);
    expect(() => normalizeImportedBeadPriority({ id: "bd-4", title: "Four", priority: 9 } as any)).toThrow(/unsupported numeric priority/i);

    expect(normalizeImportedBeadType({ id: "bd-5", title: "Five", type: "bug" } as any)).toBe("bug");
    expect(normalizeImportedBeadType({ id: "bd-6", title: "Six", issue_type: "feature" } as any)).toBe("feature");
    expect(normalizeImportedBeadType({ id: "bd-7", title: "Seven" } as any)).toBe("task");

    expect(mapImportedBeadStatus(undefined)).toBeNull();
    expect(mapImportedBeadStatus("open")).toBe("backlog");
    expect(mapImportedBeadStatus("in_progress")).toBe("ready");
    expect(mapImportedBeadStatus("closed")).toBe("merged");
    expect(mapImportedBeadStatus("mystery-status")).toBeNull();
  });

  it("resolves the first available beads export path and errors when none exist", () => {
    const dir = makeTempDir();
    mkdirSync(join(dir, ".beads"), { recursive: true });
    const issuesPath = join(dir, ".beads", "issues.jsonl");
    const beadsPath = join(dir, ".beads", "beads.jsonl");

    writeFileSync(issuesPath, "\n");
    expect(resolveBeadsImportPath(dir)).toBe(issuesPath);

    rmSync(issuesPath, { force: true });
    writeFileSync(beadsPath, "\n");
    expect(resolveBeadsImportPath(dir)).toBe(beadsPath);

    rmSync(beadsPath, { force: true });
    expect(() => resolveBeadsImportPath(dir)).toThrow(/No beads export found/);
  });

  it("allocates task ids with the normalized project prefix", () => {
    const existing = new Set<string>(["proj-aaaaaa"]);
    const id = allocateTaskId("proj", existing);

    expect(id).toMatch(/^proj-[0-9a-f]{5}$/);
    expect(existing.has(id)).toBe(true);
  });

  it("formats task ids, priorities, statuses, PR badges, and task-id resolution branches", () => {
    expect(priorityLabel(0)).toBe("critical");
    expect(priorityLabel(1)).toBe("high");
    expect(priorityLabel(2)).toBe("medium");
    expect(priorityLabel(3)).toBe("low");
    expect(priorityLabel(4)).toBe("backlog");
    expect(priorityLabel(9)).toBe("9");

    expect(formatTaskIdDisplay("short-id")).toBe("short-id");
    expect(formatTaskIdDisplay("task-1234567890abcdef")).toBe("task-123…");

    expect(isBackwardStatusTransition("review", "developer")).toBe(true);
    expect(isBackwardStatusTransition("backlog", "ready")).toBe(false);

    expect(colorPriority("p0", 0)).toContain("p0");
    expect(colorPriority("p4", 4)).toContain("p4");
    expect(statusChalk("ready")).toContain("ready");
    expect(statusChalk("in-progress")).toContain("in-progress");
    expect(statusChalk("merged")).toContain("merged");
    expect(statusChalk("blocked")).toContain("blocked");
    expect(statusChalk("failed")).toContain("failed");
    expect(statusChalk("backlog")).toContain("backlog");

    expect(renderPrBadge(undefined)).toContain("—");
    expect(renderPrBadge({ status: "none" } as any)).toContain("no PR");
    expect(renderPrBadge({ status: "open", number: 12 } as any)).toContain("#12");
    expect(renderPrBadge({ status: "merged", number: 13, isStale: false } as any)).toContain("#13");
    expect(renderPrBadge({ status: "merged", number: 14, isStale: true } as any)).toContain("stale");
    expect(renderPrBadge({ status: "closed", number: 15 } as any)).toContain("closed");
    expect(renderPrBadge({ status: "error" } as any)).toContain("?");

    const rows = [
      { id: "task-11111" },
      { id: "task-22222" },
      { id: "bug-33333" },
    ] as any;
    expect(resolveTaskId(rows, "bug-33333")).toBe("bug-33333");
    expect(resolveTaskId(rows, "task-111")).toBe("task-11111");
    expect(() => resolveTaskId(rows, "task-")).toThrow(/Ambiguous task ID prefix/);
    expect(() => resolveTaskId(rows, "missing")).toThrow(/not found/);
  });

  it("prints empty and populated import previews", () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    summarizeImportPreview([] as any);
    expect(logSpy.mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("No importable beads found");

    logSpy.mockClear();
    summarizeImportPreview([
      {
        bead: { id: "bd-1", title: "First bead" },
        nativeId: "task-1",
        status: "backlog",
        type: "task",
        priority: 2,
      },
    ] as any);
    const rendered = logSpy.mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Dry-run preview");
    expect(rendered).toContain("bd-1");
    expect(rendered).toContain("task-1");
  });
});
