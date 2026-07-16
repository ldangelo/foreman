import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockSpawnSync,
  mockExecFileSync,
  mockReadFileSync,
  mockWriteFileSync,
  mockUnlinkSync,
  mockSetRawMode,
  mockStdinOn,
  mockStdinRemoveAllListeners,
  mockStdoutWrite,
} = vi.hoisted(() => ({
  mockSpawnSync: vi.fn(),
  mockExecFileSync: vi.fn(),
  mockReadFileSync: vi.fn(),
  mockWriteFileSync: vi.fn(),
  mockUnlinkSync: vi.fn(),
  mockSetRawMode: vi.fn(),
  mockStdinOn: vi.fn(),
  mockStdinRemoveAllListeners: vi.fn(),
  mockStdoutWrite: vi.fn(),
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

// Mock TTY stdin/stdout for createTaskInEditor tests
vi.stubGlobal("process", {
  ...process,
  stdin: {
    ...process.stdin,
    isTTY: true,
    setRawMode: mockSetRawMode,
    on: mockStdinOn,
    removeAllListeners: mockStdinRemoveAllListeners,
  },
  stdout: {
    ...process.stdout,
    write: mockStdoutWrite,
  },
});

// Mock readline to return synchronous values for tests
const mockRlQuestion = vi.fn();
vi.mock("node:readline/promises", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  createInterface: vi.fn().mockReturnValue({
    question: mockRlQuestion,
    close: vi.fn(),
  }),
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

  it("surfaces createTaskInEditor parse failures and success cases", async () => {
    const onError = vi.fn();

    // Simulate dropdown selection by triggering Enter on the stdin event
    // The dropdown handler is set up asynchronously, so we need to simulate the sequence
    mockRlQuestion
      .mockResolvedValueOnce("") // ID (empty, optional)
      .mockResolvedValueOnce("New task") // Title
      .mockResolvedValueOnce("") // Description (empty, optional)
      // Type dropdown: select "task" (default, index 0) - triggered via stdin
      // Priority dropdown: select index 2 (medium) - triggered via stdin
      .mockResolvedValueOnce(""); // Extra calls

    // Simulate the dropdown selection by triggering Enter on stdin
    let dropdownCallback: ((chunk: Buffer) => void) | undefined;
    mockStdinOn.mockImplementation((event: string, cb: (chunk: Buffer) => void) => {
      if (event === "data") {
        dropdownCallback = cb;
      }
    });

    // Start the task creation
    const promise = createTaskInEditor(onError);

    // Simulate type dropdown selection (first dropdown - Enter to select default "task")
    if (dropdownCallback) {
      dropdownCallback(Buffer.from("\r")); // Enter for type
      // Wait a tick for the next dropdown
      await new Promise((r) => setTimeout(r, 10));
      // Simulate priority dropdown selection (Enter to select default "2 (medium)")
      dropdownCallback(Buffer.from("\r")); // Enter for priority
    }

    const result = await promise;

    expect(result).toMatchObject({
      title: "New task",
      description: null,
      type: "task",
      priority: 2,
      status: "backlog",
    });
  });

  it("surfaces createTaskInEditor non-zero editor exits", async () => {
    const onError = vi.fn();

    mockRlQuestion.mockResolvedValueOnce(""); // ID
    mockRlQuestion.mockResolvedValueOnce("New task"); // Title
    mockRlQuestion.mockResolvedValueOnce(""); // Description
    // Simulate Esc to cancel at type dropdown
    mockStdinOn.mockImplementation((event: string, cb: (chunk: Buffer) => void) => {
      if (event === "data") {
        cb(Buffer.from("\x1B")); // Escape
      }
    });

    const result = await createTaskInEditor(onError);

    expect(result).toBeNull();
    expect(onError).toHaveBeenCalledWith("Task creation cancelled.");
  });

  it("validates title presence in createTaskInEditor", async () => {
    const onError = vi.fn();

    // Empty title
    mockRlQuestion
      .mockResolvedValueOnce("") // ID
      .mockResolvedValueOnce("") // Title (empty - should trigger error)
      .mockResolvedValueOnce("") // Description
      .mockResolvedValueOnce(""); // Extra calls

    const result = await createTaskInEditor(onError);

    expect(result).toBeNull();
    expect(onError).toHaveBeenCalledWith("Title is required.");
  });

  it("creates task with custom id, type, and priority via dropdown", async () => {
    const onError = vi.fn();

    mockRlQuestion
      .mockResolvedValueOnce("custom-id") // ID
      .mockResolvedValueOnce("Bug task") // Title
      .mockResolvedValueOnce("This is a bug") // Description
      .mockResolvedValueOnce(""); // Extra calls

    // Simulate dropdown selections: type "bug" (index 1), priority "0 (critical)" (index 0)
    let dropdownCallback: ((chunk: Buffer) => void) | undefined;
    mockStdinOn.mockImplementation((event: string, cb: (chunk: Buffer) => void) => {
      if (event === "data") {
        dropdownCallback = cb;
      }
    });

    const promise = createTaskInEditor(onError);

    if (dropdownCallback) {
      // Type dropdown: arrow down once to select "bug" (index 1)
      dropdownCallback(Buffer.from("\x1B[B")); // Arrow down
      await new Promise((r) => setTimeout(r, 10));
      dropdownCallback(Buffer.from("\r")); // Enter to select

      // Priority dropdown: arrow up once to select "0 (critical)" (index 0 is already selected, this wraps to 4 then...)
      // Actually index 0 is "task" (default), arrow down once to go to "bug"
      // For priority, default is index 2 (medium), let's go to critical (index 0)
      await new Promise((r) => setTimeout(r, 10));
      dropdownCallback(Buffer.from("\x1B[A")); // Arrow up (from index 2 to index 1 = high)
      await new Promise((r) => setTimeout(r, 10));
      dropdownCallback(Buffer.from("\x1B[A")); // Arrow up again (from index 1 to index 0 = critical)
      await new Promise((r) => setTimeout(r, 10));
      dropdownCallback(Buffer.from("\r")); // Enter to select
    }

    const result = await promise;

    expect(result).toMatchObject({
      id: "custom-id",
      title: "Bug task",
      description: "This is a bug",
      type: "bug",
      priority: 0,
      status: "backlog",
    });
  });

  it("throws from legacy sync wrappers", () => {
    expect(() => applyStatusChange("/tmp/project", "task-1", "ready")).toThrow("applyStatusChange is now async");
    expect(() => closeTask("/tmp/project", "task-1")).toThrow("closeTask is now async");
    expect(() => saveEditedTask("/tmp/project", "task-1", createTask())).toThrow("saveEditedTask is now async");
  });
});
