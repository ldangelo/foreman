import { describe, expect, it, vi, beforeEach } from "vitest";
import chalk from "chalk";
import { renderRunsTable, runToJson, isStuck, type RunRow } from "../runs.js";
import type { Run } from "../../../lib/store.js";

describe("isStuck", () => {
  const baseRun: Run = {
    id: "run-abc",
    project_id: "proj-1",
    seed_id: "task-123",
    agent_type: "developer",
    session_key: null,
    worktree_path: null,
    status: "running",
    started_at: new Date(Date.now() - 20 * 60 * 1000).toISOString(), // 20 min ago
    completed_at: null,
    created_at: new Date(Date.now() - 25 * 60 * 1000).toISOString(),
    progress: null,
  };

  it("returns false for completed run even if old", () => {
    const run = { ...baseRun, status: "completed" as const, completed_at: new Date().toISOString() };
    expect(isStuck(run, null)).toBe(false);
  });

  it("returns false for pending run within threshold", () => {
    const run = { ...baseRun, started_at: new Date(Date.now() - 5 * 60 * 1000).toISOString() };
    expect(isStuck(run, null)).toBe(false);
  });

  it("returns true for running run exceeding 15 min threshold", () => {
    expect(isStuck(baseRun, null)).toBe(true);
  });

  it("returns true for pending run exceeding threshold", () => {
    const run = { ...baseRun, status: "pending" as const };
    expect(isStuck(run, null)).toBe(true);
  });

  it("uses created_at when started_at is null", () => {
    const run = { ...baseRun, started_at: null };
    expect(isStuck(run, null)).toBe(true);
  });
});

describe("renderRunsTable", () => {
  const createRunRow = (overrides: Partial<RunRow> = {}): RunRow => ({
    id: "run-abc123",
    task: "foreman-99999",
    status: "running",
    phase: "developer",
    workerPid: "12345",
    elapsed: "5m 32s",
    lastEvent: "read(src/app.ts)",
    logPath: "/home/user/.foreman/logs/run-abc123.out",
    reportPath: "/home/user/.foreman/reports/run-abc123",
    cost: "$0.0234",
    turns: 42,
    indicators: [],
    raw: {
      id: "run-abc123",
      project_id: "proj-1",
      seed_id: "foreman-99999",
      agent_type: "developer",
      session_key: null,
      worktree_path: null,
      status: "running",
      started_at: new Date().toISOString(),
      completed_at: null,
      created_at: new Date().toISOString(),
      progress: null,
    },
    ...overrides,
  });

  it("returns empty string for no rows", () => {
    expect(renderRunsTable([])).toBe("");
  });

  it("renders basic columns for a single row", () => {
    const rows = [createRunRow()];
    const output = renderRunsTable(rows);
    expect(output).toContain("run-abc123");
    expect(output).toContain("foreman-99999");
    expect(output).toContain("RUNNING");
    expect(output).toContain("developer");
    expect(output).toContain("5m 32s");
  });

  it("includes STUCK indicator when present", () => {
    const rows = [createRunRow({ indicators: ["STUCK"] })];
    const output = renderRunsTable(rows);
    expect(output).toContain("STUCK");
  });

  it("includes FATAL indicator when present", () => {
    const rows = [createRunRow({ status: "failed", indicators: ["FATAL"] })];
    const output = renderRunsTable(rows);
    expect(output).toContain("FATAL");
  });

  it("shows verbose columns when verbose=true", () => {
    const rows = [createRunRow()];
    const output = renderRunsTable(rows, true);
    expect(output).toContain("LOG_PATH");
    expect(output).toContain("REPORT_PATH");
    expect(output).toContain("COST");
    expect(output).toContain("TURNS");
    expect(output).toContain("$0.0234");
    expect(output).toContain("42");
  });

  it("hides verbose columns when verbose=false", () => {
    const rows = [createRunRow()];
    const output = renderRunsTable(rows, false);
    expect(output).not.toContain("LOG_PATH");
    expect(output).not.toContain("REPORT_PATH");
    expect(output).not.toContain("COST");
    expect(output).not.toContain("TURNS");
  });

  it("shows null values as em-dash", () => {
    const rows = [createRunRow({ phase: null, lastEvent: null })];
    const output = renderRunsTable(rows);
    expect(output).toContain("—");
  });

  it("handles multiple rows", () => {
    const rows = [
      createRunRow({ id: "run-1", status: "running" }),
      createRunRow({ id: "run-2", status: "completed", phase: null, indicators: [] }),
    ];
    const output = renderRunsTable(rows);
    expect(output).toContain("run-1");
    expect(output).toContain("run-2");
  });
});

describe("runToJson", () => {
  const createRunRow = (overrides: Partial<RunRow> = {}): RunRow => ({
    id: "run-xyz",
    task: "foreman-12345",
    status: "running",
    phase: "developer",
    workerPid: "67890",
    elapsed: "3m 10s",
    lastEvent: "bash(npm test)",
    logPath: "/home/user/.foreman/logs/run-xyz.out",
    reportPath: "/home/user/.foreman/reports/run-xyz",
    cost: "$0.0150",
    turns: 15,
    indicators: [],
    raw: {
      id: "run-xyz",
      project_id: "proj-1",
      seed_id: "foreman-12345",
      agent_type: "developer",
      session_key: null,
      worktree_path: null,
      status: "running",
      started_at: new Date(Date.now() - 3 * 60 * 1000).toISOString(),
      completed_at: null,
      created_at: new Date(Date.now() - 3 * 60 * 1000).toISOString(),
      progress: null,
    },
    ...overrides,
  });

  it("serializes all fields correctly", () => {
    const row = createRunRow();
    const json = runToJson(row);
    expect(json.id).toBe("run-xyz");
    expect(json.task).toBe("foreman-12345");
    expect(json.status).toBe("running");
    expect(json.phase).toBe("developer");
    expect(json.workerPid).toBe("67890");
    expect(json.lastEvent).toBe("bash(npm test)");
    expect(json.logPath).toBe("/home/user/.foreman/logs/run-xyz.out");
    expect(json.reportPath).toBe("/home/user/.foreman/reports/run-xyz");
    expect(json.cost).toBe("$0.0150");
    expect(json.turns).toBe(15);
  });

  it("sets stuck=true when STUCK indicator present", () => {
    const row = createRunRow({ indicators: ["STUCK"] });
    const json = runToJson(row);
    expect(json.stuck).toBe(true);
  });

  it("sets stuck=false when STUCK indicator absent", () => {
    const row = createRunRow({ indicators: [] });
    const json = runToJson(row);
    expect(json.stuck).toBe(false);
  });

  it("includes startedAt and createdAt from raw run", () => {
    const row = createRunRow();
    const json = runToJson(row);
    expect(json.startedAt).toBe(row.raw.started_at);
    expect(json.createdAt).toBe(row.raw.created_at);
  });

  it("handles null workerPid", () => {
    const row = createRunRow({ workerPid: null });
    const json = runToJson(row);
    expect(json.workerPid).toBeNull();
  });

  it("includes elapsedMs as positive number", () => {
    const row = createRunRow();
    const json = runToJson(row);
    expect(typeof json.elapsedMs).toBe("number");
    expect(json.elapsedMs).toBeGreaterThan(0);
  });
});
