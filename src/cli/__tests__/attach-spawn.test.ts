import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { mockSpawn } = vi.hoisted(() => ({
  mockSpawn: vi.fn(),
}));

vi.mock("node:child_process", async () => {
  const actual = await vi.importActual<typeof import("node:child_process")>("node:child_process");
  return {
    ...actual,
    spawn: mockSpawn,
  };
});

function makeRun(overrides: Record<string, unknown> = {}) {
  return {
    id: "run-1",
    project_id: "project-1",
    task_id: "task-1",
    agent_type: "developer",
    session_key: null,
    worktree_path: "/tmp/worktree-1",
    status: "running",
    started_at: "2026-01-01T00:00:00.000Z",
    completed_at: null,
    created_at: "2026-01-01T00:00:00.000Z",
    progress: null,
    base_branch: null,
    merge_strategy: null,
    ...overrides,
  };
}

function makeChild() {
  const handlers = new Map<string, (value?: unknown) => void>();
  const child = {
    kill: vi.fn(),
    on: vi.fn((event: string, handler: (value?: unknown) => void) => {
      handlers.set(event, handler);
      return child;
    }),
    emit(event: string, value?: unknown) {
      handlers.get(event)?.(value);
    },
  };
  return child as any;
}

describe("attach spawn-backed paths", () => {
  let logSpy: ReturnType<typeof vi.spyOn>;
  let errorSpy: ReturnType<typeof vi.spyOn>;
  let processKillSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.resetModules();
    vi.clearAllMocks();
    logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    processKillSpy = vi.spyOn(process, "kill").mockImplementation(() => true as never);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("resumes SDK sessions with claude --resume", async () => {
    const child = makeChild();
    mockSpawn.mockReturnValue(child);
    const { attachAction } = await import("../commands/attach.js");
    const store = { getRun: vi.fn().mockReturnValue(makeRun({ session_key: "session-abc123" })) } as any;

    const promise = attachAction("run-1", {}, store, "/tmp/project");
    child.emit("exit", 0);

    await expect(promise).resolves.toBe(0);
    expect(mockSpawn).toHaveBeenCalledWith("claude", ["--resume", "abc123"], {
      cwd: "/tmp/worktree-1",
      stdio: "inherit",
    });
  });

  it("falls back to tailing the log file when no SDK session exists", async () => {
    const child = makeChild();
    mockSpawn.mockReturnValue(child);
    const { attachAction } = await import("../commands/attach.js");
    const store = { getRun: vi.fn().mockReturnValue(makeRun({ session_key: null })) } as any;

    const promise = attachAction("run-1", {}, store, "/tmp/project");
    child.emit("exit", 0);

    await expect(promise).resolves.toBe(0);
    expect(mockSpawn).toHaveBeenCalledWith("tail", ["-f", expect.stringContaining("run-1.out")], { stdio: "inherit" });
    expect(logSpy.mock.calls.some((call: unknown[]) => String(call[0]).includes("Tailing log file"))).toBe(true);
  });

  it("reports spawn errors when SDK resume cannot launch claude", async () => {
    const child = makeChild();
    mockSpawn.mockReturnValue(child);
    const { attachAction } = await import("../commands/attach.js");
    const store = { getRun: vi.fn().mockReturnValue(makeRun({ session_key: "session-sdk123" })) } as any;

    const promise = attachAction("run-1", {}, store, "/tmp/project");
    child.emit("error", new Error("claude missing"));

    await expect(promise).resolves.toBe(1);
    expect(errorSpy.mock.calls.some((call: unknown[]) => String(call[0]).includes("Failed to launch claude: claude missing"))).toBe(true);
    expect(errorSpy.mock.calls.some((call: unknown[]) => String(call[0]).includes("Ensure 'claude' CLI is installed"))).toBe(true);
  });

  it("reports spawn errors when follow mode cannot tail the log", async () => {
    const child = makeChild();
    mockSpawn.mockReturnValue(child);
    const { attachAction } = await import("../commands/attach.js");
    const store = { getRun: vi.fn().mockReturnValue(makeRun()) } as any;

    const promise = attachAction("run-1", { follow: true }, store, "/tmp/project");
    child.emit("error", new Error("tail missing"));

    await expect(promise).resolves.toBe(1);
    expect(errorSpy.mock.calls.some((call: unknown[]) => String(call[0]).includes("Failed to tail log file: tail missing"))).toBe(true);
  });

  it("terminates follow mode when aborted", async () => {
    const child = makeChild();
    mockSpawn.mockReturnValue(child);
    const { attachAction } = await import("../commands/attach.js");
    const controller = new AbortController();
    const store = { getRun: vi.fn().mockReturnValue(makeRun()) } as any;

    const promise = attachAction("run-1", { follow: true, _signal: controller.signal }, store, "/tmp/project");
    controller.abort();
    child.emit("exit", 0);

    await expect(promise).resolves.toBe(0);
    expect(child.kill).toHaveBeenCalledWith("SIGTERM");
  });

  it("treats non-SDK session metadata as a tail-log fallback", async () => {
    const child = makeChild();
    mockSpawn.mockReturnValue(child);
    const { attachAction } = await import("../commands/attach.js");
    const store = { getRun: vi.fn().mockReturnValue(makeRun({ session_key: "pid-4321" })) } as any;

    const promise = attachAction("run-1", {}, store, "/tmp/project");
    child.emit("exit", 0);

    await expect(promise).resolves.toBe(0);
    expect(mockSpawn).toHaveBeenCalledWith("tail", ["-f", expect.stringContaining("run-1.out")], { stdio: "inherit" });
    expect(logSpy.mock.calls.some((call: unknown[]) => String(call[0]).includes("No SDK session found. Tailing log file"))).toBe(true);
  });

  it("opens a shell in worktree mode", async () => {
    const child = makeChild();
    mockSpawn.mockReturnValue(child);
    const { attachAction } = await import("../commands/attach.js");
    const store = { getRun: vi.fn().mockReturnValue(makeRun({ worktree_path: "/tmp/wt" })) } as any;

    const promise = attachAction("run-1", { worktree: true }, store, "/tmp/project");
    child.emit("exit", 0);

    await expect(promise).resolves.toBe(0);
    expect(mockSpawn).toHaveBeenCalledWith(process.env.SHELL ?? "/bin/bash", [], {
      cwd: "/tmp/wt",
      stdio: "inherit",
    });
  });

  it("reports shell spawn errors in worktree mode", async () => {
    const child = makeChild();
    mockSpawn.mockReturnValue(child);
    const { attachAction } = await import("../commands/attach.js");
    const store = { getRun: vi.fn().mockReturnValue(makeRun({ worktree_path: "/tmp/wt" })) } as any;

    const promise = attachAction("run-1", { worktree: true }, store, "/tmp/project");
    child.emit("error", new Error("shell missing"));

    await expect(promise).resolves.toBe(1);
    expect(errorSpy.mock.calls.some((call: unknown[]) => String(call[0]).includes("Failed to launch shell"))).toBe(true);
  });

  it("kills local worker pids and marks active runs stuck", async () => {
    const { attachAction } = await import("../commands/attach.js");
    const store = {
      getRun: vi.fn().mockReturnValue(makeRun({ session_key: "pid-4321", status: "running" })),
      updateRun: vi.fn(),
    } as any;

    await expect(attachAction("run-1", { kill: true }, store, "/tmp/project")).resolves.toBe(0);
    expect(processKillSpy).toHaveBeenCalledWith(4321, "SIGTERM");
    expect(store.updateRun).toHaveBeenCalledWith("run-1", { status: "stuck" });
  });
});
