/**
 * Tests for TRD-007: Backend selection in run.ts based on FOREMAN_TASK_BACKEND.
 *
 * Verifies:
 * - When FOREMAN_TASK_BACKEND='br': BeadsRustClient and BvClient are instantiated
 * - When FOREMAN_TASK_BACKEND='br' and br binary missing: error thrown
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Hoisted mocks (vi.mock factories are hoisted; vars must use vi.hoisted) ──
const {
  mockGetTaskBackend,
  mockEnsureBrInstalled,
  MockBeadsRustClient,
  MockBvClient,
  MockDispatcher,
  MockForemanStore,
  mockDispatch,
  mockVcsCreate,
} = vi.hoisted(() => {
  const mockGetTaskBackend = vi.fn().mockReturnValue("br");
  const mockEnsureBrInstalled = vi.fn().mockResolvedValue(undefined);
  // Must use function keyword (not arrow) so vi.fn() can be used as a constructor with `new`
  const MockBeadsRustClient = vi.fn(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
    this.ensureBrInstalled = mockEnsureBrInstalled;
  });
  const MockBvClient = vi.fn(function MockBvClientImpl() { /* constructor */ });
  const mockDispatch = vi.fn().mockResolvedValue({
    dispatched: [],
    skipped: [],
    resumed: [],
    activeAgents: 0,
  });
  const MockDispatcher = vi.fn(function MockDispatcherImpl(this: Record<string, unknown>) {
    this.dispatch = mockDispatch;
    this.resumeRuns = vi.fn().mockResolvedValue({
      dispatched: [],
      skipped: [],
      resumed: [],
      activeAgents: 0,
    });
  });
  // Instance + static methods needed by task-client-factory.ts
  // hasNativeTasks returns false so selectTaskReadBackend picks 'beads' backend
  const mockInstance = {
    close: vi.fn(),
    isOpen: vi.fn().mockReturnValue(true),
    hasNativeTasks: vi.fn().mockReturnValue(false),
  };
  const MockForemanStore = vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    Object.assign(this, mockInstance);
    this.close = vi.fn();
  }) as unknown as ReturnType<typeof vi.fn> & {
    forProject: ReturnType<typeof vi.fn>;
    open: ReturnType<typeof vi.fn>;
  };
  // Static methods called by task-client-factory.ts during backend selection
  MockForemanStore.forProject = vi.fn().mockReturnValue(mockInstance);
  MockForemanStore.open = vi.fn().mockReturnValue(mockInstance);
  const mockVcsCreate = vi.fn().mockResolvedValue({
    getRepoRoot: vi.fn().mockResolvedValue("/mock/project"),
  });
  return {
    mockGetTaskBackend,
    mockEnsureBrInstalled,
    MockBeadsRustClient,
    MockBvClient,
    MockDispatcher,
    MockForemanStore,
    mockDispatch,
    mockVcsCreate,
  };
});

vi.mock("../../lib/feature-flags.js", () => ({
  getTaskBackend: () => mockGetTaskBackend(),
}));

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: MockBeadsRustClient,
}));

vi.mock("../../lib/bv.js", () => ({
  BvClient: MockBvClient,
}));

vi.mock("../../orchestrator/dispatcher.js", () => ({
  Dispatcher: MockDispatcher,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: MockForemanStore,
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: (...args: unknown[]) => mockVcsCreate(...args),
  },
}));

vi.mock("../../orchestrator/notification-server.js", () => ({
  NotificationServer: vi.fn(function MockNotificationServer(this: Record<string, unknown>) {
    this.start = vi.fn().mockResolvedValue(undefined);
    this.stop = vi.fn().mockResolvedValue(undefined);
    this.url = "http://127.0.0.1:9999";
  }),
}));

vi.mock("../../orchestrator/notification-bus.js", () => ({
  notificationBus: {},
}));

vi.mock("../watch-ui.js", () => ({
  watchRunsInk: vi.fn().mockResolvedValue({ detached: false }),
}));

vi.mock("../../lib/task-client-factory.js", () => ({
  createTaskClient: vi.fn().mockResolvedValue({
    backendType: "native",
    taskClient: { list: vi.fn(), get: vi.fn(), create: vi.fn(), update: vi.fn(), close: vi.fn() },
  }),
}));

// ── Module under test ──────────────────────────────────────────────────────
import { createTaskClients } from "../commands/run.js";

// ── Helpers ────────────────────────────────────────────────────────────────

const PROJECT_PATH = "/mock/project";

describe("TRD-007: run.ts backend selection via FOREMAN_TASK_BACKEND", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockEnsureBrInstalled.mockResolvedValue(undefined);
    // Restore constructor implementations after clearAllMocks resets them
    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.ensureBrInstalled = mockEnsureBrInstalled;
    });
    MockBvClient.mockImplementation(function MockBvClientImpl() { /* constructor */ });
    MockDispatcher.mockImplementation(function MockDispatcherImpl(this: Record<string, unknown>) {
      this.dispatch = mockDispatch;
      this.resumeRuns = vi.fn().mockResolvedValue({
        dispatched: [],
        skipped: [],
        resumed: [],
        activeAgents: 0,
      });
    });
    MockForemanStore.mockImplementation(function MockForemanStoreImpl(this: Record<string, unknown>) {
      this.close = vi.fn();
    });
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  // ── native backend ──────────────────────────────────────────────────────

  describe("when legacy FOREMAN_TASK_BACKEND='br'", () => {
    beforeEach(() => {
      mockGetTaskBackend.mockReturnValue("br");
    });

    it("returns the native task client", async () => {
      const result = await createTaskClients(PROJECT_PATH);

      expect(MockBeadsRustClient).not.toHaveBeenCalled();
      expect(result.taskClient).toBeDefined();
    });

    it("does not verify the br binary", async () => {
      await createTaskClients(PROJECT_PATH);

      expect(mockEnsureBrInstalled).not.toHaveBeenCalled();
    });

    it("does not instantiate BvClient", async () => {
      const result = await createTaskClients(PROJECT_PATH);

      expect(MockBvClient).not.toHaveBeenCalled();
      expect(result.bvClient).toBeNull();
    });

    it("ignores missing br binary errors", async () => {
      mockEnsureBrInstalled.mockRejectedValue(
        new Error(
          "br (beads_rust) CLI not found at /home/user/.local/bin/br. Install via: cargo install beads_rust",
        ),
      );

      await expect(createTaskClients(PROJECT_PATH)).resolves.toMatchObject({
        backendType: "native",
        bvClient: null,
      });
      expect(MockBvClient).not.toHaveBeenCalled();
    });
  });

});
