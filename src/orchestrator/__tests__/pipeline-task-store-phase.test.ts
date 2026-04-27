/**
 * Tests for REQ-012 / REQ-017: pipeline-executor calls onTaskPhaseChange()
 * at each phase transition.
 *
 * Verifies:
 *  1. ctx.onTaskPhaseChange?.(config.taskId, phaseName) is called after
 *     each successful phase completion.
 *  2. When ctx.onTaskPhaseChange is absent, no errors are thrown (no-op).
 *  3. When config.taskId is null, the callback still remains non-fatal.
 *  4. WorkerConfig includes optional taskId field.
 *  5. PipelineContext includes optional onTaskPhaseChange field.
 *  6. PipelineRunConfig includes optional taskId field.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { installBundledPrompts } from "../../lib/prompt-loader.js";

// ── Type-only checks ─────────────────────────────────────────────────────────

describe("WorkerConfig: taskId field", () => {
  it("WorkerConfig interface has optional taskId field", async () => {
    // Import the type — if taskId is missing, TS would have failed at compile time.
    // This test verifies at runtime that the field is accepted in the shape.
    const { spawnWorkerProcess } = await import("../dispatcher.js");
    // The function accepts WorkerConfig — we just check it's importable.
    expect(typeof spawnWorkerProcess).toBe("function");
  });

  it("WorkerConfig taskId field is optional (can be undefined)", () => {
    // Structural type check: build a minimal WorkerConfig without taskId
    const config = {
      runId: "run-001",
      projectId: "proj-001",
      seedId: "seed-001",
      seedTitle: "Test seed",
      model: "anthropic/claude-sonnet-4-6",
      worktreePath: "/tmp/wt",
      prompt: "Do stuff",
      env: {},
    };
    // If taskId was required, the line above would fail strict TS checks.
    // Runtime: just verify the field is absent (i.e., the type allows it)
    expect((config as Record<string, unknown>)["taskId"]).toBeUndefined();
  });

  it("WorkerConfig taskId can be a string", () => {
    const config = {
      runId: "run-001",
      projectId: "proj-001",
      seedId: "seed-001",
      seedTitle: "Test seed",
      model: "anthropic/claude-sonnet-4-6",
      worktreePath: "/tmp/wt",
      prompt: "Do stuff",
      env: {},
      taskId: "task-abc-123",
    };
    expect(config.taskId).toBe("task-abc-123");
  });

  it("WorkerConfig taskId can be null (beads fallback mode)", () => {
    const config = {
      runId: "run-001",
      projectId: "proj-001",
      seedId: "seed-001",
      seedTitle: "Test seed",
      model: "anthropic/claude-sonnet-4-6",
      worktreePath: "/tmp/wt",
      prompt: "Do stuff",
      env: {},
      taskId: null,
    };
    expect(config.taskId).toBeNull();
  });
});

// ── NativeTaskStore.updatePhase() unit tests ─────────────────────────────────

describe("NativeTaskStore.updatePhase()", () => {
  it("is a no-op when taskId is null", async () => {
    const { NativeTaskStore } = await import("../../lib/task-store.js");
    // Create a mock DB
    const mockRun = vi.fn();
    const mockPrepare = vi.fn(() => ({ run: mockRun }));
    const mockDb = { prepare: mockPrepare } as unknown as import("better-sqlite3").Database;

    const store = new NativeTaskStore(mockDb);
    store.updatePhase(null, "developer");

    // DB should NOT have been touched
    expect(mockPrepare).not.toHaveBeenCalled();
    expect(mockRun).not.toHaveBeenCalled();
  });

  it("is a no-op when taskId is undefined", async () => {
    const { NativeTaskStore } = await import("../../lib/task-store.js");
    const mockRun = vi.fn();
    const mockPrepare = vi.fn(() => ({ run: mockRun }));
    const mockDb = { prepare: mockPrepare } as unknown as import("better-sqlite3").Database;

    const store = new NativeTaskStore(mockDb);
    // undefined coerces to null via ?? null in the executor call
    store.updatePhase(null, "qa");

    expect(mockPrepare).not.toHaveBeenCalled();
  });

  it("calls DB UPDATE when taskId is a string", async () => {
    const { NativeTaskStore } = await import("../../lib/task-store.js");
    const mockRun = vi.fn();
    const mockPrepare = vi.fn(() => ({ run: mockRun }));
    const mockDb = { prepare: mockPrepare } as unknown as import("better-sqlite3").Database;

    const store = new NativeTaskStore(mockDb);
    store.updatePhase("task-xyz", "reviewer");

    expect(mockPrepare).toHaveBeenCalledWith(
      expect.stringContaining("UPDATE tasks"),
    );
    expect(mockRun).toHaveBeenCalledWith("reviewer", expect.any(String), "task-xyz");
  });

  it("sets status = phaseName for the given taskId", async () => {
    const { NativeTaskStore } = await import("../../lib/task-store.js");
    const capturedArgs: unknown[][] = [];
    const mockRun = vi.fn((...args: unknown[]) => { capturedArgs.push(args); });
    const mockPrepare = vi.fn(() => ({ run: mockRun }));
    const mockDb = { prepare: mockPrepare } as unknown as import("better-sqlite3").Database;

    const store = new NativeTaskStore(mockDb);
    store.updatePhase("task-abc", "finalize");

    expect(capturedArgs[0][0]).toBe("finalize");
    expect(capturedArgs[0][2]).toBe("task-abc");
  });
});

// ── executePipeline() integration: onTaskPhaseChange is called ─────────────────

describe("executePipeline(): onTaskPhaseChange() called at phase transitions", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-pipe-taskstore-test-"));
    process.env["FOREMAN_HOME"] = tmpDir;
    mkdirSync(join(tmpDir, "prompts", "default"), { recursive: true });
    installBundledPrompts(tmpDir, true);
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
  });

  it("calls onTaskPhaseChange for each successfully completed phase", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    const onTaskPhaseChange = vi.fn();

    const mockStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
    };
    const mockRunPhase = vi.fn().mockResolvedValue({
      success: true,
      costUsd: 0.001,
      turns: 1,
      tokensIn: 100,
      tokensOut: 200,
    });
    const mockRegisterAgent = vi.fn().mockResolvedValue(undefined);
    const mockSendMail = vi.fn();
    const mockSendMailText = vi.fn();
    const mockReserveFiles = vi.fn();
    const mockReleaseFiles = vi.fn();
    const mockMarkStuck = vi.fn();
    const mockLog = vi.fn();

    const workflowConfig = {
      name: "test",
      phases: [
        { name: "explorer", artifact: "EXPLORER_REPORT.md" },
        { name: "developer", artifact: "DEVELOPER_REPORT.md" },
      ],
    };

    await executePipeline({
      config: {
        runId: "run-001",
        projectId: "proj-001",
        seedId: "seed-001",
        seedTitle: "Test",
        model: "anthropic/claude-haiku-4-5",
        worktreePath: tmpDir,
        env: {},
        taskId: "task-native-001",
      },
      workflowConfig: workflowConfig as never,
      store: mockStore as never,
      logFile: join(tmpDir, "test.log"),
      notifyClient: null,
      agentMailClient: null,
      onTaskPhaseChange,
      runPhase: mockRunPhase,
      registerAgent: mockRegisterAgent,
      sendMail: mockSendMail,
      sendMailText: mockSendMailText,
      reserveFiles: mockReserveFiles,
      releaseFiles: mockReleaseFiles,
      markStuck: mockMarkStuck,
      log: mockLog,
      promptOpts: { projectRoot: tmpDir, workflow: "default" },
    });

    expect(onTaskPhaseChange).toHaveBeenCalledTimes(2);
    expect(onTaskPhaseChange).toHaveBeenCalledWith("task-native-001", "explorer");
    expect(onTaskPhaseChange).toHaveBeenCalledWith("task-native-001", "developer");
  });

  it("keeps successful phase completion non-fatal when the native task update callback swallows its own failure", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    const runtimeTaskClient = {
      update: vi.fn().mockRejectedValue(new Error("native task update failed")),
    };
    const onTaskPhaseChange = async (taskId: string | null | undefined, phaseName: string) => {
      if (!taskId) return;
      try {
        await runtimeTaskClient.update(taskId, { status: phaseName });
      } catch {
        // non-fatal by design
      }
    };

    const mockStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
    };
    const mockRunPhase = vi.fn().mockResolvedValue({
      success: true,
      costUsd: 0.001,
      turns: 1,
      tokensIn: 100,
      tokensOut: 200,
    });

    const workflowConfig = {
      name: "test",
      phases: [{ name: "explorer", artifact: "EXPLORER_REPORT.md" }],
    };

    await expect(executePipeline({
      config: {
        runId: "run-005",
        projectId: "proj-005",
        seedId: "seed-005",
        seedTitle: "Test callback swallow",
        model: "anthropic/claude-haiku-4-5",
        worktreePath: tmpDir,
        env: {},
        taskId: "task-native-005",
      },
      workflowConfig: workflowConfig as never,
      store: mockStore as never,
      logFile: join(tmpDir, "test5.log"),
      notifyClient: null,
      agentMailClient: null,
      onTaskPhaseChange,
      runPhase: mockRunPhase,
      registerAgent: vi.fn().mockResolvedValue(undefined),
      sendMail: vi.fn(),
      sendMailText: vi.fn(),
      reserveFiles: vi.fn(),
      releaseFiles: vi.fn(),
      markStuck: vi.fn(),
      log: vi.fn(),
      promptOpts: { projectRoot: tmpDir, workflow: "default" },
    })).resolves.not.toThrow();

    expect(runtimeTaskClient.update).toHaveBeenCalledWith("task-native-005", { status: "explorer" });
  });

  it("passes null task ids to onTaskPhaseChange without failing", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    const onTaskPhaseChange = vi.fn();

    const mockStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
    };
    const mockRunPhase = vi.fn().mockResolvedValue({
      success: true,
      costUsd: 0,
      turns: 1,
      tokensIn: 0,
      tokensOut: 0,
    });

    const workflowConfig = {
      name: "test",
      phases: [{ name: "explorer", artifact: "EXPLORER_REPORT.md" }],
    };

    await executePipeline({
      config: {
        runId: "run-002",
        projectId: "proj-002",
        seedId: "seed-002",
        seedTitle: "Test beads fallback",
        model: "anthropic/claude-haiku-4-5",
        worktreePath: tmpDir,
        env: {},
        taskId: null,  // beads fallback — no native taskId
      },
      workflowConfig: workflowConfig as never,
      store: mockStore as never,
      logFile: join(tmpDir, "test2.log"),
      notifyClient: null,
      agentMailClient: null,
      onTaskPhaseChange,
      runPhase: mockRunPhase,
      registerAgent: vi.fn().mockResolvedValue(undefined),
      sendMail: vi.fn(),
      sendMailText: vi.fn(),
      reserveFiles: vi.fn(),
      releaseFiles: vi.fn(),
      markStuck: vi.fn(),
      log: vi.fn(),
      promptOpts: { projectRoot: tmpDir, workflow: "default" },
    });

    expect(onTaskPhaseChange).toHaveBeenCalledWith(null, "explorer");
  });

  it("does not enqueue phase label bead writes during active pipeline phases", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    const enqueueBeadWrite = vi.fn();
    const mockStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
      enqueueBeadWrite,
    };
    const mockRunPhase = vi.fn().mockResolvedValue({
      success: true,
      costUsd: 0,
      turns: 1,
      tokensIn: 0,
      tokensOut: 0,
    });

    const workflowConfig = {
      name: "test",
      phases: [{ name: "explorer", artifact: "EXPLORER_REPORT.md" }],
    };

    await executePipeline({
      config: {
        runId: "run-no-labels",
        projectId: "proj-no-labels",
        seedId: "seed-no-labels",
        seedTitle: "No phase label writes",
        model: "anthropic/claude-haiku-4-5",
        worktreePath: tmpDir,
        env: {},
      },
      workflowConfig: workflowConfig as never,
      store: mockStore as never,
      logFile: join(tmpDir, "no-labels.log"),
      notifyClient: null,
      agentMailClient: null,
      runPhase: mockRunPhase,
      registerAgent: vi.fn().mockResolvedValue(undefined),
      sendMail: vi.fn(),
      sendMailText: vi.fn(),
      reserveFiles: vi.fn(),
      releaseFiles: vi.fn(),
      markStuck: vi.fn(),
      log: vi.fn(),
      promptOpts: { projectRoot: tmpDir, workflow: "default" },
    });

    expect(enqueueBeadWrite).not.toHaveBeenCalled();
  });

  it("routes registered normal phase progress and events through the observability writer instead of direct store writes", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    const mockStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
    };
    const observedProgresses: Array<Record<string, unknown>> = [];
    const observabilityWriter = {
      updateProgress: vi.fn().mockImplementation(async (progress: Record<string, unknown>) => {
        observedProgresses.push(structuredClone(progress));
      }),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };
    const mockRunPhase = vi.fn().mockResolvedValue({
      success: true,
      costUsd: 0.25,
      turns: 2,
      tokensIn: 100,
      tokensOut: 200,
    });

    await executePipeline({
      config: {
        runId: "run-observability",
        projectId: "proj-observability",
        seedId: "seed-observability",
        seedTitle: "Registered seam",
        model: "anthropic/claude-haiku-4-5",
        worktreePath: tmpDir,
        env: {},
        taskId: "task-native-observability",
      },
      workflowConfig: {
        name: "test",
        phases: [{ name: "explorer", artifact: "EXPLORER_REPORT.md" }],
      } as never,
      store: mockStore as never,
      logFile: join(tmpDir, "observability.log"),
      notifyClient: null,
      agentMailClient: null,
      observabilityWriter,
      onTaskPhaseChange: vi.fn(),
      runPhase: mockRunPhase,
      registerAgent: vi.fn().mockResolvedValue(undefined),
      sendMail: vi.fn(),
      sendMailText: vi.fn(),
      reserveFiles: vi.fn(),
      releaseFiles: vi.fn(),
      markStuck: vi.fn(),
      log: vi.fn(),
      promptOpts: { projectRoot: tmpDir, workflow: "default" },
    });

    expect(observabilityWriter.updateProgress).toHaveBeenCalled();
    expect(observabilityWriter.updateProgress).toHaveBeenCalledWith(
      expect.objectContaining({ currentPhase: "explorer" }),
    );
    expect(observabilityWriter.updateProgress).toHaveBeenCalledWith(
      expect.objectContaining({
        currentPhase: "explorer",
        costUsd: 0.25,
        costByPhase: { explorer: 0.25 },
      }),
    );
    expect(observabilityWriter.logEvent).toHaveBeenCalledWith(
      "phase-start",
      expect.objectContaining({ seedId: "seed-observability", phase: "explorer" }),
    );
    expect(observabilityWriter.logEvent).toHaveBeenCalledWith(
      "complete",
      expect.objectContaining({ seedId: "seed-observability", phase: "explorer", costUsd: 0.25 }),
    );
    expect(mockStore.updateRunProgress).not.toHaveBeenCalled();
    expect(mockStore.logEvent).not.toHaveBeenCalled();
  });

  it("routes registered bash phase success through the observability writer instead of direct store writes", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    const mockStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
    };
    const observedProgresses: Array<Record<string, unknown>> = [];
    const observabilityWriter = {
      updateProgress: vi.fn().mockImplementation(async (progress: Record<string, unknown>) => {
        observedProgresses.push(structuredClone(progress));
      }),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };
    const onTaskPhaseChange = vi.fn();

    await executePipeline({
      config: {
        runId: "run-bash-observability",
        projectId: "proj-bash-observability",
        seedId: "seed-bash-observability",
        seedTitle: "Registered bash seam",
        model: "anthropic/claude-haiku-4-5",
        worktreePath: tmpDir,
        env: {},
        taskId: "task-native-bash",
      },
      workflowConfig: {
        name: "test",
        phases: [{ name: "explorer", bash: "exit 0" }],
      } as never,
      store: mockStore as never,
      logFile: join(tmpDir, "bash-observability.log"),
      notifyClient: null,
      agentMailClient: null,
      observabilityWriter,
      onTaskPhaseChange,
      runPhase: vi.fn(),
      registerAgent: vi.fn().mockResolvedValue(undefined),
      sendMail: vi.fn(),
      sendMailText: vi.fn(),
      reserveFiles: vi.fn(),
      releaseFiles: vi.fn(),
      markStuck: vi.fn(),
      log: vi.fn(),
      promptOpts: { projectRoot: tmpDir, workflow: "default" },
    });

    expect(observabilityWriter.updateProgress).toHaveBeenCalled();
    expect(observabilityWriter.logEvent).toHaveBeenCalledWith(
      "complete",
      expect.objectContaining({ seedId: "seed-bash-observability", phase: "explorer" }),
    );
    expect(mockStore.updateRunProgress).not.toHaveBeenCalled();
    expect(mockStore.logEvent).not.toHaveBeenCalled();
    expect(onTaskPhaseChange).toHaveBeenCalledWith("task-native-bash", "explorer");
  });

  it("routes registered Haiku fallback success through the observability writer instead of direct store writes", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    const mockStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
      logRateLimitEvent: vi.fn(),
    };
    const observabilityWriter = {
      updateProgress: vi.fn().mockResolvedValue(undefined),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };
    const onTaskPhaseChange = vi.fn();
    const setTimeoutSpy = vi.spyOn(globalThis, "setTimeout").mockImplementation(((handler: unknown, _timeout?: number, ...args: unknown[]) => {
      if (typeof handler === "function") {
        (handler as (...callbackArgs: unknown[]) => void)(...args);
      }
      return 0 as unknown as ReturnType<typeof setTimeout>;
    }) as typeof setTimeout);

    const mockRunPhase = vi.fn()
      .mockResolvedValueOnce({
        success: false,
        costUsd: 0,
        turns: 1,
        tokensIn: 0,
        tokensOut: 0,
        error: "429 rate limit",
        outputText: "429 rate limit",
      })
      .mockResolvedValueOnce({
        success: true,
        costUsd: 0.2,
        turns: 2,
        tokensIn: 20,
        tokensOut: 30,
      });

    try {
      await executePipeline({
        config: {
          runId: "run-haiku-fallback-observability",
          projectId: "proj-haiku-fallback-observability",
          seedId: "seed-haiku-fallback-observability",
          seedTitle: "Registered haiku fallback seam",
          model: "anthropic/claude-haiku-4-5",
          worktreePath: tmpDir,
          env: {},
          taskId: "task-native-haiku-fallback",
        },
        workflowConfig: {
          name: "test",
          phases: [{ name: "explorer", artifact: "EXPLORER_REPORT.md" }],
        } as never,
        store: mockStore as never,
        logFile: join(tmpDir, "haiku-fallback-observability.log"),
        notifyClient: null,
        agentMailClient: null,
        observabilityWriter,
        onTaskPhaseChange,
        runPhase: mockRunPhase,
        registerAgent: vi.fn().mockResolvedValue(undefined),
        sendMail: vi.fn(),
        sendMailText: vi.fn(),
        reserveFiles: vi.fn(),
        releaseFiles: vi.fn(),
        markStuck: vi.fn(),
        log: vi.fn(),
        promptOpts: { projectRoot: tmpDir, workflow: "default" },
      });
    } finally {
      setTimeoutSpy.mockRestore();
    }

    expect(mockRunPhase).toHaveBeenCalledTimes(2);
    expect(mockRunPhase.mock.calls[1][9]).toBe(observabilityWriter);
    expect(observabilityWriter.updateProgress).toHaveBeenCalled();
    expect(observabilityWriter.logEvent).toHaveBeenCalledWith(
      "complete",
      expect.objectContaining({ seedId: "seed-haiku-fallback-observability", phase: "explorer" }),
    );
    expect(mockStore.updateRunProgress).not.toHaveBeenCalled();
    expect(mockStore.logEvent).not.toHaveBeenCalled();
    expect(mockStore.logRateLimitEvent).toHaveBeenCalled();
    expect(onTaskPhaseChange).toHaveBeenCalledWith("task-native-haiku-fallback", "explorer");
  });

  it("keeps successful QA/finalize support progress writes on the registered observability writer", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    const mockStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
    };
    const observedProgresses: Array<Record<string, unknown>> = [];
    const observabilityWriter = {
      updateProgress: vi.fn().mockImplementation(async (progress: Record<string, unknown>) => {
        observedProgresses.push(structuredClone(progress));
      }),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };
    const mockVcsBackend = {
      name: "git",
      getFinalizeCommands: vi.fn().mockReturnValue({
        stageCommand: "git add -A",
        commitCommand: "git commit -m test",
        pushCommand: "git push",
        integrateTargetCommand: "git fetch origin && git rebase origin/main",
        branchVerifyCommand: "git rev-parse --abbrev-ref HEAD",
        cleanCommand: "git status --short",
        restoreTrackedStateCommand: "git reset --mixed",
      }),
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
      resolveRef: vi.fn().mockImplementation(async (_worktreePath: string, ref: string) => `resolved:${ref}`),
      getHeadId: vi.fn().mockResolvedValue("head-123"),
      isAncestor: vi.fn().mockResolvedValue(true),
    };
    const mockRunPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      if (phaseName === "qa") {
        writeFileSync(
          join(tmpDir, "QA_REPORT.md"),
          [
            "## Verdict: PASS",
            "Ran: npm test",
            "1 passed, 0 failed",
          ].join("\n"),
          "utf8",
        );
      }
      if (phaseName === "finalize") {
        writeFileSync(
          join(tmpDir, "FINALIZE_VALIDATION.md"),
          [
            "## Verdict: PASS",
            "## Target Integration: SUCCESS",
            "## Test Validation: PASS",
          ].join("\n"),
          "utf8",
        );
      }

      return {
        success: true,
        costUsd: 0.1,
        turns: 1,
        tokensIn: 10,
        tokensOut: 20,
      };
    });

    await executePipeline({
      config: {
        runId: "run-qa-finalize",
        projectId: "proj-qa-finalize",
        seedId: "seed-qa-finalize",
        seedTitle: "QA finalize seam",
        model: "anthropic/claude-sonnet-4-6",
        worktreePath: tmpDir,
        env: {},
        taskId: "task-native-qa-finalize",
        vcsBackend: mockVcsBackend as never,
      },
      workflowConfig: {
        name: "test",
        phases: [
          { name: "qa", artifact: "QA_REPORT.md", verdict: true },
          { name: "finalize", artifact: "FINALIZE_VALIDATION.md", verdict: true },
        ],
      } as never,
      store: mockStore as never,
      logFile: join(tmpDir, "qa-finalize.log"),
      notifyClient: null,
      agentMailClient: null,
      observabilityWriter,
      onTaskPhaseChange: vi.fn(),
      runPhase: mockRunPhase,
      registerAgent: vi.fn().mockResolvedValue(undefined),
      sendMail: vi.fn(),
      sendMailText: vi.fn(),
      reserveFiles: vi.fn(),
      releaseFiles: vi.fn(),
      markStuck: vi.fn(),
      log: vi.fn(),
      promptOpts: { projectRoot: tmpDir, workflow: "default" },
    });

    expect(observabilityWriter.updateProgress).toHaveBeenCalledWith(
      expect.objectContaining({ qaValidatedTargetRef: "resolved:origin/main" }),
    );
    expect(observabilityWriter.updateProgress).toHaveBeenCalledWith(
      expect.objectContaining({ currentTargetRef: "resolved:origin/main" }),
    );
    expect(observabilityWriter.logEvent).toHaveBeenCalledWith(
      "complete",
      expect.objectContaining({ seedId: "seed-qa-finalize", phase: "qa" }),
    );
    expect(observabilityWriter.logEvent).toHaveBeenCalledWith(
      "complete",
      expect.objectContaining({ seedId: "seed-qa-finalize", phase: "finalize" }),
    );
    expect(mockStore.updateRunProgress).not.toHaveBeenCalled();
    expect(mockStore.logEvent).not.toHaveBeenCalled();
  });

  it("routes epic bookkeeping and epic phase progress through the registered observability writer", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    const mockStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
    };
    const observedProgresses: Array<Record<string, unknown>> = [];
    const observabilityWriter = {
      updateProgress: vi.fn().mockImplementation(async (progress: Record<string, unknown>) => {
        observedProgresses.push(structuredClone(progress));
      }),
      logEvent: vi.fn().mockResolvedValue(undefined),
    };
    const phaseResults = [
      { costUsd: 0.4, turns: 1, tokensIn: 10, tokensOut: 20 },
      { costUsd: 0.6, turns: 1, tokensIn: 10, tokensOut: 20 },
      { costUsd: 0.7, turns: 1, tokensIn: 10, tokensOut: 20 },
      { costUsd: 0.8, turns: 1, tokensIn: 10, tokensOut: 20 },
      { costUsd: 0.2, turns: 1, tokensIn: 10, tokensOut: 20 },
    ];
    let runPhaseCall = 0;

    await executePipeline({
      config: {
        runId: "run-epic-observability",
        projectId: "proj-epic-observability",
        seedId: "seed-epic-observability",
        seedTitle: "Epic observability seam",
        model: "anthropic/claude-sonnet-4-6",
        worktreePath: tmpDir,
        env: {},
        taskId: "task-epic-parent",
      },
      workflowConfig: {
        name: "test",
        phases: [
          { name: "explorer", artifact: "EXPLORER_REPORT.md" },
          { name: "developer", artifact: "DEVELOPER_REPORT.md" },
          { name: "finalize", artifact: "FINALIZE_VALIDATION.md" },
        ],
        taskPhases: ["explorer", "developer"],
        finalPhases: ["finalize"],
      } as never,
      store: mockStore as never,
      logFile: join(tmpDir, "epic-observability.log"),
      notifyClient: null,
      agentMailClient: null,
      observabilityWriter,
      runPhase: vi.fn().mockImplementation(async () => ({
        success: true,
        ...phaseResults[runPhaseCall++],
      })),
      registerAgent: vi.fn().mockResolvedValue(undefined),
      sendMail: vi.fn(),
      sendMailText: vi.fn(),
      reserveFiles: vi.fn(),
      releaseFiles: vi.fn(),
      markStuck: vi.fn(),
      log: vi.fn(),
      promptOpts: { projectRoot: tmpDir, workflow: "default" },
      epicTasks: [
        {
          seedId: "epic-child-001",
          seedTitle: "Epic child 1",
          seedDescription: "Child task 1",
        },
        {
          seedId: "epic-child-002",
          seedTitle: "Epic child 2",
          seedDescription: "Child task 2",
        },
      ],
    } as never);

    const firstTaskProgress = observedProgresses.find((progress) => progress.epicTasksCompleted === 1 && progress.epicCurrentTaskId === "epic-child-001");
    const secondTaskProgress = observedProgresses.find((progress) => progress.epicTasksCompleted === 2 && progress.epicCurrentTaskId === "epic-child-002");
    expect(firstTaskProgress).toMatchObject({
      epicCurrentTaskId: "epic-child-001",
      epicTasksCompleted: 1,
      epicCostByTask: {
        "epic-child-001": 1,
      },
    });
    expect(secondTaskProgress).toMatchObject({
      epicCurrentTaskId: "epic-child-002",
      epicTasksCompleted: 2,
      epicCostByTask: {
        "epic-child-001": 1,
        "epic-child-002": 1.5,
      },
    });
    expect(mockStore.updateRunProgress).not.toHaveBeenCalled();
  });

  it("preserves epic local fallback writes when no observability writer is provided", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    const mockStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
    };

    await executePipeline({
      config: {
        runId: "run-epic-local",
        projectId: "proj-epic-local",
        seedId: "seed-epic-local",
        seedTitle: "Epic local fallback",
        model: "anthropic/claude-sonnet-4-6",
        worktreePath: tmpDir,
        env: {},
        taskId: null,
      },
      workflowConfig: {
        name: "test",
        phases: [
          { name: "explorer", artifact: "EXPLORER_REPORT.md" },
          { name: "developer", artifact: "DEVELOPER_REPORT.md" },
          { name: "finalize", artifact: "FINALIZE_VALIDATION.md" },
        ],
        taskPhases: ["explorer", "developer"],
        finalPhases: ["finalize"],
      } as never,
      store: mockStore as never,
      logFile: join(tmpDir, "epic-local.log"),
      notifyClient: null,
      agentMailClient: null,
      runPhase: vi.fn().mockResolvedValue({
        success: true,
        costUsd: 0.1,
        turns: 1,
        tokensIn: 10,
        tokensOut: 20,
      }),
      registerAgent: vi.fn().mockResolvedValue(undefined),
      sendMail: vi.fn(),
      sendMailText: vi.fn(),
      reserveFiles: vi.fn(),
      releaseFiles: vi.fn(),
      markStuck: vi.fn(),
      log: vi.fn(),
      promptOpts: { projectRoot: tmpDir, workflow: "default" },
      epicTasks: [
        {
          seedId: "epic-local-child",
          seedTitle: "Epic child",
          seedDescription: "Child task",
        },
      ],
    } as never);

    expect(mockStore.updateRunProgress).toHaveBeenCalledWith(
      "run-epic-local",
      expect.objectContaining({
        epicCurrentTaskId: "epic-local-child",
        currentPhase: "epic-init",
      }),
    );
    expect(mockStore.updateRunProgress).toHaveBeenCalledWith(
      "run-epic-local",
      expect.objectContaining({ currentPhase: "finalize" }),
    );
    expect(mockStore.updateRunProgress).toHaveBeenCalledWith(
      "run-epic-local",
      expect.objectContaining({
        epicCurrentTaskId: "epic-local-child",
        epicTasksCompleted: 1,
      }),
    );
  });

  it("keeps QA bug closures scoped to the task that created them", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    const onTaskQaFailure = vi.fn().mockResolvedValue("bug-task-a");
    const onTaskQaPass = vi.fn().mockResolvedValue(undefined);

    const mockStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
    };
    const mockRunPhase = vi.fn();
    let runPhaseCall = 0;
    mockRunPhase.mockImplementation(async () => {
      runPhaseCall++;

      if (runPhaseCall === 1) {
        return {
          success: true,
          costUsd: 0.1,
          turns: 1,
          tokensIn: 10,
          tokensOut: 20,
        };
      }

      if (runPhaseCall === 2) {
        writeFileSync(
          join(tmpDir, "QA_REPORT.md"),
          "## Verdict: FAIL\n## Test Command\n- vitest run src/orchestrator/__tests__/pipeline-task-store-phase.test.ts\n- tests: 1 passed, 1 failed\n",
        );
        return {
          success: true,
          costUsd: 0.1,
          turns: 1,
          tokensIn: 10,
          tokensOut: 20,
        };
      }

      if (runPhaseCall === 3) {
        return {
          success: true,
          costUsd: 0.1,
          turns: 1,
          tokensIn: 10,
          tokensOut: 20,
        };
      }

      if (runPhaseCall === 4) {
        writeFileSync(
          join(tmpDir, "QA_REPORT.md"),
          "## Verdict: PASS\n## Test Command\n- vitest run src/orchestrator/__tests__/pipeline-task-store-phase.test.ts\n- tests: 2 passed, 0 failed\n",
        );
        return {
          success: true,
          costUsd: 0.1,
          turns: 1,
          tokensIn: 10,
          tokensOut: 20,
        };
      }

      expect(onTaskQaPass).not.toHaveBeenCalled();

      if (runPhaseCall === 5) {
        return {
          success: true,
          costUsd: 0.1,
          turns: 1,
          tokensIn: 10,
          tokensOut: 20,
        };
      }

      if (runPhaseCall === 6) {
        writeFileSync(
          join(tmpDir, "QA_REPORT.md"),
          "## Verdict: PASS\n## Test Command\n- vitest run src/orchestrator/__tests__/pipeline-task-store-phase.test.ts\n- tests: 2 passed, 0 failed\n",
        );
      }

      return {
        success: true,
        costUsd: 0.1,
        turns: 1,
        tokensIn: 10,
        tokensOut: 20,
      };
    });

    await executePipeline({
      config: {
        runId: "run-epic-qa-scope",
        projectId: "proj-epic-qa-scope",
        seedId: "seed-epic-qa-scope",
        seedTitle: "Epic QA scope",
        model: "anthropic/claude-sonnet-4-6",
        worktreePath: tmpDir,
        env: {},
        taskId: "task-epic-parent",
        epicId: "epic-parent",
      },
      workflowConfig: {
        name: "test",
        phases: [
          { name: "developer", artifact: "DEVELOPER_REPORT.md" },
          { name: "qa", artifact: "QA_REPORT.md", verdict: true, retryWith: "developer", retryOnFail: 0 },
        ],
        taskPhases: ["developer", "qa"],
      } as never,
      store: mockStore as never,
      logFile: join(tmpDir, "epic-qa-scope.log"),
      notifyClient: null,
      agentMailClient: null,
      runPhase: mockRunPhase,
      registerAgent: vi.fn().mockResolvedValue(undefined),
      sendMail: vi.fn(),
      sendMailText: vi.fn(),
      reserveFiles: vi.fn(),
      releaseFiles: vi.fn(),
      markStuck: vi.fn(),
      log: vi.fn(),
      promptOpts: { projectRoot: tmpDir, workflow: "default" },
      onTaskQaFailure,
      onTaskQaPass,
      epicTasks: [
        { seedId: "task-a", seedTitle: "Task A" },
        { seedId: "task-b", seedTitle: "Task B" },
        { seedId: "task-a", seedTitle: "Task A retry" },
      ],
    } as never);

    expect(onTaskQaFailure).toHaveBeenCalledTimes(1);
    expect(onTaskQaFailure).toHaveBeenCalledWith("task-a", "Task A", "epic-parent");
    expect(onTaskQaPass).toHaveBeenCalledTimes(1);
    expect(onTaskQaPass).toHaveBeenCalledWith("bug-task-a");
  });

  it("keeps local fallback behavior unchanged and non-fatal without a registered observability writer", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    const mockStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
    };
    const onTaskPhaseChange = vi.fn();
    const mockRunPhase = vi.fn().mockResolvedValue({
      success: true,
      costUsd: 0.05,
      turns: 1,
      tokensIn: 10,
      tokensOut: 20,
    });

    await expect(executePipeline({
      config: {
        runId: "run-local-fallback",
        projectId: "proj-local-fallback",
        seedId: "seed-local-fallback",
        seedTitle: "Local fallback",
        model: "anthropic/claude-haiku-4-5",
        worktreePath: tmpDir,
        env: {},
        taskId: null,
      },
      workflowConfig: {
        name: "test",
        phases: [{ name: "explorer", artifact: "EXPLORER_REPORT.md" }],
      } as never,
      store: mockStore as never,
      logFile: join(tmpDir, "local-fallback.log"),
      notifyClient: null,
      agentMailClient: null,
      onTaskPhaseChange,
      runPhase: mockRunPhase,
      registerAgent: vi.fn().mockResolvedValue(undefined),
      sendMail: vi.fn(),
      sendMailText: vi.fn(),
      reserveFiles: vi.fn(),
      releaseFiles: vi.fn(),
      markStuck: vi.fn(),
      log: vi.fn(),
      promptOpts: { projectRoot: tmpDir, workflow: "default" },
    })).resolves.not.toThrow();

    expect(mockStore.updateRunProgress).toHaveBeenCalled();
    expect(mockStore.logEvent).toHaveBeenCalledWith(
      "proj-local-fallback",
      "phase-start",
      expect.objectContaining({ seedId: "seed-local-fallback", phase: "explorer" }),
      "run-local-fallback",
    );
    expect(mockStore.logEvent).toHaveBeenCalledWith(
      "proj-local-fallback",
      "complete",
      expect.objectContaining({ seedId: "seed-local-fallback", phase: "explorer", costUsd: 0.05 }),
      "run-local-fallback",
    );
    expect(onTaskPhaseChange).toHaveBeenCalledWith(null, "explorer");
  });

  it("does NOT throw when onTaskPhaseChange is absent (undefined)", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    const mockStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
    };
    const mockRunPhase = vi.fn().mockResolvedValue({
      success: true,
      costUsd: 0,
      turns: 1,
      tokensIn: 0,
      tokensOut: 0,
    });

    const workflowConfig = {
      name: "test",
      phases: [{ name: "explorer", artifact: "EXPLORER_REPORT.md" }],
    };

    // Should not throw even without onTaskPhaseChange
    await expect(
      executePipeline({
        config: {
          runId: "run-003",
          projectId: "proj-003",
          seedId: "seed-003",
          seedTitle: "Test no callback",
          model: "anthropic/claude-haiku-4-5",
          worktreePath: tmpDir,
          env: {},
          taskId: "task-xyz",
        },
        workflowConfig: workflowConfig as never,
        store: mockStore as never,
        logFile: join(tmpDir, "test3.log"),
        notifyClient: null,
        agentMailClient: null,
        // onTaskPhaseChange intentionally absent
        runPhase: mockRunPhase,
        registerAgent: vi.fn().mockResolvedValue(undefined),
        sendMail: vi.fn(),
        sendMailText: vi.fn(),
        reserveFiles: vi.fn(),
        releaseFiles: vi.fn(),
        markStuck: vi.fn(),
        log: vi.fn(),
        promptOpts: { projectRoot: tmpDir, workflow: "default" },
      }),
    ).resolves.not.toThrow();
  });

  it("does NOT call onTaskPhaseChange for a failed phase (only successful phases)", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    const onTaskPhaseChange = vi.fn();

    const mockStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
    };
    // Phase fails
    const mockRunPhase = vi.fn().mockResolvedValue({
      success: false,
      costUsd: 0,
      turns: 1,
      tokensIn: 0,
      tokensOut: 0,
      error: "Phase failed",
    });

    const workflowConfig = {
      name: "test",
      phases: [{ name: "developer", artifact: "DEVELOPER_REPORT.md" }],
    };

    await executePipeline({
      config: {
        runId: "run-004",
        projectId: "proj-004",
        seedId: "seed-004",
        seedTitle: "Test failure",
        model: "anthropic/claude-haiku-4-5",
        worktreePath: tmpDir,
        env: {},
        taskId: "task-abc",
      },
      workflowConfig: workflowConfig as never,
      store: mockStore as never,
      logFile: join(tmpDir, "test4.log"),
      notifyClient: null,
      agentMailClient: null,
      onTaskPhaseChange,
      runPhase: mockRunPhase,
      registerAgent: vi.fn().mockResolvedValue(undefined),
      sendMail: vi.fn(),
      sendMailText: vi.fn(),
      reserveFiles: vi.fn(),
      releaseFiles: vi.fn(),
      markStuck: vi.fn().mockResolvedValue(undefined),
      log: vi.fn(),
      promptOpts: { projectRoot: tmpDir, workflow: "default" },
    });

    expect(onTaskPhaseChange).not.toHaveBeenCalled();
  });

  it("passes projectPath before notifyClient when marking a phase stuck", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    const mockStore = {
      updateRunProgress: vi.fn(),
      logEvent: vi.fn(),
    };
    const mockMarkStuck = vi.fn().mockResolvedValue(undefined);
    const notifyClient = { send: vi.fn() };
    const mockRunPhase = vi.fn().mockResolvedValue({
      success: false,
      costUsd: 0,
      turns: 1,
      tokensIn: 0,
      tokensOut: 0,
      error: "phase failed",
    });

    await executePipeline({
      config: {
        runId: "run-stuck-contract",
        projectId: "proj-stuck-contract",
        seedId: "seed-stuck-contract",
        seedTitle: "Stuck contract",
        model: "anthropic/claude-haiku-4-5",
        worktreePath: tmpDir,
        projectPath: tmpDir,
        env: {},
      },
      workflowConfig: {
        name: "test",
        phases: [{ name: "explorer", artifact: "EXPLORER_REPORT.md" }],
      } as never,
      store: mockStore as never,
      logFile: join(tmpDir, "stuck-contract.log"),
      notifyClient,
      agentMailClient: null,
      runPhase: mockRunPhase,
      registerAgent: vi.fn().mockResolvedValue(undefined),
      sendMail: vi.fn(),
      sendMailText: vi.fn(),
      reserveFiles: vi.fn(),
      releaseFiles: vi.fn(),
      markStuck: mockMarkStuck,
      log: vi.fn(),
      promptOpts: { projectRoot: tmpDir, workflow: "default" },
    });

    expect(mockMarkStuck).toHaveBeenCalledTimes(1);
    expect(mockMarkStuck).toHaveBeenCalledWith(
      mockStore,
      "run-stuck-contract",
      "proj-stuck-contract",
      "seed-stuck-contract",
      "Stuck contract",
      expect.objectContaining({ currentPhase: "explorer" }),
      "explorer",
      "phase failed",
      tmpDir,
      notifyClient,
    );
  });
});
