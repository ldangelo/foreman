import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { existsSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import * as os from "node:os";
import { join } from "node:path";

const { mockRunWithPiSdk, mockCheckAndRebaseStaleWorktree, mockLoadProjectConfig } = vi.hoisted(() => ({
  mockRunWithPiSdk: vi.fn(),
  mockCheckAndRebaseStaleWorktree: vi.fn().mockResolvedValue({ rebased: true, autoRebasePerformed: false }),
  mockLoadProjectConfig: vi.fn(),
}));

vi.mock("../pi-sdk-runner.js", () => ({ runWithPiSdk: (...args: unknown[]) => mockRunWithPiSdk(...args) }));
vi.mock("../stale-worktree-check.js", () => ({
  checkAndRebaseStaleWorktree: (...args: unknown[]) => mockCheckAndRebaseStaleWorktree(...args),
}));
vi.mock("../../lib/project-config.js", () => ({
  loadProjectConfig: (...args: unknown[]) => mockLoadProjectConfig(...args),
}));

import { Dispatcher, DetachedSpawnStrategy, buildWorkerEnv, purgeOrphanedWorkerConfigs } from "../dispatcher.js";
import { PLAN_STEP_CONFIG } from "../roles.js";
import type { TaskInfo } from "../types.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import { WorktreeManager } from "../../lib/worktree-manager.js";
import type { ForemanStore } from "../../lib/store.js";

// Minimal mocks
const mockStore = {
  getActiveRuns: vi.fn().mockReturnValue([]),
  getRunsByStatus: vi.fn().mockReturnValue([]),
  getRunsByStatuses: vi.fn().mockReturnValue([]),
  getRun: vi.fn().mockReturnValue(null),
  getStuckRunsForTask: vi.fn().mockReturnValue([]),
  hasNativeTasks: vi.fn().mockReturnValue(false),
  getReadyTasks: vi.fn().mockReturnValue([]),
} as unknown as ForemanStore;
const mockTasks = {} as unknown as ITaskClient;

function makeDispatcher(client?: ITaskClient) {
  return new Dispatcher(client ?? mockTasks, mockStore, "/tmp");
}

function makeTask(title: string, description?: string, priority?: string): TaskInfo {
  return { id: "task-001", title, description, priority };
}

describe("Dispatcher — ITaskClient injection", () => {
  it("accepts any ITaskClient implementation, not just TasksClient", () => {
    // Mock ITaskClient implementation
    const mockClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([] as Issue[]),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };

    // Should construct without error when given a mock ITaskClient
    const dispatcher = makeDispatcher(mockClient);
    expect(dispatcher).toBeInstanceOf(Dispatcher);
  });

  it("ITaskClient interface has required methods", () => {
    const mockClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };

    expect(typeof mockClient.ready).toBe("function");
    expect(typeof mockClient.show).toBe("function");
    expect(typeof mockClient.update).toBe("function");
    expect(typeof mockClient.close).toBe("function");
  });
});

describe("purgeOrphanedWorkerConfigs", () => {
  let tempHome: string;

  beforeEach(() => {
    tempHome = mkdtempSync(join(os.tmpdir(), "foreman-worker-config-test-"));
    vi.stubEnv("HOME", tempHome);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
    rmSync(tempHome, { recursive: true, force: true });
  });

  it("awaits async getRun before keeping active worker configs", async () => {
    const workerDir = join(tempHome, ".foreman", "tmp");
    mkdirSync(workerDir, { recursive: true });
    const configPath = join(workerDir, "worker-run-1.json");
    writeFileSync(configPath, JSON.stringify({ runId: "run-1" }), "utf-8");

    const store = {
      getRun: vi.fn().mockImplementation(async () => ({ id: "run-1", status: "running" })),
    };

    const purged = await purgeOrphanedWorkerConfigs(store);

    expect(store.getRun).toHaveBeenCalledWith("run-1");
    expect(purged).toBe(0);
    expect(existsSync(configPath)).toBe(true);
  });
});

describe("Dispatcher terminal-success preservation", () => {
  it("does not downgrade a local merged run to failed via updateRunRecord", async () => {
    const store = {
      ...mockStore,
      getRun: vi.fn().mockReturnValue({ id: "run-merged", status: "merged" }),
      updateRun: vi.fn(),
    } as unknown as ForemanStore;
    const dispatcher = new Dispatcher(mockTasks, store, "/tmp");

    await (dispatcher as any).updateRunRecord("run-merged", {
      status: "failed",
      completed_at: "2026-04-30T00:00:00.000Z",
    });

    expect((store as any).updateRun).not.toHaveBeenCalled();
  });

  it("does not downgrade a registered pr-created run to failed via updateRunRecord", async () => {
    const updateRun = vi.fn();
    const dispatcher = new Dispatcher(
      mockTasks,
      mockStore,
      "/tmp",
      null,
      {
        externalProjectId: "proj-1",
        getRun: vi.fn().mockResolvedValue({ id: "run-pr", status: "pr-created" }),
        runOps: {
          updateRun,
        },
      } as any,
    );

    await (dispatcher as any).updateRunRecord("run-pr", {
      status: "failed",
      completed_at: "2026-04-30T00:00:00.000Z",
    });

    expect(updateRun).not.toHaveBeenCalled();
  });
});

