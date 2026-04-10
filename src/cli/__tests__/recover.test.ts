import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { recoverAction, type RecoverActionDeps } from "../commands/recover.js";
import type { Message, Run } from "../../lib/store.js";

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-12345678",
    project_id: "proj-1",
    seed_id: "bd-123",
    agent_type: "anthropic/claude-opus-4-6",
    session_key: null,
    worktree_path: "/tmp/worktree",
    status: "failed",
    started_at: "2026-04-10T12:00:00.000Z",
    completed_at: "2026-04-10T12:10:00.000Z",
    created_at: "2026-04-10T12:00:00.000Z",
    progress: null,
    ...overrides,
  };
}

function makeMessage(overrides: Partial<Message> = {}): Message {
  return {
    id: "msg-1",
    run_id: "run-12345678",
    sender_agent_type: "developer",
    recipient_agent_type: "foreman",
    subject: "handoff",
    body: "Recovered enough context",
    read: 0,
    created_at: "2026-04-10T12:05:00.000Z",
    deleted_at: null,
    ...overrides,
  };
}

function captureConsole() {
  const stdout: string[] = [];
  const stderr: string[] = [];

  const logSpy = vi.spyOn(console, "log").mockImplementation((...args: unknown[]) => {
    stdout.push(args.join(" "));
  });
  const errorSpy = vi.spyOn(console, "error").mockImplementation((...args: unknown[]) => {
    stderr.push(args.join(" "));
  });
  const warnSpy = vi.spyOn(console, "warn").mockImplementation((...args: unknown[]) => {
    stderr.push(args.join(" "));
  });

  return {
    stdout,
    stderr,
    restore() {
      logSpy.mockRestore();
      errorSpy.mockRestore();
      warnSpy.mockRestore();
    },
  };
}

describe("recoverAction truthfulness", () => {
  let tempRoot: string;
  let projectPath: string;
  let worktreePath: string;
  let previousHome: string | undefined;

  beforeEach(() => {
    tempRoot = mkdtempSync(join(tmpdir(), "foreman-recover-test-"));
    projectPath = join(tempRoot, "repo");
    worktreePath = join(tempRoot, "worktree");
    mkdirSync(projectPath, { recursive: true });
    mkdirSync(worktreePath, { recursive: true });
    mkdirSync(join(tempRoot, ".foreman", "logs"), { recursive: true });
    writeFileSync(join(worktreePath, "DEVELOPER_REPORT.md"), "# Developer report\ncontext\n");
    writeFileSync(join(tempRoot, ".foreman", "logs", "run-12345678.log"), "worker log line\n");
    previousHome = process.env.HOME;
    process.env.HOME = tempRoot;
  });

  afterEach(() => {
    if (previousHome === undefined) {
      delete process.env.HOME;
    } else {
      process.env.HOME = previousHome;
    }
    rmSync(tempRoot, { recursive: true, force: true });
    vi.restoreAllMocks();
  });

  function makeDeps(runCommand: RecoverActionDeps["runCommand"], overrides: Partial<RecoverActionDeps> = {}): RecoverActionDeps {
    return {
      createVcs: (vi.fn(async () => ({
        getRepoRoot: vi.fn(async () => projectPath),
      })) as unknown) as RecoverActionDeps["createVcs"],
      createStore: vi.fn(() => ({
        getRunsForSeed: vi.fn(() => [makeRun({ worktree_path: worktreePath })]),
        getRunProgress: vi.fn(() => null),
        getAllMessages: vi.fn(() => [makeMessage()]),
        close: vi.fn(),
      })),
      runCommand,
      loadPrompt: vi.fn(() => "PROMPT"),
      getModel: vi.fn(() => "mock-model"),
      getBranchName: vi.fn(() => "foreman/bd-123"),
      ...overrides,
    };
  }

  it("tells the truth in raw mode without claiming recovery success", async () => {
    const runRecoveryAgent = vi.fn();
    const consoleCapture = captureConsole();
    const deps = makeDeps((args) => {
      if (args[0] === "br" && args[1] === "show") {
        return { ok: true, output: "bead info", status: 0 };
      }
      if (args[0] === "br" && args[1] === "list") {
        return { ok: true, output: "bd-999 blocked", status: 0 };
      }
      if (args[0] === "git") {
        return { ok: true, output: "abc123 fix", status: 0 };
      }
      throw new Error(`Unexpected command: ${args.join(" ")}`);
    }, {
      runRecoveryAgent,
    });

    try {
      const exitCode = await recoverAction("bd-123", { reason: "stuck", raw: true }, deps);

      expect(exitCode).toBe(0);
      expect(runRecoveryAgent).not.toHaveBeenCalled();
      expect(consoleCapture.stdout.join("\n")).toContain("─── Run Summary ───");
      expect(consoleCapture.stdout.join("\n")).not.toContain("Recovery complete");
      expect(consoleCapture.stdout.join("\n")).not.toContain("Raw recovery context emitted");
      expect(consoleCapture.stderr.join("\n")).toContain("Raw recovery context emitted; recovery agent was not invoked.");
      expect(consoleCapture.stderr.join("\n")).not.toContain("Recovery complete");
    } finally {
      consoleCapture.restore();
    }
  });

  it("returns non-zero when AI ran on degraded collection instead of claiming clean success", async () => {
    const consoleCapture = captureConsole();
    const runRecoveryAgent = vi.fn(async () => ({
      success: true,
      costUsd: 0.25,
      turns: 1,
      toolCalls: 1,
      toolBreakdown: { Read: 1 },
      tokensIn: 10,
      tokensOut: 20,
      outputText: "Applied a recovery fix",
    }));
    const deps = makeDeps((args) => {
      if (args[0] === "br" && args[1] === "show") {
        return { ok: false, output: "br unavailable", status: 1, error: "exit 1" };
      }
      if (args[0] === "br" && args[1] === "list") {
        return { ok: true, output: "", status: 0 };
      }
      if (args[0] === "git") {
        return { ok: true, output: "abc123 fix", status: 0 };
      }
      throw new Error(`Unexpected command: ${args.join(" ")}`);
    }, {
      runRecoveryAgent,
    });

    try {
      const exitCode = await recoverAction(
        "bd-123",
        { reason: "stuck", output: "captured already" },
        deps,
      );

      expect(exitCode).toBe(1);
      expect(runRecoveryAgent).toHaveBeenCalledTimes(1);
      expect(consoleCapture.stdout.join("\n")).toContain("Applied a recovery fix");
      expect(consoleCapture.stderr.join("\n")).toContain("Recovery context is degraded:");
      expect(consoleCapture.stderr.join("\n")).toContain("Invoking mock-model with degraded recovery context");
      expect(consoleCapture.stderr.join("\n")).toContain("Recovery agent completed, but context collection was degraded ($0.2500)");
      expect(consoleCapture.stderr.join("\n")).not.toContain("Recovery complete ($0.2500)");
    } finally {
      consoleCapture.restore();
    }
  });
});
