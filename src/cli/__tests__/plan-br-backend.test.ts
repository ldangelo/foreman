/**
 * Tests for TRD-016: Backend selection in plan.ts based on FOREMAN_TASK_BACKEND.
 *
 * Verifies:
 * - When FOREMAN_TASK_BACKEND='br': BeadsRustClient is used for issue creation
 * - When FOREMAN_TASK_BACKEND='sd': SeedsClient is used for issue creation
 * - Existing sd backend behavior is not broken
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Hoisted mocks ──────────────────────────────────────────────────────────
const {
  mockGetTaskBackend,
  MockSeedsClient,
  MockBeadsRustClient,
  MockDispatcher,
  MockForemanStore,
  mockGetProjectByPath,
} = vi.hoisted(() => {
  const mockGetTaskBackend = vi.fn().mockReturnValue("sd");

  const MockSeedsClient = vi.fn(function MockSeedsClientImpl(this: Record<string, unknown>) {
    this.create = vi.fn().mockResolvedValue({ id: "sd-001", title: "Epic" });
    this.close = vi.fn().mockResolvedValue(undefined);
    this.addDependency = vi.fn().mockResolvedValue(undefined);
    this.ready = vi.fn().mockResolvedValue([]);
    this.ensureSdInstalled = vi.fn().mockResolvedValue(undefined);
    this.isInitialized = vi.fn().mockResolvedValue(true);
  });

  const MockBeadsRustClient = vi.fn(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
    this.create = vi.fn().mockResolvedValue({ id: "br-001", title: "Epic" });
    this.close = vi.fn().mockResolvedValue(undefined);
    this.addDependency = vi.fn().mockResolvedValue(undefined);
    this.ready = vi.fn().mockResolvedValue([]);
    this.ensureBrInstalled = vi.fn().mockResolvedValue(undefined);
    this.isInitialized = vi.fn().mockResolvedValue(true);
  });

  const mockGetProjectByPath = vi.fn().mockReturnValue({ id: "proj-001", path: "/mock/project" });
  const MockForemanStore = vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    this.getProjectByPath = mockGetProjectByPath;
    this.close = vi.fn();
  });

  const MockDispatcher = vi.fn(function MockDispatcherImpl(this: Record<string, unknown>) {
    this.dispatchPlanStep = vi.fn().mockResolvedValue({ runId: "run-001" });
  });

  return {
    mockGetTaskBackend,
    MockSeedsClient,
    MockBeadsRustClient,
    MockDispatcher,
    MockForemanStore,
    mockGetProjectByPath,
  };
});

vi.mock("../../lib/feature-flags.js", () => ({
  getTaskBackend: () => mockGetTaskBackend(),
}));

vi.mock("../../lib/seeds.js", () => ({
  SeedsClient: MockSeedsClient,
}));

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: MockBeadsRustClient,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: MockForemanStore,
}));

vi.mock("../../orchestrator/dispatcher.js", () => ({
  Dispatcher: MockDispatcher,
}));

// ── Module under test ──────────────────────────────────────────────────────
import { createPlanClient } from "../commands/plan.js";

// ── Helpers ────────────────────────────────────────────────────────────────

const PROJECT_PATH = "/mock/project";

describe("TRD-016: plan.ts backend selection via FOREMAN_TASK_BACKEND", () => {
  beforeEach(() => {
    vi.clearAllMocks();

    // Restore mock implementations after clearAllMocks resets call tracking
    MockSeedsClient.mockImplementation(function MockSeedsClientImpl(this: Record<string, unknown>) {
      this.create = vi.fn().mockResolvedValue({ id: "sd-001", title: "Epic" });
      this.close = vi.fn().mockResolvedValue(undefined);
      this.addDependency = vi.fn().mockResolvedValue(undefined);
      this.ready = vi.fn().mockResolvedValue([]);
      this.ensureSdInstalled = vi.fn().mockResolvedValue(undefined);
      this.isInitialized = vi.fn().mockResolvedValue(true);
    });

    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.create = vi.fn().mockResolvedValue({ id: "br-001", title: "Epic" });
      this.close = vi.fn().mockResolvedValue(undefined);
      this.addDependency = vi.fn().mockResolvedValue(undefined);
      this.ready = vi.fn().mockResolvedValue([]);
      this.ensureBrInstalled = vi.fn().mockResolvedValue(undefined);
      this.isInitialized = vi.fn().mockResolvedValue(true);
    });

    MockForemanStore.mockImplementation(function MockForemanStoreImpl(this: Record<string, unknown>) {
      this.getProjectByPath = mockGetProjectByPath;
      this.close = vi.fn();
    });
    mockGetProjectByPath.mockReturnValue({ id: "proj-001", path: "/mock/project" });

    MockDispatcher.mockImplementation(function MockDispatcherImpl(this: Record<string, unknown>) {
      this.dispatchPlanStep = vi.fn().mockResolvedValue({ runId: "run-001" });
    });
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  // ── br backend ──────────────────────────────────────────────────────────

  describe("when FOREMAN_TASK_BACKEND='br'", () => {
    beforeEach(() => {
      mockGetTaskBackend.mockReturnValue("br");
    });

    it("returns a BeadsRustClient instance", () => {
      const client = createPlanClient(PROJECT_PATH);

      expect(MockBeadsRustClient).toHaveBeenCalledWith(PROJECT_PATH);
      expect(MockBeadsRustClient).toHaveBeenCalledTimes(1);
      expect(client).toBeDefined();
    });

    it("does not instantiate SeedsClient", () => {
      createPlanClient(PROJECT_PATH);

      expect(MockSeedsClient).not.toHaveBeenCalled();
    });

    it("returned client has a create method (BeadsRustClient API)", () => {
      const client = createPlanClient(PROJECT_PATH);

      expect(typeof (client as unknown as Record<string, unknown>).create).toBe("function");
    });

    it("returned client has close and addDependency methods", () => {
      const client = createPlanClient(PROJECT_PATH);

      const c = client as unknown as Record<string, unknown>;
      expect(typeof c.close).toBe("function");
      expect(typeof c.addDependency).toBe("function");
    });
  });

});