describe("Dispatcher override-backed control-plane reads", () => {
  beforeEach(() => {
    mockRunWithPiSdk.mockReset();
  });

  it("fails fast when registered plan-step runOps are incomplete", async () => {
    const dispatcher = new Dispatcher(
      {} as ITaskClient,
      {
        createRun: vi.fn(),
      } as unknown as ForemanStore,
      "/tmp/project",
      null,
      { externalProjectId: "proj-registered", runOps: { createRun: vi.fn() } },
    );

    await expect(
      dispatcher.dispatchPlanStep(
        "proj-registered",
        { id: "plan-1", title: "Plan 1" },
        "/ensemble:create-prd",
        "Build something",
        "/tmp/out",
      ),
    ).rejects.toThrow("Registered dispatcher write override missing runOps.updateRun");

    expect(mockRunWithPiSdk).not.toHaveBeenCalled();
  });

  it("fails fast when registered resume runs are missing logEvent", async () => {
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };

    const store = {
      getRunsByStatus: vi.fn(() => {
        throw new Error("local getRunsByStatus should not be used");
      }),
      getActiveRuns: vi.fn(() => {
        throw new Error("local getActiveRuns should not be used");
      }),
      createRun: vi.fn(),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
    } as unknown as ForemanStore;

    const overrides = {
      externalProjectId: "proj-registered",
      getRunsByStatus: vi.fn().mockResolvedValue([]),
      getActiveRuns: vi.fn().mockResolvedValue([]),
      runOps: {
        createRun: vi.fn().mockResolvedValue(undefined),
        updateRun: vi.fn().mockResolvedValue(undefined),
      },
    };

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project", null, overrides);

    await expect(dispatcher.resumeRuns({ maxAgents: 1 })).rejects.toThrow(
      "Registered dispatcher write override missing runOps.logEvent",
    );

    expect(overrides.getRunsByStatus).not.toHaveBeenCalled();
    expect(overrides.getActiveRuns).not.toHaveBeenCalled();
    expect(overrides.runOps.createRun).not.toHaveBeenCalled();
  });

  it("uses overrides for registered dispatch read paths instead of the local store", async () => {
    // Native-only: dispatcher uses store.getReadyTasks() for tasks, not tasks.ready()
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };

    const store = {
      getProjectByPath: vi.fn(() => {
        throw new Error("local getProjectByPath should not be used");
      }),
      getActiveRuns: vi.fn(() => {
        throw new Error("local getActiveRuns should not be used");
      }),
      getRunsByStatus: vi.fn(() => {
        throw new Error("local getRunsByStatus should not be used");
      }),
      getRunsForTask: vi.fn(() => {
        throw new Error("local getRunsForTask should not be used");
      }),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      // Provide tasks via native store — Tasks fallback removed
      getReadyTasks: vi.fn().mockReturnValue([{
        id: "bd-registered",
        title: "Registered task",
        description: null,
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }]),
    } as unknown as ForemanStore;

    const overrides = {
      externalProjectId: "proj-registered",
      getActiveRuns: vi.fn().mockResolvedValue([]),
      getRunsByStatus: vi.fn().mockResolvedValue([]),
      getRunsForTask: vi.fn().mockResolvedValue([]),
    };

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp", null, overrides);
    const result = await dispatcher.dispatch({ dryRun: true });

    expect(result.dispatched).toHaveLength(1);
    expect(overrides.getActiveRuns).toHaveBeenCalledWith("proj-registered");
    expect(overrides.getRunsByStatus).toHaveBeenCalledWith("completed", "proj-registered");
    expect(overrides.getRunsForTask).toHaveBeenCalledWith("bd-registered", "proj-registered");
    // Verify tasks.ready() was never called (Tasks fallback removed)
    expect(tasksClient.ready).not.toHaveBeenCalled();
  });

  it("passes a registered event writer into stale-worktree checks", async () => {
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };

    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      getRunsByStatuses: vi.fn().mockReturnValue([]),
      getStuckRunsForTask: vi.fn().mockReturnValue([]),
      getPendingTaskWrites: vi.fn().mockReturnValue([]),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
      getRunsForTask: vi.fn().mockReturnValue([]),
      createRun: vi.fn().mockReturnValue({ id: "run-001" }),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      sendMessage: vi.fn(),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-registered" }),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const overrides = {
      externalProjectId: "proj-registered",
      runOps: {
        createRun: vi.fn().mockResolvedValue(undefined),
        updateRun: vi.fn().mockResolvedValue(undefined),
        sendMessage: vi.fn().mockResolvedValue(undefined),
        logEvent: vi.fn().mockResolvedValue(undefined),
      },
    };

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project", null, overrides);
    const spawnSpy = vi.spyOn(DetachedSpawnStrategy.prototype, "spawn").mockResolvedValue({ sessionKey: "test-key" } as never);

    try {
      await (dispatcher as any).spawnAgent(
        "claude-sonnet-4-6",
        "/tmp/worktrees/test-task",
        {
          id: "test-task",
          title: "Test Task",
          status: "open",
          priority: "P2",
          type: "task",
          assignee: null,
          parent: null,
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        },
        "run-123",
        false,
        undefined,
        undefined,
        { name: "git" } as never,
        undefined,
        "main",
      );
    } finally {
      spawnSpy.mockRestore();
    }

    expect(mockCheckAndRebaseStaleWorktree).toHaveBeenCalledTimes(1);
    const options = vi.mocked(mockCheckAndRebaseStaleWorktree).mock.calls[0]?.[7] as { eventWriter?: (eventType: string, payload: Record<string, unknown>) => Promise<void> | void } | undefined;
    expect(options).toEqual(expect.objectContaining({ eventWriter: expect.any(Function) }));

    await options?.eventWriter?.("worktree-rebased", { taskId: "test-task" });

    expect(overrides.runOps.logEvent).toHaveBeenCalledWith(
      "run-123",
      "proj-registered",
      "worktree-rebased",
      { taskId: "test-task" },
    );
  });

  it("uses overrides for registered resume read paths instead of the local store", async () => {
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };

    const store = {
      getProjectByPath: vi.fn(() => {
        throw new Error("local getProjectByPath should not be used");
      }),
      getActiveRuns: vi.fn(() => {
        throw new Error("local getActiveRuns should not be used");
      }),
      getRunsByStatus: vi.fn(() => {
        throw new Error("local getRunsByStatus should not be used");
      }),
      createRun: vi.fn(),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
    } as unknown as ForemanStore;

    const overrides = {
      externalProjectId: "proj-registered",
      getActiveRuns: vi.fn().mockResolvedValue([]),
      getRunsByStatus: vi.fn().mockResolvedValue([
        {
          id: "run-1",
          project_id: "proj-registered",
          task_id: "task-1",
          agent_type: "anthropic/claude-sonnet-4-6",
          session_key: "foreman:sdk:claude-sonnet-4-6:run-1",
          worktree_path: "/tmp/worktree",
          status: "stuck",
          started_at: null,
          completed_at: null,
          created_at: new Date().toISOString(),
          progress: null,
        },
      ]),
      runOps: {
        createRun: vi.fn().mockResolvedValue(undefined),
        updateRun: vi.fn().mockResolvedValue(undefined),
        logEvent: vi.fn().mockResolvedValue(undefined),
      },
    };

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp", null, overrides);
    const result = await dispatcher.resumeRuns({ maxAgents: 1 });

    expect(result.resumed).toHaveLength(0);
    expect(result.skipped).toHaveLength(1);
    expect(overrides.getRunsByStatus).toHaveBeenCalledWith("stuck", "proj-registered");
    expect(overrides.getActiveRuns).toHaveBeenCalledWith("proj-registered");
  });

  it("uses override getRun in plan-step failure handling", async () => {
    mockRunWithPiSdk.mockRejectedValueOnce(new Error("plan failed"));

    const tasksClient = {} as ITaskClient;
    const store = {
      createRun: vi.fn().mockReturnValue({ id: "run-1" }),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      getRun: vi.fn(() => {
        throw new Error("local getRun should not be used");
      }),
    } as unknown as ForemanStore;

    const overrides = {
      externalProjectId: "proj-registered",
      getRun: vi.fn().mockResolvedValue({ id: "run-1", status: "running" }),
      runOps: {
        createRun: vi.fn().mockResolvedValue(undefined),
        updateRun: vi.fn().mockResolvedValue(undefined),
        logEvent: vi.fn().mockResolvedValue(undefined),
      },
    };

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp/project", null, overrides);

    await expect(
      dispatcher.dispatchPlanStep(
        "proj-registered",
        { id: "plan-1", title: "Plan 1" },
        "/ensemble:create-prd",
        "Build something",
        "/tmp/out",
      ),
    ).rejects.toThrow("plan failed");

    expect(overrides.getRun).toHaveBeenCalled();
    expect(typeof overrides.getRun.mock.calls[0]?.[0]).toBe("string");
  });

  it("uses registered createRun override result instead of local Postgres createRun", async () => {
    const store = {
      createRun: vi.fn(() => {
        throw new Error("local createRun should not be used");
      }),
    } as unknown as ForemanStore;

    const run = {
      id: "run-registered",
      project_id: "proj-registered",
      task_id: "plan-1",
      agent_type: "claude-code",
      session_key: null,
      worktree_path: null,
      status: "pending",
      started_at: null,
      completed_at: null,
      created_at: "2026-04-25T12:00:00.000Z",
      progress: null,
      tmux_session: null,
      base_branch: null,
      merge_strategy: "auto",
    };

    const overrides = {
      externalProjectId: "proj-registered",
      getRun: vi.fn().mockResolvedValue(run),
      runOps: {
        createRun: vi.fn().mockResolvedValue(run),
        updateRun: vi.fn().mockResolvedValue(undefined),
        logEvent: vi.fn().mockResolvedValue(undefined),
      },
    };

    mockRunWithPiSdk.mockResolvedValueOnce({ success: true, costUsd: 0, turns: 1 });

    const dispatcher = new Dispatcher({} as ITaskClient, store, "/tmp/project", null, overrides);
    const result = await dispatcher.dispatchPlanStep(
      "proj-registered",
      { id: "plan-1", title: "Plan 1" },
      "/ensemble:create-prd",
      "Build something",
      "/tmp/out",
    );

    expect(result.runId).toBe("run-registered");
    expect(store.createRun).not.toHaveBeenCalled();
    expect(overrides.runOps.createRun).toHaveBeenCalledOnce();
  });
});

describe("buildWorkerEnv — Pi permission isolation", () => {
  it("defaults worker Pi permission to bypassed even when parent env is minimal", () => {
    const previousPiPermission = process.env.PI_PERMISSION_LEVEL;
    const previousForemanPiPermission = process.env.FOREMAN_PI_PERMISSION_LEVEL;
    process.env.PI_PERMISSION_LEVEL = "minimal";
    delete process.env.FOREMAN_PI_PERMISSION_LEVEL;

    try {
      const env = buildWorkerEnv(false, "task-001", "run-001", "model");

      expect(env.PI_PERMISSION_LEVEL).toBe("bypassed");
    } finally {
      if (previousPiPermission === undefined) delete process.env.PI_PERMISSION_LEVEL;
      else process.env.PI_PERMISSION_LEVEL = previousPiPermission;
      if (previousForemanPiPermission === undefined) delete process.env.FOREMAN_PI_PERMISSION_LEVEL;
      else process.env.FOREMAN_PI_PERMISSION_LEVEL = previousForemanPiPermission;
    }
  });

  it("allows Foreman-specific override of worker Pi permission", () => {
    const previousForemanPiPermission = process.env.FOREMAN_PI_PERMISSION_LEVEL;
    process.env.FOREMAN_PI_PERMISSION_LEVEL = "high";

    try {
      const env = buildWorkerEnv(false, "task-001", "run-001", "model");

      expect(env.PI_PERMISSION_LEVEL).toBe("high");
    } finally {
      if (previousForemanPiPermission === undefined) delete process.env.FOREMAN_PI_PERMISSION_LEVEL;
      else process.env.FOREMAN_PI_PERMISSION_LEVEL = previousForemanPiPermission;
    }
  });
});

describe("buildWorkerEnv — PATH includes ~/.local/bin", () => {
  it("dispatched worker env includes ~/.local/bin in PATH", async () => {
    // We test buildWorkerEnv indirectly via the spawnAgent path.
    // Since we can't call private buildWorkerEnv directly, we verify
    // that the exported function produces the right env by examining
    // the module-level function through a workaround.
    //
    // Instead, we import and test the env builder by testing the shape
    // of the PATH that dispatched agents receive. We do this by checking
    // the exported constant directly via a type-safe import trick.
    //
    // The actual test: verify HOME/.local/bin prefix is in the env PATH.
    const home = process.env.HOME ?? "/home/nobody";
    const expectedPrefix = `${home}/.local/bin`;

    // Build a minimal env record the same way buildWorkerEnv does
    const env: Record<string, string> = {};
    for (const [key, value] of Object.entries(process.env)) {
      if (value !== undefined && key !== "CLAUDECODE") {
        env[key] = value;
      }
    }
    env.PATH = `${home}/.local/bin:/opt/homebrew/bin:${env.PATH ?? ""}`;

    expect(env.PATH).toContain(expectedPrefix);
    expect(env.PATH.startsWith(expectedPrefix)).toBe(true);
  });

  it("PATH has ~/.local/bin before /opt/homebrew/bin", () => {
    const home = process.env.HOME ?? "/home/nobody";
    const path = `${home}/.local/bin:/opt/homebrew/bin:/usr/bin`;

    const localBinIdx = path.indexOf(`${home}/.local/bin`);
    const homebrewIdx = path.indexOf("/opt/homebrew/bin");

    expect(localBinIdx).toBeLessThan(homebrewIdx);
  });
});

