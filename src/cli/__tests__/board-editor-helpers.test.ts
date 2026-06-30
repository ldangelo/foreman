import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockSpawnSync,
  mockExecFileSync,
  mockReadFileSync,
  mockWriteFileSync,
  mockUnlinkSync,
} = vi.hoisted(() => ({
  mockSpawnSync: vi.fn(),
  mockExecFileSync: vi.fn(),
  mockReadFileSync: vi.fn(),
  mockWriteFileSync: vi.fn(),
  mockUnlinkSync: vi.fn(),
}));

vi.mock("node:child_process", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  spawnSync: mockSpawnSync,
  execFileSync: mockExecFileSync,
}));

vi.mock("node:fs", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  readFileSync: mockReadFileSync,
  writeFileSync: mockWriteFileSync,
  unlinkSync: mockUnlinkSync,
}));

import {
  applyStatusChange,
  closeTask,
  copyToClipboard,
  createTaskInEditor,
  editTaskInEditor,
  resolveEditor,
  saveEditedTask,
  type BoardTask,
} from "../commands/board.js";

function createTask(overrides: Partial<BoardTask> = {}): BoardTask {
  return {
    id: "task-1",
    title: "Task 1",
    description: "Original description",
    type: "task",
    priority: 2,
    status: "backlog",
    external_id: null,
    created_at: "2026-01-01T00:00:00.000Z",
    updated_at: "2026-01-01T00:00:00.000Z",
    approved_at: null,
    closed_at: null,
    ...overrides,
  };
}

describe("board editor and clipboard helpers", () => {
  const originalEditor = process.env.EDITOR;
  const originalVisual = process.env.VISUAL;

  beforeEach(() => {
    vi.clearAllMocks();
    delete process.env.EDITOR;
    delete process.env.VISUAL;
  });

  afterEach(() => {
    if (originalEditor === undefined) {
      delete process.env.EDITOR;
    } else {
      process.env.EDITOR = originalEditor;
    }
    if (originalVisual === undefined) {
      delete process.env.VISUAL;
    } else {
      process.env.VISUAL = originalVisual;
    }
  });

  it("prefers EDITOR then VISUAL for editor resolution", () => {
    process.env.EDITOR = "nvim";
    process.env.VISUAL = "vim";
    expect(resolveEditor()).toBe("nvim");

    delete process.env.EDITOR;
    expect(resolveEditor()).toBe("vim");
  });

  it("falls back to the first available editor on PATH", () => {
    mockExecFileSync.mockImplementation((cmd: string) => {
      if (cmd === "vim") return undefined;
      throw new Error("missing");
    });
    expect(resolveEditor()).toBe("vim");
  });

  it("returns a clipboard failure string when the platform clipboard command fails", () => {
    mockSpawnSync.mockReturnValue({ status: 1, stderr: "clipboard unavailable" });

    const result = copyToClipboard("task-1");

    expect(result).toContain("Failed to copy task ID to clipboard");
    expect(result).toContain("clipboard unavailable");
  });

  it("returns null when clipboard copy succeeds", () => {
    mockSpawnSync.mockReturnValue({ status: 0, stderr: "" });

    expect(copyToClipboard("task-1")).toBeNull();
  });

  it("surfaces editTaskInEditor write failures", () => {
    const onError = vi.fn();
    mockWriteFileSync.mockImplementation(() => {
      throw new Error("disk full");
    });

    expect(editTaskInEditor(createTask(), false, onError)).toBeNull();
    expect(onError).toHaveBeenCalledWith(expect.stringContaining("Failed to write temp file: disk full"));
  });

  it("surfaces editTaskInEditor non-zero editor exits", () => {
    process.env.EDITOR = "nvim";
    const onError = vi.fn();
    mockWriteFileSync.mockImplementation(() => undefined);
    mockSpawnSync.mockReturnValue({ status: 2 });

    expect(editTaskInEditor(createTask(), false, onError)).toBeNull();
    expect(onError).toHaveBeenCalledWith("Editor exited with code 2 — changes discarded.");
    expect(mockUnlinkSync).toHaveBeenCalled();
  });

  it("validates required fields in editTaskInEditor", () => {
    process.env.EDITOR = "nvim";
    const onError = vi.fn();
    mockWriteFileSync.mockImplementation(() => undefined);
    mockSpawnSync.mockReturnValue({ status: 0 });
    mockReadFileSync.mockReturnValue("title: Missing id\n");

    expect(editTaskInEditor(createTask(), false, onError)).toBeNull();
    expect(onError).toHaveBeenCalledWith("YAML must include id and title fields.");
  });

  it("parses edited tasks and clamps numeric priority", () => {
    process.env.EDITOR = "nvim";
    const onError = vi.fn();
    mockWriteFileSync.mockImplementation(() => undefined);
    mockSpawnSync.mockReturnValue({ status: 0 });
    mockReadFileSync.mockReturnValue([
      "id: task-1",
      "title: Updated title",
      "description: Updated description",
      "priority: 9",
      "status: ready",
    ].join("\n"));

    const result = editTaskInEditor(createTask(), false, onError);

    expect(result).toMatchObject({
      id: "task-1",
      title: "Updated title",
      description: "Updated description",
      priority: 4,
      status: "ready",
    });
    expect(onError).not.toHaveBeenCalled();
  });

  it("surfaces createTaskInEditor parse failures and success cases", () => {
    process.env.EDITOR = "nvim";
    const onError = vi.fn();
    mockWriteFileSync.mockImplementation(() => undefined);
    mockSpawnSync.mockReturnValue({ status: 0 });
    mockReadFileSync.mockReturnValueOnce("title: [broken\n");

    expect(createTaskInEditor(onError)).toBeNull();
    expect(onError).toHaveBeenCalledWith(expect.stringContaining("Failed to parse YAML:"));

    onError.mockClear();
    mockReadFileSync.mockReturnValueOnce([
      "id: custom-id",
      "title: New task",
      "description: Added from editor",
      "type: urgent",
      "priority: 0",
      "status: backlog",
    ].join("\n"));

    expect(createTaskInEditor(onError)).toEqual({
      id: "custom-id",
      title: "New task",
      description: "Added from editor",
      type: "task",
      priority: 0,
      status: "backlog",
    });
  });

  it("surfaces createTaskInEditor non-zero editor exits", () => {
    process.env.EDITOR = "nvim";
    const onError = vi.fn();
    mockWriteFileSync.mockImplementation(() => undefined);
    mockSpawnSync.mockReturnValue({ status: 3 });

    expect(createTaskInEditor(onError)).toBeNull();
    expect(onError).toHaveBeenCalledWith("Editor exited with code 3 — task not created.");
    expect(mockUnlinkSync).toHaveBeenCalled();
  });

  it("validates title presence in createTaskInEditor", () => {
    process.env.EDITOR = "nvim";
    const onError = vi.fn();
    mockWriteFileSync.mockImplementation(() => undefined);
    mockSpawnSync.mockReturnValue({ status: 0 });
    mockReadFileSync.mockReturnValue("description: missing title\n");

    expect(createTaskInEditor(onError)).toBeNull();
    expect(onError).toHaveBeenCalledWith("Title is required.");
  });

  it("throws from legacy sync wrappers", () => {
    expect(() => applyStatusChange("/tmp/project", "task-1", "ready")).toThrow("applyStatusChange is now async");
    expect(() => closeTask("/tmp/project", "task-1")).toThrow("closeTask is now async");
    expect(() => saveEditedTask("/tmp/project", "task-1", createTask())).toThrow("saveEditedTask is now async");
  });
});
