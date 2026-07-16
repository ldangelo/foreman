import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => {
  const mockSpawnSync = vi.fn();
  const mockExistsSync = vi.fn();
  const mockReaddirSync = vi.fn();
  const mockStatSync = vi.fn();
  const mockForemanHomePath = vi.fn((...segments: string[]) => `/mock/home/${segments.join("/")}`);
  return {
    mockSpawnSync,
    mockExistsSync,
    mockReaddirSync,
    mockStatSync,
    mockForemanHomePath,
  };
});

vi.mock("node:child_process", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  spawnSync: mocks.mockSpawnSync,
}));

vi.mock("node:fs", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  existsSync: mocks.mockExistsSync,
  readdirSync: mocks.mockReaddirSync,
  statSync: mocks.mockStatSync,
}));

vi.mock("../../lib/paths.js", () => ({
  foremanHomePath: mocks.mockForemanHomePath,
}));

import type { InboxTaskSummary } from "../commands/inbox.js";

function createSummary(overrides: Partial<InboxTaskSummary> = {}): InboxTaskSummary {
  return {
    taskId: "task-123",
    runId: "run-456",
    runStatus: "running",
    phase: "developer",
    lastActivityAt: "2026-01-01T00:00:00.000Z",
    lastActivitySource: "message",
    statusText: "running",
    attention: false,
    attentionReason: null,
    verdict: "unknown",
    projectId: "proj-abc",
    worktreePath: "/tmp/worktree",
    messages: [],
    events: [],
    ...overrides,
  };
}

function createDirEntry(name: string): { name: string; isDirectory: () => boolean; isFile: () => boolean } {
  return { name, isDirectory: () => true, isFile: () => false };
}

function createFileEntry(name: string, _mtimeMs: number, _size = 1024): { name: string; isFile: () => boolean; isDirectory: () => boolean } {
  return { name, isFile: () => true, isDirectory: () => false };
}