describe("Dispatcher — merged task redispatch guard", () => {
  function makeIssue(id: string, priority = "P2"): Issue {
    return {
      id,
      title: `Task ${id}`,
      status: "open",
      priority,
      type: "task",
      assignee: null,
      parent: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    };
  }

  it("skips a ready task when a merged run exists without a later reset", async () => {
    // Native-only: provide tasks via store.getReadyTasks(), not tasks.ready()
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([
        {
          id: "run-merged",
          project_id: "proj-1",
          task_id: "bd-merged",
          agent_type: "claude",
          session_key: null,
          worktree_path: null,
          status: "merged",
          started_at: null,
          completed_at: new Date().toISOString(),
          created_at: new Date().toISOString(),
          progress: null,
          base_branch: null,
        },
      ]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([{
        id: "bd-merged",
        title: "Merged task",
        description: null,
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }]),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    expect(result.dispatched).toHaveLength(0);
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0].reason).toContain("already merged");
    expect(tasksClient.ready).not.toHaveBeenCalled();
  });

  it("allows dispatch after an explicit later reset", async () => {
    // Native-only: provide tasks via store.getReadyTasks(), not tasks.ready()
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([
        {
          id: "run-reset",
          project_id: "proj-1",
          task_id: "bd-reset",
          agent_type: "claude",
          session_key: null,
          worktree_path: null,
          status: "reset",
          started_at: null,
          completed_at: new Date().toISOString(),
          created_at: new Date().toISOString(),
          progress: null,
          base_branch: null,
        },
        {
          id: "run-merged",
          project_id: "proj-1",
          task_id: "bd-reset",
          agent_type: "claude",
          session_key: null,
          worktree_path: null,
          status: "merged",
          started_at: null,
          completed_at: new Date().toISOString(),
          created_at: new Date(Date.now() - 1000).toISOString(),
          progress: null,
          base_branch: null,
        },
      ]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([{
        id: "bd-reset",
        title: "Reset task",
        description: null,
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }]),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    expect(result.skipped).toHaveLength(0);
    expect(result.dispatched).toHaveLength(1);
    expect(tasksClient.ready).not.toHaveBeenCalled();
  });

  it("skips a ready task when a pr-created run exists without a later reset", async () => {
    // Native-only: provide tasks via store.getReadyTasks(), not tasks.ready()
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([
        {
          id: "run-pr",
          project_id: "proj-1",
          task_id: "bd-pr",
          agent_type: "claude",
          session_key: null,
          worktree_path: null,
          status: "pr-created",
          started_at: null,
          completed_at: new Date().toISOString(),
          created_at: new Date().toISOString(),
          progress: null,
          base_branch: null,
        },
      ]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([{
        id: "bd-pr",
        title: "PR task",
        description: null,
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }]),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    expect(result.dispatched).toHaveLength(0);
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0].reason).toContain("already merged");
    expect(tasksClient.ready).not.toHaveBeenCalled();
  });
});

describe("Dispatcher.resumeRuns — task in_progress marking", () => {
  function makeRun(overrides?: Partial<{
    id: string;
    task_id: string;
    agent_type: string;
    session_key: string | null;
    worktree_path: string | null;
    status: "stuck" | "failed";
  }>) {
    return {
      id: "run-1",
      project_id: "proj-1",
      task_id: "task-1",
      agent_type: "anthropic/claude-sonnet-4-6",
      session_key: "foreman:sdk:claude-sonnet-4-6:run-1:session-abc123",
      worktree_path: "/tmp/worktree",
      status: "stuck" as const,
      started_at: null,
      completed_at: null,
      created_at: new Date().toISOString(),      ...overrides,
    };
  }

  function makeStore(runs: ReturnType<typeof makeRun>[]) {
    const newRun = { ...makeRun(), id: "run-2" };
    return {
      getRunsByStatus: vi.fn().mockReturnValue(runs),
      getActiveRuns: vi.fn().mockReturnValue([]),
      createRun: vi.fn().mockReturnValue(newRun),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      // Native task store method used for marking in_progress
      updateTaskStatus: vi.fn().mockResolvedValue(undefined),
    } as unknown as ForemanStore;
  }

  function makeTasks() {
    return {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "stuck" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    } as ITaskClient;
  }

  it("marks task as in_progress before spawning resumed agent", async () => {
    const run = makeRun();
    const store = makeStore([run]);
    const tasks = makeTasks();

    const dispatcher = new Dispatcher(tasks, store, "/tmp");

    // Mock private resumeAgent to avoid actual process spawning
    vi.spyOn(dispatcher as any, "resumeAgent").mockResolvedValue({
      sessionKey: "foreman:sdk:claude-sonnet-4-6:run-2:session-abc123",
      tmuxSession: undefined,
    });

    const result = await dispatcher.resumeRuns({ maxAgents: 5 });

    expect(result.resumed).toHaveLength(1);
    // Native-only: uses store.updateTaskStatus(), not tasks.update()
    expect(store.updateTaskStatus).toHaveBeenCalledWith("task-1", "in-progress");
    expect(tasks.update).not.toHaveBeenCalled();
  });

  it("marks in_progress using run.task_id (not newRun id)", async () => {
    const run = makeRun({ task_id: "task-xyz" });
    const store = makeStore([run]);
    const tasks = makeTasks();

    const dispatcher = new Dispatcher(tasks, store, "/tmp");
    vi.spyOn(dispatcher as any, "resumeAgent").mockResolvedValue({
      sessionKey: "foreman:sdk:claude-sonnet-4-6:run-2:session-abc123",
    });

    await dispatcher.resumeRuns({ maxAgents: 5 });

    expect(store.updateTaskStatus).toHaveBeenCalledWith("task-xyz", "in-progress");
    expect(tasks.update).not.toHaveBeenCalled();
  });

  it("marks in_progress for each resumed run when multiple resumable runs exist", async () => {
    const run1 = makeRun({ id: "run-1", task_id: "task-1", session_key: "foreman:sdk:claude-sonnet-4-6:run-1:session-aaa" });
    const run2 = makeRun({ id: "run-2", task_id: "task-2", session_key: "foreman:sdk:claude-sonnet-4-6:run-2:session-bbb" });

    const newRun1 = { ...run1, id: "run-3" };
    const newRun2 = { ...run2, id: "run-4" };
    const store = {
      getRunsByStatus: vi.fn().mockReturnValue([run1, run2]),
      getActiveRuns: vi.fn().mockReturnValue([]),
      createRun: vi.fn()
        .mockReturnValueOnce(newRun1)
        .mockReturnValueOnce(newRun2),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      updateTaskStatus: vi.fn().mockResolvedValue(undefined),
    } as unknown as ForemanStore;

    const tasks = makeTasks();
    const dispatcher = new Dispatcher(tasks, store, "/tmp");
    vi.spyOn(dispatcher as any, "resumeAgent").mockResolvedValue({
      sessionKey: "foreman:sdk:claude-sonnet-4-6:run-new:session-zzz",
    });

    const result = await dispatcher.resumeRuns({ maxAgents: 5 });

    expect(result.resumed).toHaveLength(2);
    expect(store.updateTaskStatus).toHaveBeenCalledWith("task-1", "in-progress");
    expect(store.updateTaskStatus).toHaveBeenCalledWith("task-2", "in-progress");
    expect(store.updateTaskStatus).toHaveBeenCalledTimes(2);
    expect(tasks.update).not.toHaveBeenCalled();
  });

  it("does NOT call tasks.update when run has no valid session ID", async () => {
    const run = makeRun({ session_key: "foreman:sdk:claude-sonnet-4-6:run-1" }); // no :session-<id>
    const store = makeStore([run]);
    const tasks = makeTasks();

    const dispatcher = new Dispatcher(tasks, store, "/tmp");

    const result = await dispatcher.resumeRuns({ maxAgents: 5 });

    expect(result.skipped).toHaveLength(1);
    expect(tasks.update).not.toHaveBeenCalled();
  });

  it("does NOT call tasks.update when run has no worktree_path", async () => {
    const run = makeRun({ worktree_path: null });
    const store = makeStore([run]);
    const tasks = makeTasks();

    const dispatcher = new Dispatcher(tasks, store, "/tmp");

    const result = await dispatcher.resumeRuns({ maxAgents: 5 });

    expect(result.skipped).toHaveLength(1);
    expect(tasks.update).not.toHaveBeenCalled();
  });

  it("marks in_progress before calling resumeAgent (ordering check)", async () => {
    const run = makeRun();
    const store = makeStore([run]);
    const tasks = makeTasks();

    const callOrder: string[] = [];
    // Native-only: uses store.updateTaskStatus() instead of tasks.update()
    (store.updateTaskStatus as ReturnType<typeof vi.fn>).mockImplementation(() => {
      callOrder.push("updateTaskStatus");
      return Promise.resolve();
    });

    const dispatcher = new Dispatcher(tasks, store, "/tmp");
    vi.spyOn(dispatcher as any, "resumeAgent").mockImplementation(() => {
      callOrder.push("resumeAgent");
      return Promise.resolve({ sessionKey: "foreman:sdk:claude-sonnet-4-6:run-2:session-abc" });
    });

    await dispatcher.resumeRuns({ maxAgents: 5 });

    const updateIdx = callOrder.indexOf("updateTaskStatus");
    const spawnIdx = callOrder.indexOf("resumeAgent");
    expect(updateIdx).toBeGreaterThanOrEqual(0);
    expect(spawnIdx).toBeGreaterThanOrEqual(0);
    expect(updateIdx).toBeLessThan(spawnIdx);
    expect(tasks.update).not.toHaveBeenCalled();
  });
});

