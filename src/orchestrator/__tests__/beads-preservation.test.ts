import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Module mocks ──────────────────────────────────────────────────────────────

vi.mock("node:child_process", () => ({
  execFile: vi.fn(),
}));

vi.mock("node:fs", () => ({
  writeFileSync: vi.fn(),
  unlinkSync: vi.fn(),
  existsSync: vi.fn(() => false),
  mkdirSync: vi.fn(),
  renameSync: vi.fn(),
}));

import { execFile } from "node:child_process";
import { writeFileSync, unlinkSync } from "node:fs";
import { preserveBeadChanges } from "../refinery.js";

function makeBackend() {
  return {
    applyPatchToIndex: vi.fn().mockResolvedValue(undefined),
    commit: vi.fn().mockResolvedValue(undefined),
  };
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function mockGitSuccess(responses: Record<string, string>) {
  (execFile as any).mockImplementation(
    (_cmd: string, args: string[], _opts: any, callback: Function) => {
      const key = args.join(" ");
      for (const [pattern, stdout] of Object.entries(responses)) {
        if (key.includes(pattern)) {
          callback(null, { stdout, stderr: "" });
          return;
        }
      }
      callback(null, { stdout: "", stderr: "" });
    },
  );
}

function mockGitSequence(results: Array<{ stdout?: string; error?: Error }>) {
  let callIndex = 0;
  (execFile as any).mockImplementation(
    (_cmd: string, _args: string[], _opts: any, callback: Function) => {
      const result = results[callIndex] ?? { stdout: "" };
      callIndex++;
      if (result.error) {
        const err = result.error as any;
        err.stdout = "";
        err.stderr = result.error.message;
        callback(err);
      } else {
        callback(null, { stdout: result.stdout ?? "", stderr: "" });
      }
    },
  );
}

// ── preserveBeadChanges() tests ───────────────────────────────────────────────

describe("preserveBeadChanges()", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("extracts .tasks/ changes and applies them to target", async () => {
    const patchContent = "diff --git a/.tasks/issues.jsonl b/.tasks/issues.jsonl\n+some bead data\n";
    const backend = makeBackend();

    mockGitSuccess({
      "diff main...foreman/task-abc -- .tasks/": patchContent,
      "commit -m": "",
    });

    const result = await preserveBeadChanges(
      "/tmp/project",
      "foreman/task-abc",
      "main",
      backend,
    );

    expect(result.preserved).toBe(true);
    expect(vi.mocked(writeFileSync)).toHaveBeenCalled();
    expect(backend.applyPatchToIndex).toHaveBeenCalledWith(
      "/tmp/project",
      expect.stringContaining(".foreman-task-patch-"),
    );
    expect(backend.commit).toHaveBeenCalledWith(
      "/tmp/project",
      "chore: preserve task changes from task-abc",
    );
  });

  it("does nothing when no .tasks/ changes exist", async () => {
    mockGitSuccess({
      "diff main...foreman/task-abc -- .tasks/": "",
    });

    const result = await preserveBeadChanges(
      "/tmp/project",
      "foreman/task-abc",
      "main",
    );

    expect(result.preserved).toBe(false);
    expect(result.error).toBeUndefined();
  });

  it("logs warning on patch failure but does not throw", async () => {
    const patchContent = "diff --git a/.tasks/issues.jsonl b/.tasks/issues.jsonl\n+data\n";
    const backend = {
      applyPatchToIndex: vi.fn().mockRejectedValue(new Error("patch does not apply")),
      commit: vi.fn().mockResolvedValue(undefined),
    };

    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        if (args.includes("diff")) {
          callback(null, { stdout: patchContent, stderr: "" });
          return;
        }
        callback(null, { stdout: "", stderr: "" });
      },
    );

    const result = await preserveBeadChanges(
      "/tmp/project",
      "foreman/task-fail",
      "main",
      backend,
    );

    expect(result.preserved).toBe(false);
    expect(result.error).toContain("patch does not apply");
  });

  it("always cleans up temp file even on failure", async () => {
    const patchContent = "diff --git a/.tasks/x b/.tasks/x\n+data\n";
    const backend = {
      applyPatchToIndex: vi.fn().mockRejectedValue(new Error("apply failed")),
      commit: vi.fn().mockResolvedValue(undefined),
    };

    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        if (args.includes("diff")) {
          callback(null, { stdout: patchContent, stderr: "" });
          return;
        }
        callback(null, { stdout: "", stderr: "" });
      },
    );

    await preserveBeadChanges("/tmp/project", "foreman/task-cleanup", "main", backend);

    // unlinkSync should be called for temp file cleanup
    expect(vi.mocked(unlinkSync)).toHaveBeenCalled();
  });

  it("preserves only .tasks/ directory changes", async () => {
    // The diff command should specifically filter to .tasks/
    const calls: string[][] = [];
    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        calls.push(args);
        callback(null, { stdout: "", stderr: "" });
      },
    );

    await preserveBeadChanges("/tmp/project", "foreman/task-only", "main");

    const diffCall = calls.find((c) => c.includes("diff"));
    expect(diffCall).toBeDefined();
    expect(diffCall).toContain(".tasks/");
  });
});