describe("selectReportInteractive", () => {
  const originalEnv = { ...process.env };

  beforeEach(() => {
    vi.clearAllMocks();
    vi.resetModules();
    process.env = { ...originalEnv };
    process.env.EDITOR = "vim";
    mocks.mockExistsSync.mockReturnValue(false);
    mocks.mockReaddirSync.mockReturnValue([]);
    mocks.mockStatSync.mockReturnValue({ mtimeMs: Date.now(), size: 1024 } as never);
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  async function importAndRunSelectReport(summary: InboxTaskSummary, readlineInput: string): Promise<void> {
    // Set up readline mock before importing
    const rlClose = vi.fn();
    const rlQuestion = vi.fn((_: string, cb: (answer: string) => void) => {
      // Simulate async user input
      setTimeout(() => cb(readlineInput), 0);
    });

    vi.doMock("readline", () => ({
      createInterface: vi.fn(() => ({
        close: rlClose,
        question: rlQuestion,
      })),
    }));

    const { selectReportInteractive } = await import("../commands/inbox.js");
    await selectReportInteractive(summary);
  }

  describe("report directory discovery", () => {
    it("prints warning when no report directory exists", async () => {
      const consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      mocks.mockExistsSync.mockReturnValue(false);

      await importAndRunSelectReport(createSummary(), "");

      expect(consoleLogSpy).toHaveBeenCalledWith(expect.stringContaining("No report directory found"));
      expect(mocks.mockSpawnSync).not.toHaveBeenCalled();
      consoleLogSpy.mockRestore();
    });

    it("prints warning when report directory has no files", async () => {
      const consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      mocks.mockExistsSync.mockReturnValue(true);
      mocks.mockReaddirSync.mockReturnValue([]);

      await importAndRunSelectReport(createSummary(), "");

      expect(consoleLogSpy).toHaveBeenCalledWith(expect.stringContaining("No report files found"));
      expect(mocks.mockSpawnSync).not.toHaveBeenCalled();
      consoleLogSpy.mockRestore();
    });

    it("lists checked directories when projectId is provided but dir does not exist", async () => {
      const consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      mocks.mockExistsSync.mockReturnValue(false);

      await importAndRunSelectReport(createSummary({ projectId: "proj-x" }), "");

      expect(consoleLogSpy).toHaveBeenCalledWith("Checked directories:");
      expect(mocks.mockSpawnSync).not.toHaveBeenCalled();
      consoleLogSpy.mockRestore();
    });
  });

  describe("file listing and ordering", () => {
    it("lists files sorted by modification time (newest first)", async () => {
      const consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const now = Date.now();
      mocks.mockExistsSync.mockReturnValue(true);
      mocks.mockReaddirSync.mockImplementation((path: unknown) => {
        const p = path as string;
        if (p.includes("reports") && p.endsWith("reports")) {
          return [createDirEntry("proj-abc")];
        }
        if (p.includes("task-123")) {
          return [
            createFileEntry("old-report.md", now - 10000),
            createFileEntry("new-report.md", now),
            createFileEntry("middle-report.md", now - 5000),
          ];
        }
        return [];
      });
      mocks.mockStatSync.mockImplementation((path: string) => {
        const name = path.split("/").pop()!;
        const mtimes: Record<string, number> = {
          "old-report.md": now - 10000,
          "new-report.md": now,
          "middle-report.md": now - 5000,
        };
        return { mtimeMs: mtimes[name] ?? now, size: 1024 } as never;
      });

      await importAndRunSelectReport(createSummary(), "");

      const logCalls = consoleLogSpy.mock.calls.map((c) => c.join(" ")).join("\n");
      const newIdx = logCalls.indexOf("new-report.md");
      const middleIdx = logCalls.indexOf("middle-report.md");
      const oldIdx = logCalls.indexOf("old-report.md");
      expect(newIdx).toBeLessThan(middleIdx);
      expect(middleIdx).toBeLessThan(oldIdx);
      consoleLogSpy.mockRestore();
    });

    it("shows file size next to each file", async () => {
      const consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      mocks.mockExistsSync.mockReturnValue(true);
      mocks.mockReaddirSync.mockImplementation((path: unknown) => {
        const p = path as string;
        if (p.includes("reports") && p.endsWith("reports")) {
          return [createDirEntry("proj-abc")];
        }
        if (p.includes("task-123")) {
          return [createFileEntry("small.md", Date.now(), 512)];
        }
        return [];
      });
      mocks.mockStatSync.mockReturnValue({ mtimeMs: Date.now(), size: 512 } as never);

      await importAndRunSelectReport(createSummary(), "");

      expect(consoleLogSpy).toHaveBeenCalledWith(expect.stringContaining("KB"));
      consoleLogSpy.mockRestore();
    });
  });

  describe("user input handling", () => {
    beforeEach(() => {
      const now = Date.now();
      mocks.mockExistsSync.mockReturnValue(true);
      mocks.mockReaddirSync.mockImplementation((path: unknown) => {
        const p = path as string;
        if (p.includes("reports") && p.endsWith("reports")) {
          return [createDirEntry("proj-abc")];
        }
        if (p.includes("task-123")) {
          return [
            createFileEntry("report-a.md", now),
            createFileEntry("report-b.md", now - 1000),
          ];
        }
        return [];
      });
      mocks.mockStatSync.mockReturnValue({ mtimeMs: Date.now(), size: 1024 } as never);
    });

    it("cancels when user presses Enter without a selection", async () => {
      const consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      await importAndRunSelectReport(createSummary(), "");

      await new Promise((r) => setTimeout(r, 20));

      expect(consoleLogSpy).toHaveBeenCalledWith(expect.stringContaining("Cancelled"));
      expect(mocks.mockSpawnSync).not.toHaveBeenCalled();
      consoleLogSpy.mockRestore();
    });

    it("rejects out-of-bounds numeric selection", async () => {
      const consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      await importAndRunSelectReport(createSummary(), "99");

      await new Promise((r) => setTimeout(r, 20));

      expect(consoleLogSpy).toHaveBeenCalledWith(expect.stringContaining("Invalid selection"));
      expect(mocks.mockSpawnSync).not.toHaveBeenCalled();
      consoleLogSpy.mockRestore();
    });

    it("rejects non-numeric input", async () => {
      const consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      await importAndRunSelectReport(createSummary(), "abc");

      await new Promise((r) => setTimeout(r, 20));

      expect(consoleLogSpy).toHaveBeenCalledWith(expect.stringContaining("Invalid selection"));
      expect(mocks.mockSpawnSync).not.toHaveBeenCalled();
      consoleLogSpy.mockRestore();
    });

    it("rejects zero and negative numbers", async () => {
      const consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      await importAndRunSelectReport(createSummary(), "-1");

      await new Promise((r) => setTimeout(r, 20));

      expect(consoleLogSpy).toHaveBeenCalledWith(expect.stringContaining("Invalid selection"));
      expect(mocks.mockSpawnSync).not.toHaveBeenCalled();
      consoleLogSpy.mockRestore();
    });
  });

  describe("editor launch", () => {
    beforeEach(() => {
      mocks.mockSpawnSync.mockReturnValue({ status: 0 });
      mocks.mockExistsSync.mockReturnValue(true);
      mocks.mockReaddirSync.mockImplementation((path: unknown) => {
        const p = path as string;
        if (p.includes("reports") && p.endsWith("reports")) {
          return [createDirEntry("proj-abc")];
        }
        if (p.includes("task-123")) {
          return [createFileEntry("report.md", Date.now())];
        }
        return [];
      });
      mocks.mockStatSync.mockReturnValue({ mtimeMs: Date.now(), size: 1024 } as never);
    });

    it("launches editor with selected file path without shell", async () => {
      await importAndRunSelectReport(createSummary(), "1");

      await new Promise((r) => setTimeout(r, 20));

      expect(mocks.mockSpawnSync).toHaveBeenCalledWith(
        "vim",
        expect.arrayContaining([expect.stringContaining("report.md")]),
        expect.not.objectContaining({ shell: true })
      );
    });

    it("reports non-zero exit code from editor", async () => {
      mocks.mockSpawnSync.mockReturnValue({ status: 42 });
      const consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      await importAndRunSelectReport(createSummary(), "1");

      await new Promise((r) => setTimeout(r, 20));

      expect(consoleLogSpy).toHaveBeenCalledWith(expect.stringContaining("exited with code 42"));
      consoleLogSpy.mockRestore();
    });

    it("passes correct file path to editor", async () => {
      await importAndRunSelectReport(createSummary(), "1");

      await new Promise((r) => setTimeout(r, 20));

      const callArgs = mocks.mockSpawnSync.mock.calls[0];
      const filePath = callArgs[1][0];
      expect(filePath).toContain("report.md");
    });
  });

  describe("with both task and run flows", () => {
    beforeEach(() => {
      mocks.mockSpawnSync.mockReturnValue({ status: 0 });
      mocks.mockExistsSync.mockReturnValue(true);
      mocks.mockReaddirSync.mockImplementation((path: unknown) => {
        const p = path as string;
        if (p.includes("reports") && p.endsWith("reports")) {
          return [createDirEntry("proj-abc")];
        }
        if (p.includes("task-abc")) {
          return [createFileEntry("report.md", Date.now())];
        }
        return [];
      });
      mocks.mockStatSync.mockReturnValue({ mtimeMs: Date.now(), size: 1024 } as never);
    });

    it("works when taskId and runId are provided", async () => {
      await importAndRunSelectReport(createSummary({ taskId: "task-abc", runId: "run-xyz" }), "1");

      await new Promise((r) => setTimeout(r, 20));

      // Verify that the report dir was accessed (the second call)
      const calls = mocks.mockReaddirSync.mock.calls;
      const reportDirCall = calls.find((c) => typeof c[0] === "string" && c[0].includes("task-abc"));
      expect(reportDirCall).toBeDefined();
      expect(reportDirCall![0]).toContain("task-abc");
      expect(reportDirCall![0]).toContain("run-xyz");
      expect(mocks.mockSpawnSync).toHaveBeenCalled();
    });

    it("handles summary without projectId", async () => {
      const consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      mocks.mockExistsSync.mockReturnValue(false);

      await importAndRunSelectReport(createSummary({ projectId: null }), "");

      expect(consoleLogSpy).toHaveBeenCalledWith(expect.stringContaining("No report directory found"));
      expect(mocks.mockSpawnSync).not.toHaveBeenCalled();
      consoleLogSpy.mockRestore();
    });
  });
});