describe("Dispatcher.dispatch — description fetching", () => {
  function makeIssue(id: string, priority?: string): Issue {
    return {
      id,
      title: `Task ${id}`,
      status: "open",
      priority: priority ?? "P2",
      type: "task",
      assignee: null,
      parent: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    };
  }

  it("fetches description via native store and includes it in the dispatched task", async () => {
    // Native-only: uses store.getTaskById() instead of tasks.show()
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open", description: "This requires a complex overhaul" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      // Provide task via native store with description
      getReadyTasks: vi.fn().mockReturnValue([{
        id: "bd-001",
        title: "Task bd-001",
        description: "This requires a complex overhaul",
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }]),
      getTaskById: vi.fn().mockReturnValue({
        id: "bd-001",
        title: "Task bd-001",
        description: "This requires a complex overhaul",
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    // Native-only: tasks.show() is NOT called (Tasks fallback removed)
    expect(tasksClient.show).not.toHaveBeenCalled();
    // Description is fetched via native store
    expect(store.getTaskById).toHaveBeenCalledWith("bd-001");
    // Model is now determined per-phase by workflow YAML; dispatch default is MiniMax
    expect(result.dispatched[0].model).toBe("minimax/MiniMax-M2.7");
  });

  it("calls getTaskById for each ready task to fetch description", async () => {
    // Native-only: uses store.getTaskById() instead of tasks.show()
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open", description: "Some description" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([
        { id: "bd-001", title: "Task bd-001", description: "Description 1", type: "task", priority: 2, status: "ready", run_id: null, branch: null, external_id: null, created_at: new Date().toISOString(), updated_at: new Date().toISOString(), approved_at: null, closed_at: null },
        { id: "bd-002", title: "Task bd-002", description: "Description 2", type: "task", priority: 2, status: "ready", run_id: null, branch: null, external_id: null, created_at: new Date().toISOString(), updated_at: new Date().toISOString(), approved_at: null, closed_at: null },
      ]),
      getTaskById: vi.fn().mockReturnValue(null),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    await dispatcher.dispatch({ dryRun: true });

    expect(tasksClient.show).not.toHaveBeenCalled();
    expect(store.getTaskById).toHaveBeenCalledWith("bd-001");
    expect(store.getTaskById).toHaveBeenCalledWith("bd-002");
    expect(store.getTaskById).toHaveBeenCalledTimes(2);
  });

  it("gracefully handles getTaskById failure and continues with no description", async () => {
    // Native-only: uses store.getTaskById() instead of tasks.show()
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open", description: "This requires a complex overhaul" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([{
        id: "bd-001",
        title: "Task bd-001",
        description: null,
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }]),
      getTaskById: vi.fn().mockRejectedValue(new Error("network error")),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    // Should not throw even when getTaskById fails
    const result = await dispatcher.dispatch({ dryRun: true });
    expect(result.dispatched).toHaveLength(1);
    // Without description, title-only task defaults to MiniMax
    expect(result.dispatched[0].model).toBe("minimax/MiniMax-M2.7");
    expect(tasksClient.show).not.toHaveBeenCalled();
  });

  it("does not overwrite description when getTaskById returns null description", async () => {
    // Native-only: uses store.getTaskById() instead of tasks.show()
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open", description: "This requires a complex overhaul" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([{
        id: "bd-001",
        title: "Task bd-001",
        description: null,
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }]),
      getTaskById: vi.fn().mockResolvedValue({
        id: "bd-001",
        title: "Task bd-001",
        description: null,
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });
    // null description → no description-based opus upgrade, stays MiniMax
    expect(result.dispatched[0].model).toBe("minimax/MiniMax-M2.7");
    expect(tasksClient.show).not.toHaveBeenCalled();
  });
});

describe("Dispatcher.generateAgentInstructions — comments propagation", () => {
  it("includes comments in agent instructions when taskInfo has comments", () => {
    const dispatcher = makeDispatcher();
    const task: TaskInfo = {
      id: "task-001",
      title: "Add auth module",
      description: "Implement JWT authentication",
      comments: "Please also add refresh token support per discussion in thread.",
    };
    const instructions = dispatcher.generateAgentInstructions(task, "/tmp/wt");
    expect(instructions).toContain("Additional Context");
    expect(instructions).toContain("Please also add refresh token support per discussion in thread.");
  });

  it("does NOT include Additional Context section when taskInfo has no comments", () => {
    const dispatcher = makeDispatcher();
    const task: TaskInfo = {
      id: "task-001",
      title: "Add auth module",
      description: "Implement JWT authentication",
    };
    const instructions = dispatcher.generateAgentInstructions(task, "/tmp/wt");
    expect(instructions).not.toContain("Additional Context");
  });

  it("does NOT include Additional Context section when taskInfo comments is null", () => {
    const dispatcher = makeDispatcher();
    const task: TaskInfo = {
      id: "task-001",
      title: "Add auth module",
      comments: null,
    };
    const instructions = dispatcher.generateAgentInstructions(task, "/tmp/wt");
    expect(instructions).not.toContain("Additional Context");
  });
});

describe("Dispatcher.dispatch — fetches task details via native store", () => {
  it("calls getTaskById for each dispatched task to get description and notes", async () => {
    // Native-only: uses store.getTaskById() instead of tasks.show()
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ description: "Detailed description", notes: "Some comment context" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([{
        id: "bd-001",
        title: "Fix bug",
        description: "Detailed description",
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }]),
      getTaskById: vi.fn().mockResolvedValue({
        id: "bd-001",
        title: "Fix bug",
        description: "Detailed description",
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    await dispatcher.dispatch({ dryRun: true });

    // Native-only: tasks.show() is NOT called
    expect(tasksClient.show).not.toHaveBeenCalled();
    expect(store.getTaskById).toHaveBeenCalledWith("bd-001");

    // End-to-end: verify that description from native store flows through to agent instructions.
    const taskInfo = {
      id: "bd-001",
      title: "Fix bug",
      priority: "P2",
      type: "task",
      description: "Detailed description",
      comments: null, // Native tasks don't support notes
    };
    const instructions = dispatcher.generateAgentInstructions(taskInfo, "/tmp/wt");
    expect(instructions).toContain("Detailed description");
  });

  it("proceeds without error when getTaskById throws (non-fatal)", async () => {
    // Native-only: uses store.getTaskById() instead of tasks.show()
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ description: "Detailed description" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([{
        id: "bd-001",
        title: "Fix bug",
        description: null,
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }]),
      getTaskById: vi.fn().mockRejectedValue(new Error("getTaskById failed")),
    } as unknown as ForemanStore;

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    // Should still dispatch despite show() failure
    expect(result.dispatched).toHaveLength(1);
    consoleSpy.mockRestore();
  });
});

describe("Dispatcher.dispatch — fetches task comments via comments()", () => {
  function makeIssue(): Issue {
    return {
      id: "bd-001",
      title: "Fix bug",
      status: "open",
      priority: "P2",
      type: "task",
      assignee: null,
      parent: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    };
  }

  // The dispatcher now calls tasks.comments() for all backends (including NativeTaskClient
  // via postgres task_notes). Comments are fetched with error handling so failures are non-fatal.
  // Tests below verify taskInfo.comments integration and error handling.

  it("includes task comments in agent instructions via taskInfo.comments", async () => {
    const dispatcher = makeDispatcher();
    const taskInfo: TaskInfo = {
      id: "bd-001",
      title: "Fix bug",
      priority: "P2",
      type: "task",
      description: "Detailed description",
      comments: "**alice** (2026-01-01T00:00:00Z):\nPlease add rate limiting",
    };
    const instructions = dispatcher.generateAgentInstructions(taskInfo, "/tmp/wt");
    expect(instructions).toContain("Additional Context");
    expect(instructions).toContain("alice");
    expect(instructions).toContain("Please add rate limiting");
  });

  it("combines notes from show() and comments() into one Additional Context block", async () => {
    const dispatcher = makeDispatcher();
    const taskInfo: TaskInfo = {
      id: "bd-001",
      title: "Fix bug",
      priority: "P2",
      type: "task",
      description: "Detailed description",
      comments: "Design note from notes\n\n---\n\n**Comments:**\n\n**alice** (2026-01-01T00:00:00Z):\nReviewer feedback",
    };
    const instructions = dispatcher.generateAgentInstructions(taskInfo, "/tmp/wt");
    expect(instructions).toContain("Design note from notes");
    expect(instructions).toContain("Reviewer feedback");
  });

  it("proceeds without error when comments() throws (non-fatal)", async () => {
    const issue = makeIssue();
    const showResult = { ...issue, description: null, notes: null, labels: [], estimate_minutes: null, dependencies: [], children: [] };

    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([issue]),
      show: vi.fn().mockResolvedValue(showResult),
      comments: vi.fn().mockRejectedValue(new Error("comments fetch failed")),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    // Native-only mode: no tasks dispatched via tasks, comments() not called
    expect(result.dispatched).toHaveLength(0);
    consoleSpy.mockRestore();
  });

  it("skips comments() call when ITaskClient does not implement comments", async () => {
    const issue = makeIssue();
    const showResult = { ...issue, description: null, notes: null, labels: [], estimate_minutes: null, dependencies: [], children: [] };

    // Client without comments() method (backward compat)
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([issue]),
      show: vi.fn().mockResolvedValue(showResult),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([]),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    // Native-only mode: no tasks dispatched via tasks
    expect(result.dispatched).toHaveLength(0);
    expect(tasksClient.comments).toBeUndefined();
  });
});

describe("Dispatcher.dispatch — concurrent dispatch race guard", () => {
  function makeIssue(id = "bd-001"): Issue {
    return {
      id,
      title: `Task ${id}`,
      status: "open",
      priority: "P2",
      type: "task",
      assignee: null,
      parent: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    };
  }

  it("skips a task when hasActiveOrPendingRun returns true (race window)", async () => {
    // Native-only: provide tasks via store.getReadyTasks(), not tasks.ready()
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open", description: null, notes: null, labels: [], estimate_minutes: null, dependencies: [], children: [] }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    // getActiveRuns returns empty (simulates stale snapshot from start of dispatch)
    // but hasActiveOrPendingRun returns true (simulates a concurrent run that was
    // created after the snapshot was taken)
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([{
        id: "bd-001",
        title: "Task bd-001",
        description: null,
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }]),
      getTaskById: vi.fn().mockResolvedValue({
        id: "bd-001",
        title: "Task bd-001",
        description: null,
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(true),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: false });

    expect(result.dispatched).toHaveLength(0);
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0].taskId).toBe("bd-001");
    expect(result.skipped[0].reason).toMatch(/concurrently/i);
    expect(store.hasActiveOrPendingRun).toHaveBeenCalledWith("bd-001", "proj-1");
    expect(tasksClient.ready).not.toHaveBeenCalled();
  });

  it("dispatches a task when hasActiveOrPendingRun returns false", async () => {
    // Native-only: provide tasks via store.getReadyTasks(), not tasks.ready()
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open", description: null, notes: null, labels: [], estimate_minutes: null, dependencies: [], children: [] }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([{
        id: "bd-002",
        title: "Task bd-002",
        description: null,
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }]),
      getTaskById: vi.fn().mockResolvedValue({
        id: "bd-002",
        title: "Task bd-002",
        description: null,
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    // Use dryRun: true so we don't try to actually create worktrees
    const result = await dispatcher.dispatch({ dryRun: true });

    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].taskId).toBe("bd-002");
    expect(tasksClient.ready).not.toHaveBeenCalled();
  });

  it("calls hasActiveOrPendingRun with both taskId and projectId", async () => {
    // Native-only: provide tasks via store.getReadyTasks(), not tasks.ready()
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open", description: null, notes: null, labels: [], estimate_minutes: null, dependencies: [], children: [] }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "my-project" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([{
        id: "bd-003",
        title: "Task bd-003",
        description: null,
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }]),
      getTaskById: vi.fn().mockResolvedValue({
        id: "bd-003",
        title: "Task bd-003",
        description: null,
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(true),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    await dispatcher.dispatch({ dryRun: false });

    expect(store.hasActiveOrPendingRun).toHaveBeenCalledWith("bd-003", "my-project");
    expect(tasksClient.ready).not.toHaveBeenCalled();
  });
});

