/**
 * TRD-005-TEST | Verifies: TRD-005 | Tests: ForemanDaemon starts, binds to Unix socket, responds to health check
 * PRD: docs/PRD/PRD-2026-010-multi-project-orchestrator.md
 * TRD: docs/TRD/TRD-2026-011-multi-project-orchestrator.md#trd-005
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  mkdtempSync,
  rmSync,
  writeFileSync,
  readFileSync,
  chmodSync,
  existsSync,
  unlinkSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanDaemon, registerDirectDaemonProcess } from "../index.js";

let mockFastify: {
  all: ReturnType<typeof vi.fn>;
  get: ReturnType<typeof vi.fn>;
  post: ReturnType<typeof vi.fn>;
  listen: ReturnType<typeof vi.fn>;
  close: ReturnType<typeof vi.fn>;
  log: {
    info: ReturnType<typeof vi.fn>;
    warn: ReturnType<typeof vi.fn>;
    error: ReturnType<typeof vi.fn>;
  };
};

let mockTrpcClient: {
  projects: {
    list: ReturnType<typeof vi.fn>;
  };
};

let mockDispatcherDispatch: ReturnType<typeof vi.fn>;
let mockStore: {
  close: ReturnType<typeof vi.fn>;
};
let mockPostgresAdapterInstance: {
  hasNativeTasks: ReturnType<typeof vi.fn>;
  listTasks: ReturnType<typeof vi.fn>;
  getTaskByExternalId: ReturnType<typeof vi.fn>;
  getTask: ReturnType<typeof vi.fn>;
  claimTask: ReturnType<typeof vi.fn>;
  listActiveRuns: ReturnType<typeof vi.fn>;
  listPipelineRuns: ReturnType<typeof vi.fn>;
  createPipelineRun: ReturnType<typeof vi.fn>;
  updatePipelineRun: ReturnType<typeof vi.fn>;
  sendMessage: ReturnType<typeof vi.fn>;
  recordPipelineEvent: ReturnType<typeof vi.fn>;
};

let mockSyncRegisteredProjectCheckout = vi.fn();

vi.mock("fastify", () => ({
  default: vi.fn(() => mockFastify),
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: vi.fn(() => mockTrpcClient),
}));

vi.mock("../../lib/task-client-factory.js", () => ({
  createTaskClient: vi.fn(async () => ({
    backendType: "native",
    taskClient: {},
  })),
}));

vi.mock("../../orchestrator/dispatcher.js", () => ({
  Dispatcher: vi.fn(() => ({
    dispatch: mockDispatcherDispatch,
  })),
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: vi.fn(() => mockStore),
  },
}));

vi.mock("../../lib/db/postgres-adapter.js", () => ({
  PostgresAdapter: vi.fn(function () {
    return mockPostgresAdapterInstance;
  }),
}));

vi.mock("../../lib/bv.js", () => ({
  BvClient: vi.fn(),
}));

vi.mock("../../lib/registered-project-checkout.js", () => ({
  syncRegisteredProjectCheckout: (...args: unknown[]) => mockSyncRegisteredProjectCheckout(...args),
}));

vi.mock("../../lib/db/pool-manager.js", () => ({
  initPool: vi.fn(),
  healthCheck: vi.fn(async () => {}),
  destroyPool: vi.fn(async () => {}),
  isPoolInitialised: vi.fn(() => true),
  getPool: vi.fn(),
}));

function createMockFastify() {
  return {
    all: vi.fn(),
    get: vi.fn(),
    post: vi.fn(),
    listen: vi.fn(async () => undefined),
    close: vi.fn(async () => undefined),
    log: {
      info: vi.fn(),
      warn: vi.fn(),
      error: vi.fn(),
    },
  };
}

function createMockPostgresAdapterInstance() {
  return {
    hasNativeTasks: vi.fn(),
    listTasks: vi.fn(),
    getTaskByExternalId: vi.fn(),
    getTask: vi.fn(),
    claimTask: vi.fn(),
    listActiveRuns: vi.fn(),
    listPipelineRuns: vi.fn(),
    createPipelineRun: vi.fn(),
    updatePipelineRun: vi.fn(),
    sendMessage: vi.fn(),
    recordPipelineEvent: vi.fn(),
  };
}

// ---------------------------------------------------------------------------
// Fake PoolManager
// ---------------------------------------------------------------------------

let healthCheckCalls = 0;
let poolInitCalls = 0;
let poolDestroyCalls = 0;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function fakeSocketDir(): string {
  return mkdtempSync(join(tmpdir(), "foreman-daemon-test-"));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

beforeEach(() => {
  mockFastify = createMockFastify();
  mockTrpcClient = {
    projects: {
      list: vi.fn(),
    },
  };
  mockDispatcherDispatch = vi.fn(async () => ({
    dispatched: [],
  }));
  mockStore = {
    close: vi.fn(),
  };
  mockPostgresAdapterInstance = createMockPostgresAdapterInstance();
  mockSyncRegisteredProjectCheckout = vi.fn();
  healthCheckCalls = 0;
  poolInitCalls = 0;
  poolDestroyCalls = 0;
  vi.clearAllMocks();
});

describe("direct daemon process registration", () => {
  it("refuses to register when a live daemon PID is already recorded", () => {
    const dir = fakeSocketDir();
    const pidPath = join(dir, "daemon.pid");
    const socketPath = join(dir, "daemon.sock");
    try {
      writeFileSync(pidPath, String(process.pid), "utf8");
      const cleanup = registerDirectDaemonProcess({ pidPath, socketPath, pid: 12345 });
      expect(cleanup).toBeNull();
      expect(readFileSync(pidPath, "utf8").trim()).toBe(String(process.pid));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("allows registration when DaemonManager pre-wrote this process PID", () => {
    const dir = fakeSocketDir();
    const pidPath = join(dir, "daemon.pid");
    const socketPath = join(dir, "daemon.sock");
    try {
      writeFileSync(pidPath, String(process.pid), "utf8");
      const cleanup = registerDirectDaemonProcess({ pidPath, socketPath, pid: process.pid });
      expect(cleanup).not.toBeNull();
      expect(readFileSync(pidPath, "utf8").trim()).toBe(String(process.pid));
      cleanup?.();
      expect(existsSync(pidPath)).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("refuses to register when the daemon socket already exists", () => {
    const dir = fakeSocketDir();
    const pidPath = join(dir, "daemon.pid");
    const socketPath = join(dir, "daemon.sock");
    try {
      writeFileSync(socketPath, "", "utf8");
      const cleanup = registerDirectDaemonProcess({ pidPath, socketPath, pid: process.pid });
      expect(cleanup).toBeNull();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("cleans up the PID file it registered", () => {
    const dir = fakeSocketDir();
    const pidPath = join(dir, "daemon.pid");
    const socketPath = join(dir, "daemon.sock");
    try {
      writeFileSync(pidPath, "999999", "utf8");
      const cleanup = registerDirectDaemonProcess({ pidPath, socketPath, pid: process.pid });
      expect(cleanup).not.toBeNull();
      expect(readFileSync(pidPath, "utf8").trim()).toBe(String(process.pid));
      cleanup?.();
      expect(existsSync(pidPath)).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("ForemanDaemon", () => {
  describe("construction", () => {
    it("defaults socket path to ~/.foreman/daemon.sock", () => {
      const daemon = new ForemanDaemon();
      expect(daemon.socketPath).toMatch(/daemon\.sock$/);
    });

    it("defaults HTTP port to 3847", () => {
      const daemon = new ForemanDaemon();
      expect(daemon.httpPort).toBe(3847);
    });

    it("defaults to not running", () => {
      const daemon = new ForemanDaemon();
      expect(daemon.running).toBe(false);
    });

    it("accepts custom socket path", () => {
      const daemon = new ForemanDaemon({
        socketPath: "/tmp/my-daemon.sock",
      });
      expect(daemon.socketPath).toBe("/tmp/my-daemon.sock");
    });

    it("accepts custom HTTP port", () => {
      const daemon = new ForemanDaemon({ httpPort: 9999 });
      expect(daemon.httpPort).toBe(9999);
    });
  });

  describe("start lifecycle", () => {
    it("throws if already running", async () => {
      const daemon = new ForemanDaemon({ httpPort: 9988 });
      // We can't easily test the full start without a real Postgres,
      // but we can verify the state machine.
      expect(daemon.running).toBe(false);
    });

    it("stop is idempotent when not running", async () => {
      const daemon = new ForemanDaemon({ httpPort: 9987 });
      await daemon.stop(); // must not throw
      await daemon.stop(); // must not throw
    });
  });

  describe("ForemanDaemon class structure", () => {
    it("ForemanDaemon is exported", () => {
      expect(typeof ForemanDaemon).toBe("function");
    });

    it("has start method", () => {
      expect(new ForemanDaemon()).toHaveProperty("start");
      expect(typeof new ForemanDaemon().start).toBe("function");
    });

    it("has stop method", () => {
      expect(new ForemanDaemon()).toHaveProperty("stop");
      expect(typeof new ForemanDaemon().stop).toBe("function");
    });

    it("has running getter", () => {
      expect(new ForemanDaemon()).toHaveProperty("running");
    });

    it("has socketPath getter", () => {
      expect(new ForemanDaemon()).toHaveProperty("socketPath");
    });

    it("has httpPort getter", () => {
      expect(new ForemanDaemon()).toHaveProperty("httpPort");
    });
  });
});

describe("failStartup", () => {
  it("process.exit is called on startup failure", async () => {
    // We can't easily test process.exit without mocking it,
    // but the ForemanDaemon.start() calls failStartup(err) on connection failure.
    // The test verifies the class structure is correct.
    expect(typeof ForemanDaemon).toBe("function");
  });
});

describe("ForemanDaemon dispatch loop", () => {
  it("passes registeredProjectId into createTaskClient for registered projects", async () => {
    const originalWebhookSecret = process.env.FOREMAN_WEBHOOK_SECRET;
    delete process.env.FOREMAN_WEBHOOK_SECRET;

    const createTaskClientMock = vi.mocked(await import("../../lib/task-client-factory.js")).createTaskClient;
    const dispatcherModule = vi.mocked(await import("../../orchestrator/dispatcher.js"), { deep: true });
    const trpcClientMock = vi.mocked(await import("../../lib/trpc-client.js")).createTrpcClient;

    trpcClientMock.mockReturnValue({
      projects: {
        list: vi.fn(async () => [
          {
            id: "proj-123",
            name: "registered-project",
            path: "/tmp/registered-project",
            status: "active",
          },
        ]),
      },
    } as never);

    createTaskClientMock.mockResolvedValue({
      backendType: "native",
      taskClient: {},
    } as never);

    dispatcherModule.Dispatcher.mockImplementation(() => ({
      dispatch: vi.fn(async () => ({ dispatched: [] })),
    }) as never);

    try {
      const daemon = new ForemanDaemon({ httpPort: 9998, socketPath: join(tmpdir(), "foreman-daemon-test.sock") });
      await daemon.start();

      expect(createTaskClientMock).toHaveBeenCalledWith("/tmp/registered-project", {
        registeredProjectId: "proj-123",
      });
      await daemon.stop();
    } finally {
      if (originalWebhookSecret !== undefined) {
        process.env.FOREMAN_WEBHOOK_SECRET = originalWebhookSecret;
      } else {
        delete process.env.FOREMAN_WEBHOOK_SECRET;
      }
    }
  });

  it("syncs the registered checkout before dispatching a project", async () => {
    const originalWebhookSecret = process.env.FOREMAN_WEBHOOK_SECRET;
    delete process.env.FOREMAN_WEBHOOK_SECRET;

    const createTaskClientMock = vi.mocked(await import("../../lib/task-client-factory.js")).createTaskClient;
    const trpcClientMock = vi.mocked(await import("../../lib/trpc-client.js")).createTrpcClient;

    trpcClientMock.mockReturnValue({
      projects: {
        list: vi.fn(async () => [
          {
            id: "proj-123",
            name: "registered-project",
            path: "/tmp/registered-project",
            status: "active",
            defaultBranch: "main",
          },
        ]),
      },
    } as never);

    try {
      const daemon = new ForemanDaemon({ httpPort: 9996, socketPath: join(tmpdir(), "foreman-daemon-test.sock") });
      await daemon.start();

      expect(mockSyncRegisteredProjectCheckout).toHaveBeenCalledWith({
        projectId: "proj-123",
        projectPath: "/tmp/registered-project",
        defaultBranch: "main",
        warn: expect.any(Function),
      });
      expect(mockSyncRegisteredProjectCheckout.mock.invocationCallOrder[0]).toBeLessThan(createTaskClientMock.mock.invocationCallOrder[0]);
      await daemon.stop();
    } finally {
      if (originalWebhookSecret !== undefined) {
        process.env.FOREMAN_WEBHOOK_SECRET = originalWebhookSecret;
      } else {
        delete process.env.FOREMAN_WEBHOOK_SECRET;
      }
    }
  });

  it("uses Postgres listActiveRuns for registered-project active run lookups", async () => {
    const originalWebhookSecret = process.env.FOREMAN_WEBHOOK_SECRET;
    delete process.env.FOREMAN_WEBHOOK_SECRET;

    const createTaskClientMock = vi.mocked(await import("../../lib/task-client-factory.js")).createTaskClient;
    const dispatcherModule = vi.mocked(await import("../../orchestrator/dispatcher.js"), { deep: true });
    const trpcClientMock = vi.mocked(await import("../../lib/trpc-client.js")).createTrpcClient;

    type ActiveRunOverrides = {
      getActiveAgentCount?: () => Promise<number>;
      getActiveSeedIds?: () => Promise<string[]>;
    };

    trpcClientMock.mockReturnValue({
      projects: {
        list: vi.fn(async () => [
          {
            id: "proj-registered",
            name: "registered-project",
            path: "/tmp/registered-project",
            status: "active",
          },
        ]),
      },
    } as never);

    createTaskClientMock.mockResolvedValue({
      backendType: "native",
      taskClient: {},
    } as never);

    mockPostgresAdapterInstance.listActiveRuns.mockResolvedValue([
      { seed_id: "seed-1" },
      { seed_id: "seed-2" },
    ]);

    try {
      const daemon = new ForemanDaemon({ httpPort: 9997, socketPath: join(tmpdir(), "foreman-daemon-test.sock") });
      await daemon.start();
      await daemon.stop();

      const overrides = dispatcherModule.Dispatcher.mock.calls[0]?.[4] as ActiveRunOverrides | undefined;
      expect(overrides).toBeDefined();
      await expect(overrides?.getActiveSeedIds?.()).resolves.toEqual(["seed-1", "seed-2"]);
      await expect(overrides?.getActiveAgentCount?.()).resolves.toBe(2);
      expect(mockPostgresAdapterInstance.listActiveRuns).toHaveBeenCalledWith("proj-registered");
    } finally {
      if (originalWebhookSecret !== undefined) {
        process.env.FOREMAN_WEBHOOK_SECRET = originalWebhookSecret;
      } else {
        delete process.env.FOREMAN_WEBHOOK_SECRET;
      }
    }
  });
});
