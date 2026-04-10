import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

let exitSpy: ReturnType<typeof vi.spyOn>;

const {
  mockStartupVcs,
  mockMergeVcs,
  mockCreateVcs,
  mockEnsureBrInstalled,
  MockBeadsRustClient,
  mockStoreClose,
  mockGetProjectByPath,
  mockGetDb,
  mockGetRun,
  MockForemanStore,
  MockMergeQueue,
  MockRefinery,
  mockResolveProjectBranchPolicy,
  mockLoadProjectConfig,
} = vi.hoisted(() => {
  const mockStartupVcs = {
    getRepoRoot: vi.fn().mockResolvedValue("/mock/project"),
  };

  const mockMergeVcs = {
    name: "jujutsu",
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
  };

  const mockCreateVcs = vi
    .fn()
    .mockResolvedValueOnce(mockStartupVcs)
    .mockResolvedValue(mockMergeVcs);

  const mockEnsureBrInstalled = vi.fn().mockResolvedValue(undefined);
  const MockBeadsRustClient = vi.fn(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
    this.ensureBrInstalled = mockEnsureBrInstalled;
  });

  const mockStoreClose = vi.fn();
  const mockGetProjectByPath = vi.fn().mockReturnValue({ id: "proj-1", path: "/mock/project" });
  const mockGetDb = vi.fn().mockReturnValue({});
  const mockGetRun = vi.fn().mockReturnValue(null);
  const MockForemanStore = vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    this.getProjectByPath = mockGetProjectByPath;
    this.getDb = mockGetDb;
    this.getRun = mockGetRun;
    this.close = mockStoreClose;
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (MockForemanStore as any).forProject = vi.fn(() => new (MockForemanStore as any)());

  const MockMergeQueue = vi.fn(function MockMergeQueueImpl() {});
  const MockRefinery = vi.fn(function MockRefineryImpl() {});
  const mockResolveProjectBranchPolicy = vi.fn().mockResolvedValue({ integrationBranch: "main" });
  const mockLoadProjectConfig = vi.fn().mockReturnValue(null);

  return {
    mockStartupVcs,
    mockMergeVcs,
    mockCreateVcs,
    mockEnsureBrInstalled,
    MockBeadsRustClient,
    mockStoreClose,
    mockGetProjectByPath,
    mockGetDb,
    mockGetRun,
    MockForemanStore,
    MockMergeQueue,
    MockRefinery,
    mockResolveProjectBranchPolicy,
    mockLoadProjectConfig,
  };
});

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: (...args: unknown[]) => mockCreateVcs(...args),
  },
}));

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: MockBeadsRustClient,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: MockForemanStore,
}));

vi.mock("../../orchestrator/merge-queue.js", () => ({
  MergeQueue: MockMergeQueue,
}));

vi.mock("../../orchestrator/refinery.js", () => ({
  Refinery: MockRefinery,
  dryRunMerge: vi.fn(),
}));

vi.mock("../../orchestrator/auto-merge.js", () => ({
  syncBeadStatusAfterMerge: vi.fn(),
}));

vi.mock("../../orchestrator/merge-cost-tracker.js", () => ({
  MergeCostTracker: vi.fn(),
}));

vi.mock("../../lib/project-config.js", () => ({
  loadProjectConfig: mockLoadProjectConfig,
  resolveVcsConfig: vi.fn().mockReturnValue({ backend: "auto" }),
}));

vi.mock("../../lib/branch-policy.js", () => ({
  resolveProjectBranchPolicy: mockResolveProjectBranchPolicy,
}));

vi.mock("../../lib/branch-names.js", () => ({
  getForemanBranchName: vi.fn((seedId: string) => `foreman/${seedId}`),
}));

import { mergeCommand } from "../commands/merge.js";

async function runCommand(args: string[]): Promise<{ stdout: string; stderr: string; error?: Error }> {
  const stdoutLines: string[] = [];
  const stderrLines: string[] = [];
  const origLog = console.log;
  const origWarn = console.warn;
  const origError = console.error;
  let error: Error | undefined;

  console.log = (...a: unknown[]) => stdoutLines.push(a.join(" "));
  console.warn = (...a: unknown[]) => stderrLines.push(a.join(" "));
  console.error = (...a: unknown[]) => stderrLines.push(a.join(" "));

  try {
    await mergeCommand.parseAsync(["node", "foreman", ...args]);
  } catch (caught) {
    error = caught as Error;
  } finally {
    console.log = origLog;
    console.warn = origWarn;
    console.error = origError;
  }

  return { stdout: stdoutLines.join("\n"), stderr: stderrLines.join("\n"), error };
}

describe("merge --resolve --json error handling", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    exitSpy = vi.spyOn(process, "exit").mockImplementation((code?: number | string | null | undefined) => {
      throw new Error(`process.exit unexpectedly called with ${JSON.stringify(code ?? "")}`);
    });

    mockCreateVcs.mockReset();
    mockCreateVcs
      .mockResolvedValueOnce(mockStartupVcs)
      .mockResolvedValue(mockMergeVcs);
    mockGetProjectByPath.mockReturnValue({ id: "proj-1", path: "/mock/project" });
    mockGetRun.mockReturnValue(null);
  });

  afterEach(() => {
    exitSpy.mockRestore();
  });

  it("emits machine-readable JSON when --strategy is missing", async () => {
    const { stderr, error } = await runCommand(["--resolve", "run-123", "--json"]);

    expect(error?.message).toMatch(/process\.exit/);
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(JSON.parse(stderr.split("\n")[0] ?? "")).toEqual({
      error: "--strategy <theirs|abort> is required when using --resolve",
    });
  });

  it("emits machine-readable JSON when strategy is invalid", async () => {
    const { stderr, error } = await runCommand(["--resolve", "run-123", "--strategy", "ours", "--json"]);

    expect(error?.message).toMatch(/process\.exit/);
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(JSON.parse(stderr.split("\n")[0] ?? "")).toEqual({
      error: "Invalid strategy 'ours'. Must be 'theirs' or 'abort'.",
    });
  });

  it("emits machine-readable JSON when run is missing", async () => {
    const { stderr, error } = await runCommand(["--resolve", "run-123", "--strategy", "theirs", "--json"]);

    expect(error?.message).toMatch(/process\.exit/);
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(JSON.parse(stderr.split("\n")[0] ?? "")).toEqual({
      error: "Run 'run-123' not found.",
    });
  });

  it("emits machine-readable JSON when run is not conflicted", async () => {
    mockGetRun.mockReturnValue({
      id: "run-123",
      seed_id: "bd-123",
      status: "completed",
    });

    const { stderr, error } = await runCommand(["--resolve", "run-123", "--strategy", "theirs", "--json"]);

    expect(error?.message).toMatch(/process\.exit/);
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(JSON.parse(stderr.split("\n")[0] ?? "")).toEqual({
      error: "Run 'run-123' is not in conflict state (current status: 'completed'). Only runs with status 'conflict' can be resolved.",
    });
  });
});