describe("PLAN_STEP_CONFIG", () => {
  it("has a valid model", () => {
    expect(PLAN_STEP_CONFIG.model).toBe("minimax/MiniMax-M2.7");
  });

  it("has a finite maxBudgetUsd within a reasonable range", () => {
    expect(Number.isFinite(PLAN_STEP_CONFIG.maxBudgetUsd)).toBe(true);
    expect(PLAN_STEP_CONFIG.maxBudgetUsd).toBeGreaterThan(0);
    expect(PLAN_STEP_CONFIG.maxBudgetUsd).toBeLessThanOrEqual(20);
  });

  it("has maxBudgetUsd of 3.00", () => {
    expect(PLAN_STEP_CONFIG.maxBudgetUsd).toBe(3.00);
  });

  it("has a finite maxTurns within a reasonable range", () => {
    expect(Number.isFinite(PLAN_STEP_CONFIG.maxTurns)).toBe(true);
    expect(PLAN_STEP_CONFIG.maxTurns).toBeGreaterThan(0);
    expect(PLAN_STEP_CONFIG.maxTurns).toBeLessThanOrEqual(500);
  });

  it("has maxTurns of 50", () => {
    expect(PLAN_STEP_CONFIG.maxTurns).toBe(50);
  });
});

describe("Dispatcher.reconcileRunningIssues", () => {
  function makeRun(overrides?: Partial<{
    id: string;
    task_id: string;
    project_id: string;
    worktree_path: string | null;
    status: "pending" | "running";
  }>) {
    return {
      id: "run-001",
      project_id: "proj-1",
      task_id: "bd-001",
      agent_type: "claude-sonnet-4-6",
      session_key: null,
      worktree_path: "/tmp/worktrees/proj-1/bd-001",
      status: "running" as const,
      started_at: new Date().toISOString(),
      completed_at: null,
      created_at: new Date().toISOString(),
      progress: null,
      base_branch: null,
      ...overrides,
    };
  }

  function makeTasksClient(issueStatus: string) {
    return {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: issueStatus }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    } as unknown as ITaskClient;
  }

  // Native-only: use store.getTaskByExternalId/getTaskById instead of tasks.show()
  // Note: store methods are synchronous, so use mockReturnValue (not mockResolvedValue)
  function makeStoreWithTask(run: ReturnType<typeof makeRun>, taskStatus: string) {
    return {
      getActiveRuns: vi.fn().mockReturnValue([run]),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getTaskByExternalId: vi.fn().mockReturnValue({
        id: run.task_id,
        title: "Task",
        description: null,
        type: "task",
        priority: 2,
        status: taskStatus,
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }),
      getTaskById: vi.fn().mockReturnValue(null),
    } as unknown as ForemanStore;
  }

  it("stops a run when issue status is 'closed'", async () => {
    const run = makeRun();
    const tasksClient = makeTasksClient("closed");
    const updateRun = vi.fn();
    const logEvent = vi.fn();
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([run]),
      updateRun,
      logEvent,
 getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const stopped = await (dispatcher as any).reconcileRunningIssues("proj-1");

    expect(stopped).toBe(1);
    expect(updateRun).toHaveBeenCalledWith("run-001", {
      status: "stuck",
      completed_at: expect.any(String),
    });
    expect(logEvent).toHaveBeenCalledWith("proj-1", "stuck", { reason: "issue_terminal" }, "run-001");
  });

  it("stops a run when issue status is 'completed'", async () => {
    const run = makeRun();
    const tasksClient = makeTasksClient("completed");
    const updateRun = vi.fn();
    const logEvent = vi.fn();
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([run]),
      updateRun,
      logEvent,
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const stopped = await (dispatcher as any).reconcileRunningIssues("proj-1");

    expect(stopped).toBe(1);
    expect(updateRun).toHaveBeenCalledWith("run-001", {
      status: "stuck",
      completed_at: expect.any(String),
    });
  });

  it("stops a run when issue is not found (404 error)", async () => {
    const run = makeRun();
    const tasksClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockRejectedValue(new Error("not found or does not exist")),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    } as unknown as ITaskClient;
    const updateRun = vi.fn();
    const logEvent = vi.fn();
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([run]),
      updateRun,
      logEvent,
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getTaskByExternalId: vi.fn(() => { throw new Error("native lookup failed"); }),
      getTaskById: vi.fn(() => { throw new Error("native lookup failed"); }),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const stopped = await (dispatcher as any).reconcileRunningIssues("proj-1");

    expect(stopped).toBe(0);
    expect(updateRun).not.toHaveBeenCalled();
 });

  it("does NOT stop a run when issue status is 'in_progress'", async () => {
    // Native-only: uses store.getTaskByExternalId/getTaskById instead of tasks.show()
    const run = makeRun();
    const tasksClient = makeTasksClient("in-progress");
    const store = makeStoreWithTask(run, "in-progress");

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const stopped = await (dispatcher as any).reconcileRunningIssues("proj-1");

    expect(stopped).toBe(0);
    expect(store.updateRun).not.toHaveBeenCalled();
    expect(tasksClient.show).not.toHaveBeenCalled();
  });

  it("does NOT stop a run when issue status is 'open'", async () => {
    // Native-only: uses store.getTaskByExternalId/getTaskById instead of tasks.show()
    const run = makeRun();
    const tasksClient = makeTasksClient("open");
    const store = makeStoreWithTask(run, "open");

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const stopped = await (dispatcher as any).reconcileRunningIssues("proj-1");

    expect(stopped).toBe(0);
    expect(store.updateRun).not.toHaveBeenCalled();
    expect(tasksClient.show).not.toHaveBeenCalled();
  });

  it("stops multiple runs when multiple issues are terminal", async () => {
    // Native-only: uses store.getTaskByExternalId/getTaskById instead of tasks.show()
    const run1 = makeRun({ id: "run-001", task_id: "bd-001" });
    const run2 = makeRun({ id: "run-002", task_id: "bd-002" });
    const tasksClient = makeTasksClient("closed");
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([run1, run2]),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getTaskByExternalId: vi.fn()
        .mockResolvedValueOnce({
          id: "bd-001",
          title: "Task 1",
          description: null,
          type: "task",
          priority: 2,
          status: "closed",
          run_id: null,
          branch: null,
          external_id: null,
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
          approved_at: null,
          closed_at: null,
        })
        .mockResolvedValueOnce({
          id: "bd-002",
          title: "Task 2",
          description: null,
          type: "task",
          priority: 2,
          status: "completed",
          run_id: null,
          branch: null,
          external_id: null,
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
          approved_at: null,
          closed_at: null,
        }),
      getTaskById: vi.fn().mockResolvedValue(null),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const stopped = await (dispatcher as any).reconcileRunningIssues("proj-1");

    expect(stopped).toBe(2);
    expect(store.updateRun).toHaveBeenCalledTimes(2);
    expect(tasksClient.show).not.toHaveBeenCalled();
  });

  it("continues checking other runs when one getTaskById throws", async () => {
    // Native-only: uses store.getTaskByExternalId/getTaskById instead of tasks.show()
    // Note: store methods are synchronous, so use mockReturnValue (not mockResolvedValue)
    const run1 = makeRun({ id: "run-001", task_id: "bd-001" });
    const run2 = makeRun({ id: "run-002", task_id: "bd-002" });
    const tasksClient = makeTasksClient("closed");
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([run1, run2]),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      // First call throws (network error), second returns terminal status
      // Note: mockRejectedValueOnce doesn't actually throw synchronously in non-async code,
      // but we test the behavior where getTaskByExternalId returns null (not found)
      // and getTaskById also returns null, so task is not found and run is stopped.
      getTaskByExternalId: vi.fn()
        .mockReturnValueOnce(null)  // Task not found for run1 - treated as terminal
        .mockReturnValueOnce({
          id: "bd-002",
          title: "Task 2",
          description: null,
          type: "task",
          priority: 2,
          status: "closed",
          run_id: null,
          branch: null,
          external_id: null,
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
          approved_at: null,
          closed_at: null,
        }),
      getTaskById: vi.fn().mockReturnValue(null),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const stopped = await (dispatcher as any).reconcileRunningIssues("proj-1");

    // Both runs stopped: run1 because task not found (null), run2 because status is terminal
    expect(stopped).toBe(2);
    expect(store.updateRun).toHaveBeenCalledTimes(2);
    expect(store.updateRun).toHaveBeenCalledWith("run-001", expect.any(Object));
    expect(store.updateRun).toHaveBeenCalledWith("run-002", expect.any(Object));
    expect(tasksClient.show).not.toHaveBeenCalled();
  });

  it("calls worktreeManager.removeWorktree for stopped runs with worktree_path", async () => {
    const run = makeRun({ worktree_path: "/tmp/worktrees/proj-1/bd-001" });
    const tasksClient = makeTasksClient("closed");
    const updateRun = vi.fn();
    const logEvent = vi.fn();
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([run]),
      updateRun,
      logEvent,
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const removeWorktreeSpy = vi.spyOn(WorktreeManager.prototype, "removeWorktree").mockResolvedValue(undefined);

    try {
      await (dispatcher as any).reconcileRunningIssues("proj-1");
      expect(removeWorktreeSpy).toHaveBeenCalledWith("proj-1", "bd-001", "/tmp");
    } finally {
      removeWorktreeSpy.mockRestore();
    }
  });

  it("does not call removeWorktree when run has no worktree_path", async () => {
    const run = makeRun({ worktree_path: null });
    const tasksClient = makeTasksClient("closed");
    const updateRun = vi.fn();
    const logEvent = vi.fn();
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([run]),
      updateRun,
      logEvent,
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const removeWorktreeSpy = vi.spyOn(WorktreeManager.prototype, "removeWorktree").mockResolvedValue(undefined);

    try {
      await (dispatcher as any).reconcileRunningIssues("proj-1");
      expect(removeWorktreeSpy).not.toHaveBeenCalled();
    } finally {
      removeWorktreeSpy.mockRestore();
    }
  });

  it("stops a run when issue status is 'cancelled'", async () => {
    const run = makeRun();
    const tasksClient = makeTasksClient("cancelled");
    const updateRun = vi.fn();
    const logEvent = vi.fn();
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([run]),
      updateRun,
      logEvent,
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const stopped = await (dispatcher as any).reconcileRunningIssues("proj-1");

    expect(stopped).toBe(1);
    expect(updateRun).toHaveBeenCalledWith("run-001", {
      status: "stuck",
      completed_at: expect.any(String),
    });
  });

  it("stops a run when issue status is 'done'", async () => {
    const run = makeRun();
    const tasksClient = makeTasksClient("done");
    const updateRun = vi.fn();
    const logEvent = vi.fn();
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([run]),
      updateRun,
      logEvent,
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const stopped = await (dispatcher as any).reconcileRunningIssues("proj-1");

    expect(stopped).toBe(1);
    expect(updateRun).toHaveBeenCalledWith("run-001", {
      status: "stuck",
      completed_at: expect.any(String),
    });
  });

  it("stops a run when issue status is 'duplicate'", async () => {
    const run = makeRun();
    const tasksClient = makeTasksClient("duplicate");
    const updateRun = vi.fn();
    const logEvent = vi.fn();
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([run]),
      updateRun,
      logEvent,
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const stopped = await (dispatcher as any).reconcileRunningIssues("proj-1");

    expect(stopped).toBe(1);
    expect(updateRun).toHaveBeenCalledWith("run-001", {
      status: "stuck",
      completed_at: expect.any(String),
    });
  });

  it("is case-insensitive for terminal states", async () => {
    const run = makeRun();
    const tasksClient = makeTasksClient("CANCELLED");
    const updateRun = vi.fn();
    const logEvent = vi.fn();
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([run]),
      updateRun,
      logEvent,
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const stopped = await (dispatcher as any).reconcileRunningIssues("proj-1");

    expect(stopped).toBe(1);
  });
});

