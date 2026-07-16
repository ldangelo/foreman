import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  BOARD_STATUSES,
  boardApi,
  createKeyHandler,
  type BoardStatus,
  type BoardTask,
  type RenderState,
} from "../commands/board.js";

function createTask(id: string, overrides: Partial<BoardTask> = {}): BoardTask {
  return {
    id,
    title: `Task ${id}`,
    description: null,
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

function createTasksMap(tasksByStatus: Partial<Record<BoardStatus, BoardTask[]>>): Map<BoardStatus, BoardTask[]> {
  const map = new Map<BoardStatus, BoardTask[]>();
  for (const status of BOARD_STATUSES) {
    map.set(status, tasksByStatus[status] ?? []);
  }
  return map;
}

function createState(tasksByStatus: Partial<Record<BoardStatus, BoardTask[]>>, overrides: Partial<RenderState> = {}): RenderState {
  const tasks = createTasksMap(tasksByStatus);
  const totalTasks = [...tasks.values()].reduce((sum, rows) => sum + rows.length, 0);
  return {
    tasks,
    nav: { colIndex: 0, rowIndex: 0 },
    totalTasks,
    errorMessage: null,
    flashTaskId: null,
    showHelp: false,
    showDetail: false,
    detailTask: null,
    detailNotesStatus: "idle",
    detailNotesError: null,
    sortMode: "updated",
    ...overrides,
  };
}

describe("board key handler", () => {
  const originalApply = boardApi.applyStatusChangeAsync;
  const originalLoadNotes = boardApi.loadTaskNotesAsync;
  const originalCopy = boardApi.copyToClipboard;
  const originalCloseTaskAsync = boardApi.closeTaskAsync;
  const originalEditTaskInEditor = boardApi.editTaskInEditor;
  const originalSaveEditedTaskAsync = boardApi.saveEditedTaskAsync;
  const originalCreateTaskInEditor = boardApi.createTaskInEditor;
  const originalCreateTaskAsync = boardApi.createTaskAsync;

  beforeEach(() => {
    boardApi.applyStatusChangeAsync = vi.fn().mockResolvedValue(null);
    boardApi.loadTaskNotesAsync = vi.fn().mockResolvedValue([]);
    boardApi.copyToClipboard = vi.fn().mockReturnValue(null);
    boardApi.closeTaskAsync = vi.fn().mockResolvedValue(null);
    boardApi.editTaskInEditor = vi.fn().mockReturnValue(null);
    boardApi.saveEditedTaskAsync = vi.fn().mockResolvedValue(null);
    boardApi.createTaskInEditor = vi.fn().mockResolvedValue(null);
    boardApi.createTaskAsync = vi.fn().mockResolvedValue({ taskId: "task-new" });
  });

  afterEach(() => {
    boardApi.applyStatusChangeAsync = originalApply;
    boardApi.loadTaskNotesAsync = originalLoadNotes;
    boardApi.copyToClipboard = originalCopy;
    boardApi.closeTaskAsync = originalCloseTaskAsync;
    boardApi.editTaskInEditor = originalEditTaskInEditor;
    boardApi.saveEditedTaskAsync = originalSaveEditedTaskAsync;
    boardApi.createTaskInEditor = originalCreateTaskInEditor;
    boardApi.createTaskAsync = originalCreateTaskAsync;
    vi.restoreAllMocks();
  });

  it("navigates within and across columns", async () => {
    const state = createState({
      backlog: [createTask("task-1"), createTask("task-2")],
      ready: [createTask("task-3", { status: "ready" })],
    });
    const handleKey = createKeyHandler("/tmp/project");

    let result = await handleKey("j", state, "/tmp/project");
    expect(result.nav).toEqual({ colIndex: 0, rowIndex: 1 });

    result = await handleKey("k", { ...state, nav: { colIndex: 0, rowIndex: 0 } }, "/tmp/project");
    expect(result.nav).toEqual({ colIndex: 0, rowIndex: 1 });

    result = await handleKey("l", state, "/tmp/project");
    expect(result.nav).toEqual({ colIndex: 1, rowIndex: 0 });

    result = await handleKey("h", { ...state, nav: { colIndex: 0, rowIndex: 1 } }, "/tmp/project");
    expect(result.nav).toEqual({ colIndex: 4, rowIndex: 0 });

    result = await handleKey("2", state, "/tmp/project");
    expect(result.nav).toEqual({ colIndex: 1, rowIndex: 0 });
  });

  it("jumps to first and last rows in the current column", async () => {
    const state = createState({ backlog: [createTask("task-1"), createTask("task-2"), createTask("task-3")] }, {
      nav: { colIndex: 0, rowIndex: 1 },
    });
    const handleKey = createKeyHandler("/tmp/project");

    let result = await handleKey("g", state, "/tmp/project");
    expect(result.nav.rowIndex).toBe(0);

    result = await handleKey("G", state, "/tmp/project");
    expect(result.nav.rowIndex).toBe(2);
  });

  it("toggles and dismisses the help overlay", async () => {
    const state = createState({});
    const handleKey = createKeyHandler("/tmp/project");

    let result = await handleKey("?", state, "/tmp/project");
    expect(result.showHelp).toBe(true);

    result = await handleKey("?", { ...state, showHelp: true }, "/tmp/project");
    expect(result.showHelp).toBe(false);
    expect(result.needsRefresh).toBe(true);
  });

  it("opens and dismisses the detail panel while loading notes", async () => {
    const onDetailNotesLoaded = vi.fn();
    const state = createState({ backlog: [createTask("task-1")] });
    const handleKey = createKeyHandler("/tmp/project", { onDetailNotesLoaded });

    const result = await handleKey("\r", state, "/tmp/project");
    expect(result.showDetail).toBe(true);
    expect(result.detailTask?.id).toBe("task-1");
    expect(boardApi.loadTaskNotesAsync).toHaveBeenCalledWith("/tmp/project", "task-1");

    await Promise.resolve();
    expect(onDetailNotesLoaded).toHaveBeenCalledWith("task-1", [], null);

    const dismissed = await handleKey("\u001B", { ...state, showDetail: true, detailTask: createTask("task-1") }, "/tmp/project");
    expect(dismissed.showDetail).toBe(false);
    expect(dismissed.detailTask).toBeNull();
  });

  it("cycles task status and reports failures", async () => {
    const state = createState({ backlog: [createTask("task-1")] });
    const handleKey = createKeyHandler("/tmp/project");

    let result = await handleKey("s", state, "/tmp/project");
    expect(boardApi.applyStatusChangeAsync).toHaveBeenCalledWith("/tmp/project", "task-1", "ready");
    expect(result.flashTaskId).toBe("task-1");
    expect(result.needsRefresh).toBe(true);

    vi.mocked(boardApi.applyStatusChangeAsync).mockResolvedValueOnce("status failed");
    result = await handleKey("S", { ...state, tasks: createTasksMap({ ready: [createTask("task-2", { status: "ready" })] }), nav: { colIndex: 1, rowIndex: 0 } }, "/tmp/project");
    expect(boardApi.applyStatusChangeAsync).toHaveBeenCalledWith("/tmp/project", "task-2", "backlog");
    expect(result.errorMessage).toBe("status failed");
  });

  it("marks backlog tasks as ready and rejects non-backlog tasks", async () => {
    const handleKey = createKeyHandler("/tmp/project");

    let result = await handleKey("R", createState({ backlog: [createTask("task-1")] }), "/tmp/project");
    expect(boardApi.applyStatusChangeAsync).toHaveBeenCalledWith("/tmp/project", "task-1", "ready");
    expect(result.flashTaskId).toBe("task-1");

    result = await handleKey("R", createState({ ready: [createTask("task-2", { status: "ready" })] }, { nav: { colIndex: 1, rowIndex: 0 } }), "/tmp/project");
    expect(result.errorMessage).toBe("Task must be in backlog to mark as ready");
  });

  it("copies task ids to the clipboard and surfaces failures", async () => {
    const state = createState({ backlog: [createTask("task-1")] });
    const handleKey = createKeyHandler("/tmp/project");

    let result = await handleKey("y", state, "/tmp/project");
    expect(boardApi.copyToClipboard).toHaveBeenCalledWith("task-1");
    expect(result.flashTaskId).toBe("task-1");

    vi.mocked(boardApi.copyToClipboard).mockReturnValueOnce("copy failed");
    result = await handleKey("y", state, "/tmp/project");
    expect(result.errorMessage).toBe("copy failed");
  });

  it("closes tasks immediately and surfaces close failures", async () => {
    const state = createState({ backlog: [createTask("task-1")] });
    const handleKey = createKeyHandler("/tmp/project");

    let result = await handleKey("c", state, "/tmp/project");
    expect(result.flashTaskId).toBe("task-1");
    expect(result.needsRefresh).toBe(true);

    vi.mocked(boardApi.applyStatusChangeAsync).mockClear();
    vi.mocked(boardApi.closeTaskAsync).mockResolvedValueOnce("close failed");
    result = await handleKey("c", state, "/tmp/project");
    expect(result.errorMessage).toBe("close failed");
  });

  it("supports close-reason prompting", async () => {
    const state = createState({ backlog: [createTask("task-1")] });
    const handleKey = createKeyHandler("/tmp/project");

    const result = await handleKey("C", state, "/tmp/project");
    expect(result.promptForCloseReason).toBe(true);
  });

  it("creates tasks from the editor and reports create failures", async () => {
    const newTask = createTask("task-new");
    vi.mocked(boardApi.createTaskInEditor).mockResolvedValue(newTask);
    const handleKey = createKeyHandler("/tmp/project");

    let result = await handleKey("n", createState({}), "/tmp/project");
    expect(boardApi.createTaskAsync).toHaveBeenCalledWith("/tmp/project", newTask);
    expect(result.flashTaskId).toBe("task-new");
    expect(result.needsRefresh).toBe(true);

    vi.mocked(boardApi.createTaskAsync).mockResolvedValueOnce("create failed");
    result = await handleKey("n", createState({}), "/tmp/project");
    expect(result.errorMessage).toBe("create failed");
  });

  it("edits tasks and reports save failures", async () => {
    const task = createTask("task-1");
    vi.mocked(boardApi.editTaskInEditor).mockReturnValue(task);
    vi.mocked(boardApi.saveEditedTaskAsync).mockResolvedValueOnce(null);
    const handleKey = createKeyHandler("/tmp/project");

    let result = await handleKey("e", createState({ backlog: [task] }), "/tmp/project");
    expect(boardApi.saveEditedTaskAsync).toHaveBeenCalledWith("/tmp/project", "task-1", task);
    expect(result.flashTaskId).toBe("task-1");

    vi.mocked(boardApi.saveEditedTaskAsync).mockResolvedValueOnce("save failed");
    result = await handleKey("E", createState({ backlog: [task] }), "/tmp/project");
    expect(result.errorMessage).toBe("save failed");
  });

  it("ignores mutation keys when no task is highlighted", async () => {
    const empty = createState({});
    const handleKey = createKeyHandler("/tmp/project");

    for (const key of ["s", "S", "c", "C", "e", "E", "y", "R", "\r"]) {
      const result = await handleKey(key, empty, "/tmp/project");
      expect(result.errorMessage).toBeNull();
      expect(result.flashTaskId).toBeNull();
    }
  });

  it("toggles sort mode, refresh, and quit flags", async () => {
    const state = createState({});
    const handleKey = createKeyHandler("/tmp/project");

    let result = await handleKey("o", state, "/tmp/project");
    expect(result.sortMode).toBe("priority");

    result = await handleKey("r", state, "/tmp/project");
    expect(result.needsRefresh).toBe(true);

    result = await handleKey("q", state, "/tmp/project");
    expect(result.quit).toBe(true);
  });
});
