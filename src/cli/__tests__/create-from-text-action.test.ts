import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const {
  mockEnsureBrInstalled,
  mockIsInitialized,
  mockCreate,
  mockAddDependency,
  mockExecFileSync,
  mockOraStart,
} = vi.hoisted(() => ({
  mockEnsureBrInstalled: vi.fn(),
  mockIsInitialized: vi.fn(),
  mockCreate: vi.fn(),
  mockAddDependency: vi.fn(),
  mockExecFileSync: vi.fn(),
  mockOraStart: vi.fn(),
}));

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: vi.fn().mockImplementation(function MockBeadsRustClient() {
    return {
      ensureBrInstalled: mockEnsureBrInstalled,
      isInitialized: mockIsInitialized,
      create: mockCreate,
      addDependency: mockAddDependency,
    };
  }),
}));

vi.mock("node:child_process", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  execFileSync: (...args: unknown[]) => mockExecFileSync(...args),
}));

vi.mock("ora", () => ({
  default: () => ({
    start: (...args: unknown[]) => mockOraStart(...args),
  }),
}));

import { createTasksFromText } from "../commands/create-from-text.js";

describe("createTasksFromText", () => {
  const tempDirs: string[] = [];
  let originalExitCode: string | number | null | undefined;

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-create-from-text-"));
    tempDirs.push(dir);
    return dir;
  }

  beforeEach(() => {
    vi.clearAllMocks();
    originalExitCode = process.exitCode;
    process.exitCode = undefined;
    mockEnsureBrInstalled.mockResolvedValue(undefined);
    mockIsInitialized.mockResolvedValue(true);
    mockCreate.mockResolvedValue({ id: "bd-1", title: "Created bead" });
    mockAddDependency.mockResolvedValue(undefined);
    mockOraStart.mockReturnValue({
      succeed: vi.fn(),
      fail: vi.fn(),
      warn: vi.fn(),
      text: "",
    });
    mockExecFileSync.mockImplementation((cmd: unknown) => {
      if (String(cmd) === "which") return "/opt/homebrew/bin/claude\n";
      return JSON.stringify({
        issues: [{ title: "Created bead", description: "desc", type: "task", priority: "P2" }],
      });
    });
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  afterEach(() => {
    process.exitCode = originalExitCode;
    for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
    tempDirs.length = 0;
    vi.restoreAllMocks();
  });

  it("sets exitCode when br is unavailable", async () => {
    mockEnsureBrInstalled.mockRejectedValue(new Error("br missing"));

    await createTasksFromText("do thing", { llm: false }, "/repo");

    expect(process.exitCode).toBe(1);
    expect(mockIsInitialized).not.toHaveBeenCalled();
    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("br missing");
  });

  it("sets exitCode when tasks are not initialized", async () => {
    mockIsInitialized.mockResolvedValue(false);

    await createTasksFromText("do thing", { llm: false }, "/repo");

    expect(process.exitCode).toBe(1);
    expect(mockCreate).not.toHaveBeenCalled();
    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Tasks not initialized");
  });

  it("reads description text from a file path and supports dry-run no-llm mode", async () => {
    const dir = makeTempDir();
    const inputPath = join(dir, "desc.txt");
    writeFileSync(inputPath, "Title from file\nMore details here");

    await createTasksFromText(inputPath, { llm: false, dryRun: true, type: "bug", priority: "P1" }, "/repo");

    expect(process.exitCode).toBeUndefined();
    expect(mockCreate).not.toHaveBeenCalled();
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Reading description from:");
    expect(rendered).toContain("Beads to create");
    expect(rendered).toContain("--dry-run: No beads were created.");
  });

  it("creates parsed issues and adds dependencies in a second pass", async () => {
    mockExecFileSync.mockImplementation((cmd: unknown) => {
      if (String(cmd) === "which") return "/opt/homebrew/bin/claude\n";
      return JSON.stringify({
        issues: [
          { title: "First", description: "one", type: "task", priority: "P2" },
          { title: "Second", description: "two", type: "bug", priority: "P1", dependencies: ["First"] },
        ],
      });
    });
    mockCreate
      .mockResolvedValueOnce({ id: "bd-1", title: "First" })
      .mockResolvedValueOnce({ id: "bd-2", title: "Second" });

    await createTasksFromText("multi issue description", { llm: true }, "/repo");

    expect(mockCreate).toHaveBeenNthCalledWith(1, "First", expect.objectContaining({ type: "task", priority: "P2" }));
    expect(mockCreate).toHaveBeenNthCalledWith(2, "Second", expect.objectContaining({ type: "bug", priority: "P1" }));
    expect(mockAddDependency).toHaveBeenCalledWith("bd-2", "bd-1");
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Created beads");
    expect(rendered).toContain("bd-1");
    expect(rendered).toContain("bd-2");
  });

  it("warns when a declared dependency title was not created", async () => {
    const spinnerWarn = vi.fn();
    mockOraStart.mockReturnValue({
      succeed: vi.fn(),
      fail: vi.fn(),
      warn: spinnerWarn,
      text: "",
    });
    mockExecFileSync.mockImplementation((cmd: unknown) => {
      if (String(cmd) === "which") return "/opt/homebrew/bin/claude\n";
      return JSON.stringify({
        issues: [
          { title: "Only", description: "one", dependencies: ["Missing"] },
        ],
      });
    });
    mockCreate.mockResolvedValueOnce({ id: "bd-1", title: "Only" });

    await createTasksFromText("single issue with missing dep", { llm: true }, "/repo");

    expect(mockAddDependency).not.toHaveBeenCalled();
    expect(spinnerWarn).toHaveBeenCalledWith(expect.stringContaining('dependency "Missing"'));
  });

  it("sets exitCode and reports already-created beads when creation fails midway", async () => {
    mockExecFileSync.mockImplementation((cmd: unknown) => {
      if (String(cmd) === "which") return "/opt/homebrew/bin/claude\n";
      return JSON.stringify({
        issues: [
          { title: "First" },
          { title: "Second" },
        ],
      });
    });
    mockCreate
      .mockResolvedValueOnce({ id: "bd-1", title: "First" })
      .mockRejectedValueOnce(new Error("create failed"));

    await createTasksFromText("multi issue description", { llm: true }, "/repo");

    expect(process.exitCode).toBe(1);
    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("create failed");
    expect(rendered).toContain("Beads created before failure");
    expect(rendered).toContain("bd-1");
  });
});