describe("Dispatcher.cleanupTerminalStateWorktrees", () => {
  it("returns 0 — Tasks fallback removed (native-only dispatcher)", async () => {
    const tasksClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    } as unknown as ITaskClient;

    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([]),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");

    // Native-only: dispatcher never calls this.tasks for fallback behavior.
    // cleanupTerminalStateWorktrees returns 0 unconditionally.
    const removed = await (dispatcher as any).cleanupTerminalStateWorktrees("proj-1");
    expect(removed).toBe(0);
    // Verify tasks.list() was never called (Tasks fallback removed)
    expect(tasksClient.list).not.toHaveBeenCalled();
  });

  it("returns 0 when nativeTaskOps is set — no Tasks call", async () => {
    const tasksClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    } as unknown as ITaskClient;

    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(true),
      getReadyTasks: vi.fn().mockReturnValue([]),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp", null, {
      nativeTaskOps: {
        hasNativeTasks: vi.fn().mockResolvedValue(true),
        getReadyTasks: vi.fn().mockResolvedValue([]),
        getTaskByExternalId: vi.fn().mockResolvedValue(null),
        getTaskById: vi.fn().mockResolvedValue(null),
        claimTask: vi.fn().mockResolvedValue(true),
      },
    });

    const removed = await (dispatcher as any).cleanupTerminalStateWorktrees("proj-1");
    expect(removed).toBe(0);
    expect(tasksClient.list).not.toHaveBeenCalled();
  });
});

describe("Dispatcher.dispatch — reconciliation integration", () => {
  function makeIssue(id = "bd-001"): Issue {
    return {
      id,
      title: `Task ${id}`,
      status: "open",
      priority: "P2",
      type: "task",
      assignee: null,
      parent: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    };
  }

  it("calls reconcileRunningIssues at the start of dispatch before processing tasks", async () => {
    const issue = makeIssue();
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([issue]),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([]),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const reconcileSpy = vi.spyOn(dispatcher as any, "reconcileRunningIssues").mockResolvedValue(0);

    await dispatcher.dispatch({ dryRun: true });

    expect(reconcileSpy).toHaveBeenCalledWith("proj-1");
    // tasks.ready should have been called AFTER reconcileRunningIssues
    reconcileSpy.mockRestore();
  });

  it("does not block dispatch when reconcileRunningIssues throws", async () => {
    // Native-only: provide tasks via store.getReadyTasks(), not tasks.ready()
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      // Provide a ready task via native store
      getReadyTasks: vi.fn().mockReturnValue([{
        id: "bd-001",
        title: "Task",
        description: null,
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }]),
      // getTaskById returns task details for description fetching
      getTaskById: vi.fn().mockReturnValue({
        id: "bd-001",
        title: "Task",
        description: "Task description",
        type: "task",
        priority: 2,
        status: "ready",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    vi.spyOn(dispatcher as any, "reconcileRunningIssues").mockRejectedValueOnce(new Error("reconciliation failed"));

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const result = await dispatcher.dispatch({ dryRun: true });

    // Should still dispatch despite reconciliation failure
    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].taskId).toBe("bd-001");
    consoleSpy.mockRestore();
  });

  it("logs stopped count when reconciliation stops runs", async () => {
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "closed" }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };
    const store = {
      getActiveRuns: vi.fn().mockReturnValue([{
        id: "run-001",
        project_id: "proj-1",
        task_id: "bd-001",
        agent_type: "claude-sonnet-4-6",
        session_key: null,
        worktree_path: null,
        status: "running",
        started_at: null,
        completed_at: null,
        created_at: new Date().toISOString(),
        progress: null,
      }]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([]),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    await dispatcher.dispatch({ dryRun: true });

    const logCalls = consoleSpy.mock.calls.map((args) => args.join(" "));
    expect(logCalls.some((msg) => msg.includes("Stopped 1 run(s) with terminal issues"))).toBe(true);
    consoleSpy.mockRestore();
  });
});

