import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockSpawnSync,
  mockExecFileSync,
  mockReadFileSync,
  mockWriteFileSync,
  mockUnlinkSync,
  mockSetRawMode,
  mockStdoutWrite,
  mockRlQuestion,
  mockStdinEmitter,
} = vi.hoisted(() => {
  // Mock stdin event emitter for dropdown simulation
  const listeners: Map<string, Set<(chunk: Buffer) => void>> = new Map();
  return {
    mockSpawnSync: vi.fn(),
    mockExecFileSync: vi.fn(),
    mockReadFileSync: vi.fn(),
    mockWriteFileSync: vi.fn(),
    mockUnlinkSync: vi.fn(),
    mockSetRawMode: vi.fn(),
    mockStdoutWrite: vi.fn(),
    mockRlQuestion: vi.fn(),
    mockStdinEmitter: {
      on: (event: string, listener: (chunk: Buffer) => void) => {
        if (!listeners.has(event)) listeners.set(event, new Set());
        listeners.get(event)!.add(listener);
        return mockStdinEmitter;
      },
      removeListener: (event: string, listener: (chunk: Buffer) => void) => {
        listeners.get(event)?.delete(listener);
        return mockStdinEmitter;
      },
      emit: (event: string, chunk: Buffer) => {
        listeners.get(event)?.forEach((l) => l(chunk));
        return true;
      },
      _getListeners: (event: string) => listeners.get(event)?.size ?? 0,
      _clearListeners: (event: string) => listeners.delete(event),
    },
  };
});

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

// Mock readline to return synchronous values for tests
vi.mock("node:readline/promises", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  createInterface: vi.fn().mockReturnValue({
    question: mockRlQuestion,
    close: vi.fn(),
  }),
}));

// Mock process.stdin for dropdown simulation
Object.defineProperty(process, "stdin", {
  value: {
    isTTY: true,
    setRawMode: mockSetRawMode,
    isRaw: false,
    on: mockStdinEmitter.on,
    removeListener: mockStdinEmitter.removeListener,
    removeAllListeners: (event: string) => mockStdinEmitter._clearListeners(event),
  },
  writable: true,
});

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

  // stdin-driven Vitest coverage for createTaskInEditor dropdown flow
  // Arrow key escape sequences for dropdown navigation
  const KEY_ENTER = "\r";
  const KEY_ESC = "\u001B";
  const KEY_ARROW_UP = "\x1B[A";
  const KEY_ARROW_DOWN = "\x1B[B";

  beforeEach(() => {
    // Clear any lingering listeners between tests
    mockStdinEmitter._clearListeners("data");
  });

  // Helper to emit key after allowing event loop to register listener
  const emitKey = async (key: string): Promise<void> => {
    await new Promise<void>((resolve) => setImmediate(resolve));
    mockStdinEmitter.emit("data", Buffer.from(key));
  };

  it("creates task with defaults via Enter key on dropdowns", async () => {
    const onError = vi.fn();

    mockRlQuestion
      .mockResolvedValueOnce("") // ID (empty, optional)
      .mockResolvedValueOnce("New task") // Title
      .mockResolvedValueOnce(""); // Description

    // Start the editor and emit keys asynchronously
    const editorPromise = createTaskInEditor(onError);

    // Simulate Enter for type dropdown (selects default "task")
    await emitKey(KEY_ENTER);
    // Simulate Enter for priority dropdown (selects default index 2 = "2 (medium)")
    await emitKey(KEY_ENTER);

    const result = await editorPromise;

    expect(result).toMatchObject({
      title: "New task",
      type: "task",
      priority: 2,
    });
    expect(onError).not.toHaveBeenCalled();

    // Verify stdin listeners are cleaned up after dropdowns complete
    expect(mockStdinEmitter._getListeners("data")).toBe(0);
  });

  it("cancels task creation with Escape key on dropdown", async () => {
    const onError = vi.fn();

    mockRlQuestion
      .mockResolvedValueOnce("") // ID
      .mockResolvedValueOnce("New task"); // Title

    // Start the editor and emit escape asynchronously
    const editorPromise = createTaskInEditor(onError);

    // Simulate Escape for type dropdown to cancel
    await emitKey(KEY_ESC);

    const result = await editorPromise;

    expect(result).toBeNull();

    // Verify stdin listeners are cleaned up after cancellation
    expect(mockStdinEmitter._getListeners("data")).toBe(0);
  });

  it("validates title presence in createTaskInEditor", async () => {
    const onError = vi.fn();

    // Empty title - should trigger error before dropdown
    mockRlQuestion
      .mockResolvedValueOnce("") // ID
      .mockResolvedValueOnce(""); // Title (empty - should trigger error)

    const result = await createTaskInEditor(onError);

    expect(result).toBeNull();
    expect(onError).toHaveBeenCalledWith("Title is required.");

    // No dropdown stdin listeners should exist since we never got to the dropdowns
    expect(mockStdinEmitter._getListeners("data")).toBe(0);
  });

  it("navigates dropdown with arrow keys and selects non-default options", async () => {
    const onError = vi.fn();

    mockRlQuestion
      .mockResolvedValueOnce("custom-id") // ID
      .mockResolvedValueOnce("Bug task") // Title
      .mockResolvedValueOnce("This is a bug"); // Description

    // Start the editor
    const editorPromise = createTaskInEditor(onError);

    // For type dropdown: navigate to "bug" (index 1, default is "task" at index 0)
    await emitKey(KEY_ARROW_DOWN); // Move to index 1 (bug)
    await emitKey(KEY_ENTER); // Select "bug"

    // For priority dropdown: navigate to "0 (critical)" (index 0, default is index 2)
    await emitKey(KEY_ARROW_UP); // Move to index 1
    await emitKey(KEY_ARROW_UP); // Move to index 0 (critical)
    await emitKey(KEY_ENTER); // Select priority 0

    const result = await editorPromise;

    expect(result).toMatchObject({
      id: "custom-id",
      title: "Bug task",
      type: "bug",
      priority: 0,
    });
    expect(onError).not.toHaveBeenCalled();

    // Verify stdin listeners are cleaned up after dropdowns complete
    expect(mockStdinEmitter._getListeners("data")).toBe(0);
  });

  it("throws from legacy sync wrappers", () => {
    expect(() => applyStatusChange("/tmp/project", "task-1", "ready")).toThrow("applyStatusChange is now async");
    expect(() => closeTask("/tmp/project", "task-1")).toThrow("closeTask is now async");
    expect(() => saveEditedTask("/tmp/project", "task-1", createTask())).toThrow("saveEditedTask is now async");
  });
});