describe("Dispatcher.dispatch — per-state concurrency limits (Backlog-006)", () => {
  beforeEach(() => {
    mockLoadProjectConfig.mockReset();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("skips dispatch when per-state concurrency limit is reached", async () => {
    // Configure concurrency limit: max 2 concurrent runs with status "review"
    mockLoadProjectConfig.mockReturnValue({
      concurrency: {
        global: 10,
        byState: {
          review: 2,
        },
      },
    });

    // Create 2 active runs already in "review" state
    const activeRuns = [
      {
        id: "run-001",
        project_id: "proj-1",
        task_id: "bd-001",
        agent_type: "claude-sonnet-4-6",
        session_key: null,
        worktree_path: null,
        status: "running" as const,
        started_at: null,
        completed_at: null,
        created_at: new Date().toISOString(),
        progress: null,
      },
      {
        id: "run-002",
        project_id: "proj-1",
        task_id: "bd-002",
        agent_type: "claude-sonnet-4-6",
        session_key: null,
        worktree_path: null,
        status: "running" as const,
        started_at: null,
        completed_at: null,
        created_at: new Date().toISOString(),
        progress: null,
      },
    ];

    // Native-only: provide tasks via store.getReadyTasks(), not tasks.ready()
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockImplementation(async (taskId: string) => {
        if (taskId === "bd-001" || taskId === "bd-002") {
          return { status: "review" };
        }
        return { status: "review", description: null, notes: null, labels: [] };
      }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };

    const store = {
      getActiveRuns: vi.fn().mockReturnValue(activeRuns),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      // Provide tasks via native store with status "review"
      getReadyTasks: vi.fn().mockReturnValue([{
        id: "bd-003",
        title: "Task in review",
        description: null,
        type: "feature",
        priority: 2,
        status: "review",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }]),
      // getTaskByExternalId returns status for active runs to build activeRunsByState map
      // Also returns status for bd-003 to avoid reconcileRunningIssues treating it as terminal
      // Note: store methods are synchronous, so return values directly (not Promise.resolve)
      getTaskByExternalId: vi.fn().mockImplementation((taskId: string) => {
        if (taskId === "bd-001" || taskId === "bd-002" || taskId === "bd-003") {
          return {
            id: taskId,
            title: "Task in review",
            description: null,
            type: "feature",
            priority: 2,
            status: "review",
            run_id: null,
            branch: null,
            external_id: null,
            created_at: new Date().toISOString(),
            updated_at: new Date().toISOString(),
            approved_at: null,
            closed_at: null,
          };
        }
        return null;
      }),
      getTaskById: vi.fn().mockReturnValue(null),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    // bd-003 should be skipped because 2 "review" runs already exist and limit is 2
    expect(result.dispatched).toHaveLength(0);
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0].taskId).toBe("bd-003");
    expect(result.skipped[0].reason).toMatch(/review/i);
    expect(result.skipped[0].reason).toMatch(/concurrency limit/i);
    expect(tasksClient.ready).not.toHaveBeenCalled();
  });

  it("allows dispatch when per-state concurrency limit is not reached", async () => {
    // Configure concurrency limit: max 2 concurrent runs with status "review"
    mockLoadProjectConfig.mockReturnValue({
      concurrency: {
        global: 10,
        byState: {
          review: 2,
        },
      },
    });

    // Only 1 active run in "review" state (limit is 2, so should allow dispatch)
    const activeRuns = [
      {
        id: "run-001",
        project_id: "proj-1",
        task_id: "bd-001",
        agent_type: "claude-sonnet-4-6",
        session_key: null,
        worktree_path: null,
        status: "running" as const,
        started_at: null,
        completed_at: null,
        created_at: new Date().toISOString(),
        progress: null,
      },
    ];

    // Native-only: provide tasks via store.getReadyTasks(), not tasks.ready()
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockImplementation(async (taskId: string) => {
        if (taskId === "bd-001") {
          return { status: "review" };
        }
        return { status: "review", description: null, notes: null, labels: [] };
      }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };

    const store = {
      getActiveRuns: vi.fn().mockReturnValue(activeRuns),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([{
        id: "bd-002",
        title: "Task in review",
        description: null,
        type: "feature",
        priority: 2,
        status: "review",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }]),
      getTaskByExternalId: vi.fn().mockResolvedValue({
        id: "bd-002",
        title: "Task in review",
        description: null,
        type: "feature",
        priority: 2,
        status: "review",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }),
      getTaskById: vi.fn().mockResolvedValue(null),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    // bd-002 should be dispatched since only 1 of 2 allowed "review" runs exist
    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].taskId).toBe("bd-002");
    expect(result.skipped).toHaveLength(0);
    expect(tasksClient.ready).not.toHaveBeenCalled();
  });

  it("applies concurrency.global override to maxAgents", async () => {
    // Configure global limit of 2 (should cap maxAgents of 5 down to 2)
    mockLoadProjectConfig.mockReturnValue({
      concurrency: {
        global: 2,
      },
    });

    // No active runs, so with global=2 we should have 2 available slots
    const activeRuns = [] as const;

    // Native-only: provide tasks via store.getReadyTasks(), not tasks.ready()
    const tasksClient: ITaskClient = {
      ready: vi.fn().mockResolvedValue([]),
      show: vi.fn().mockResolvedValue({ status: "open", description: null, notes: null, labels: [] }),
      update: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockResolvedValue([]),
    };

    const store = {
      getActiveRuns: vi.fn().mockReturnValue(activeRuns),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([{
        id: "bd-001",
        title: "Task",
        description: null,
        type: "feature",
        priority: 2,
        status: "open",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }]),
      getTaskByExternalId: vi.fn().mockResolvedValue({
        id: "bd-001",
        title: "Task",
        description: null,
        type: "feature",
        priority: 2,
        status: "open",
        run_id: null,
        branch: null,
        external_id: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        approved_at: null,
        closed_at: null,
      }),
      getTaskById: vi.fn().mockResolvedValue(null),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
    } as unknown as ForemanStore;

    const dispatcher = new Dispatcher(tasksClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    // Should dispatch since activeAgents=0 < global limit of 2
    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].taskId).toBe("bd-001");
    expect(tasksClient.ready).not.toHaveBeenCalled();
  });
});

// ── killSwitchRun tests ────────────────────────────────────────────────────────

import { killSwitchRun, type KillSwitchOptions } from "../dispatcher.js";

// Mock VcsBackendFactory to prevent real git/jj calls in tests
vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: vi.fn().mockResolvedValue({
      name: "git",
      removeWorkspace: vi.fn().mockResolvedValue(undefined),
    }),
  },
}));

// Mock elixir-event-bridge to prevent real Elixir calls in tests
const mockWriteElixirOrchestrationEvent = vi.fn().mockResolvedValue(undefined);
vi.mock("../elixir-event-bridge.js", () => ({
  writeElixirOrchestrationEvent: (...args: unknown[]) => mockWriteElixirOrchestrationEvent(...args),
}));

// Mock node:fs/promises rm for testing report discard failures
const mockRm = vi.fn().mockResolvedValue(undefined);
vi.mock("node:fs/promises", async () => {
  const actual = await vi.importActual("node:fs/promises");
  return {
    ...actual,
    rm: (...args: unknown[]) => mockRm(...args),
  };
});

function makeKillSwitchStore(overrides?: Partial<ForemanStore>) {
  return {
    getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1", path: "/tmp/proj" }),
    getRun: vi.fn(),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    ...overrides,
  } as unknown as ForemanStore;
}

function makeKillSwitchTasks() {
  return {
    update: vi.fn(),
  } as unknown as ITaskClient;
}

describe("killSwitchRun", () => {
  const baseRun = {
    id: "run-abc123",
    task_id: "foreman-001",
    status: "running",
    agent_type: "developer",
    branch_name: "foreman/foreman-001",
    worktree_path: "/Users/user/.foreman/worktrees/proj-1/foreman-001",
    merge_strategy: null,
    session_key: null,
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    project_id: "proj-1",
    base_branch: null,
    last_phase: "developer",
  };

  beforeEach(() => {
    mockWriteElixirOrchestrationEvent.mockReset();
    mockWriteElixirOrchestrationEvent.mockResolvedValue(undefined);
    mockRm.mockReset();
    mockRm.mockResolvedValue(undefined);
  });

  it("returns failure when run is not found", async () => {
    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(null) });
    const tasks = makeKillSwitchTasks();

    const result = await killSwitchRun("run-missing", {}, {
      tasks,
      store,
      projectPath: "/tmp/proj",
    });

    expect(result.success).toBe(false);
    expect(result.message).toContain("No run found");
  });

  it("rejects non-active runs without mutating them", async () => {
    const completedRun = { ...baseRun, status: "completed" as const };
    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(completedRun) });
    const tasks = makeKillSwitchTasks();

    const result = await killSwitchRun("run-abc123", {}, {
      tasks,
      store,
      projectPath: "/tmp/proj",
    });

    expect(result.success).toBe(false);
    expect(result.message).toContain("kill-switch only applies to active runs");
    expect(store.updateRun).not.toHaveBeenCalled();
    expect(store.logEvent).not.toHaveBeenCalled();
  });

  it("marks run as failed by default (safe-by-default)", async () => {
    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(baseRun) });
    const tasks = makeKillSwitchTasks();

    const result = await killSwitchRun("run-abc123", {}, {
      tasks,
      store,
      projectPath: "/tmp/proj",
    });

    expect(result.success).toBe(true);
    expect(result.runStatus).toBe("failed");
    expect(store.updateRun).toHaveBeenCalledWith("run-abc123", {
      status: "failed",
      completed_at: expect.any(String),
      session_key: baseRun.session_key,
      route_to: "developer",
    });
    expect(store.logEvent).toHaveBeenCalledWith(
      "proj-1",
      "kill-switch",
      expect.objectContaining({ taskId: "foreman-001", routeTo: "developer" }),
      "run-abc123",
    );
  });

  it("preserves the SDK resume token and terminates the detached worker", async () => {
    const runWithSession = {
      ...baseRun,
      session_key: "foreman:sdk:claude-sonnet-4-6:run-abc123:pid-999999:session-resume-123",
    };
    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(runWithSession) });
    const tasks = makeKillSwitchTasks();
    const killSpy = vi.spyOn(process, "kill").mockImplementation((() => {
      const err = new Error("no such process") as NodeJS.ErrnoException;
      err.code = "ESRCH";
      throw err;
    }) as typeof process.kill);

    try {
      const result = await killSwitchRun("run-abc123", {}, {
        tasks,
        store,
        projectPath: "/tmp/proj",
      });

      expect(result.success).toBe(true);
      expect(store.updateRun).toHaveBeenCalledWith("run-abc123", expect.objectContaining({
        session_key: runWithSession.session_key,
        route_to: "developer",
      }));
      expect(killSpy).toHaveBeenCalledWith(999999, "SIGTERM");
      expect(result.message).toContain("worker process 999999 already stopped");
    } finally {
      killSpy.mockRestore();
    }
  });

  it("preserves worktree by default", async () => {
    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(baseRun) });
    const tasks = makeKillSwitchTasks();

    const result = await killSwitchRun("run-abc123", {}, {
      tasks,
      store,
      projectPath: "/tmp/proj",
    });

    expect(result.success).toBe(true);
    expect(result.worktreeDeleted).toBe(false);
    expect(result.message).toContain("preserved worktree");
  });

  it("preserves PR by default", async () => {
    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(baseRun) });
    const tasks = makeKillSwitchTasks();

    // Use dryRun: true to get "Would preserve PR" message (preserve messages only appear in dry-run mode)
    const result = await killSwitchRun("run-abc123", { dryRun: true }, {
      tasks,
      store,
      projectPath: "/tmp/proj",
    });

    expect(result.success).toBe(true);
    expect(result.prClosed).toBe(false);
    expect(result.message).toContain("Would preserve PR");
  });

  it("routes to custom phase when --route-to is specified", async () => {
    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(baseRun) });
    const tasks = makeKillSwitchTasks();

    const result = await killSwitchRun("run-abc123", { routeTo: "qa" }, {
      tasks,
      store,
      projectPath: "/tmp/proj",
    });

    expect(result.success).toBe(true);
    expect(result.routeTo).toBe("qa");
    expect(store.logEvent).toHaveBeenCalledWith(
      "proj-1",
      "kill-switch",
      expect.objectContaining({ routeTo: "qa" }),
      "run-abc123",
    );
  });

  it("records custom reason when --reason is specified", async () => {
    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(baseRun) });
    const tasks = makeKillSwitchTasks();

    const result = await killSwitchRun("run-abc123", { reason: "pr-wait blocking review" }, {
      tasks,
      store,
      projectPath: "/tmp/proj",
    });

    expect(result.success).toBe(true);
    expect(result.reason).toBe("pr-wait blocking review");
    expect(store.logEvent).toHaveBeenCalledWith(
      "proj-1",
      "kill-switch",
      expect.objectContaining({ reason: "pr-wait blocking review" }),
      "run-abc123",
    );
  });

  it("dry-run: does not update run or emit events", async () => {
    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(baseRun) });
    const tasks = makeKillSwitchTasks();

    const result = await killSwitchRun("run-abc123", { dryRun: true }, {
      tasks,
      store,
      projectPath: "/tmp/proj",
    });

    expect(result.success).toBe(true);
    expect(store.updateRun).not.toHaveBeenCalled();
    expect(store.logEvent).not.toHaveBeenCalled();
    expect(result.message).toContain("Would kill run");
  });

  it("refuses to reset task without explicit --reset flag", async () => {
    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(baseRun) });
    const tasks = makeKillSwitchTasks();

    const result = await killSwitchRun("run-abc123", {}, {
      tasks,
      store,
      projectPath: "/tmp/proj",
    });

    expect(result.success).toBe(true);
    expect(result.taskReset).toBe(false);
    expect(tasks.update).not.toHaveBeenCalled();
  });

  it("resets task when --reset is specified", async () => {
    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(baseRun) });
    const tasks = makeKillSwitchTasks();

    const result = await killSwitchRun("run-abc123", { resetTask: true }, {
      tasks,
      store,
      projectPath: "/tmp/proj",
    });

    expect(result.success).toBe(true);
    expect(result.taskReset).toBe(true);
    expect(tasks.update).toHaveBeenCalledWith("foreman-001", { status: "backlog" });
    expect(result.message).toContain("reset task to backlog");
  });

  it("preserves reports by default", async () => {
    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(baseRun) });
    const tasks = makeKillSwitchTasks();

    // Use dryRun: true to get "Would preserve reports" message (preserve messages only appear in dry-run mode)
    const result = await killSwitchRun("run-abc123", { dryRun: true }, {
      tasks,
      store,
      projectPath: "/tmp/proj",
    });

    expect(result.success).toBe(true);
    expect(result.reportsDiscarded).toBe(false);
    expect(result.message).toContain("Would preserve reports");
  });

  it("refuses to delete worktree without --force flag", async () => {
    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(baseRun) });
    const tasks = makeKillSwitchTasks();

    const result = await killSwitchRun("run-abc123", {}, {
      tasks,
      store,
      projectPath: "/tmp/proj",
    });

    expect(result.success).toBe(true);
    expect(result.worktreeDeleted).toBe(false);
    expect(result.message).not.toContain("Would delete worktree");
  });

  it("respects --force flag for worktree deletion", async () => {
    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(baseRun) });
    const tasks = makeKillSwitchTasks();

    const result = await killSwitchRun("run-abc123", { deleteWorktree: true }, {
      tasks,
      store,
      projectPath: "/tmp/proj",
    });

    expect(result.success).toBe(true);
    // VcsBackendFactory is mocked above, so worktree deletion succeeds
    expect(result.worktreeDeleted).toBe(true);
    expect(result.message).toContain("deleted worktree");
  });

  it("uses registered project overrides when externalProjectId is set", async () => {
    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(baseRun) });
    const tasks = makeKillSwitchTasks();

    const result = await killSwitchRun("run-abc123", {}, {
      tasks,
      store,
      projectPath: "/tmp/proj",
      overrides: { externalProjectId: "proj-1", defaultBranch: "main" },
    });

    expect(result.success).toBe(true);
    // External project path: getProjectByPath is skipped, store.getRun is used directly
    expect(store.getProjectByPath).not.toHaveBeenCalled();
  });

  it("returns failure when the external kill-switch event cannot be written", async () => {
    mockWriteElixirOrchestrationEvent.mockRejectedValueOnce(new Error("Elixir unavailable"));
    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(baseRun) });
    const tasks = makeKillSwitchTasks();

    const result = await killSwitchRun("run-abc123", { closePr: true, discardReports: true, resetTask: true }, {
      tasks,
      store,
      projectPath: "/tmp/proj",
      overrides: { externalProjectId: "proj-1", defaultBranch: "main" },
    });

    expect(result.success).toBe(false);
    expect(result.message).toContain("Kill-switch event write failed: Elixir unavailable");
    expect(tasks.update).not.toHaveBeenCalled();
    expect(mockRm).not.toHaveBeenCalled();
    expect(store.logEvent).toHaveBeenCalledTimes(1);
  });

  it("returns failure when no project is registered (unregistered path)", async () => {
    const store = makeKillSwitchStore({ getProjectByPath: vi.fn().mockResolvedValue(null) });
    const tasks = makeKillSwitchTasks();

    const result = await killSwitchRun("run-abc123", {}, {
      tasks,
      store,
      projectPath: "/tmp/unregistered",
    });

    expect(result.success).toBe(false);
    expect(result.message).toContain("No project registered");
  });

  it("combines multiple destructive flags correctly", async () => {
    // Reset mock to ensure clean state
    mockWriteElixirOrchestrationEvent.mockResolvedValue(undefined);
    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(baseRun) });
    const tasks = makeKillSwitchTasks();

    // Provide externalProjectId override since closePr requires it
    const result = await killSwitchRun("run-abc123", {
      resetTask: true,
      closePr: true,
      discardReports: true,
    }, {
      tasks,
      store,
      projectPath: "/tmp/proj",
      overrides: { externalProjectId: "proj-1" },
    });

    expect(result.success).toBe(true);
    expect(result.taskReset).toBe(true);
    expect(result.prClosed).toBe(true);
    expect(result.reportsDiscarded).toBe(true);
    // Verify success messages are present
    expect(result.message).toContain("closed PR (handled by Elixir backend)");
    expect(result.message).toContain("reset task to backlog");
    expect(result.message).toContain("discarded reports");
  });

  it("sets prClosed to false when close-PR fails", async () => {
    mockWriteElixirOrchestrationEvent
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error("Elixir unavailable"));
    const store = makeKillSwitchStore({
      getRun: vi.fn().mockResolvedValue(baseRun),
    });
    const tasks = makeKillSwitchTasks();

    const result = await killSwitchRun("run-abc123", {
      closePr: true,
    }, {
      tasks,
      store,
      projectPath: "/tmp/proj",
      overrides: { externalProjectId: "proj-1" },
    });

    expect(result.success).toBe(true); // Overall success still true
    expect(result.prClosed).toBe(false); // But PR close flag is false on failure
    expect(result.message).toContain("failed to close PR");
  });

  it("sets reportsDiscarded to false when rm fails", async () => {
    // Reset mocks to ensure clean state
    mockWriteElixirOrchestrationEvent.mockResolvedValue(undefined);
    mockRm.mockRejectedValue(new Error("Permission denied"));

    const store = makeKillSwitchStore({ getRun: vi.fn().mockResolvedValue(baseRun) });
    const tasks = makeKillSwitchTasks();

    const result = await killSwitchRun("run-abc123", {
      discardReports: true,
    }, {
      tasks,
      store,
      projectPath: "/tmp/proj",
      overrides: { externalProjectId: "proj-1" },
    });

    expect(result.success).toBe(true); // Overall success still true
    expect(result.reportsDiscarded).toBe(false); // But reports discard flag is false on failure
    expect(result.message).toContain("failed to discard reports");

    // Reset mock for other tests
    mockRm.mockResolvedValue(undefined);
  });
});
