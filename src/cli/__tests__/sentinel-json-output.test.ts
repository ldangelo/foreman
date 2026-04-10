import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

let exitSpy: ReturnType<typeof vi.spyOn>;

const {
  mockCreateVcs,
  mockGetRepoRoot,
  mockStoreClose,
  mockGetProjectByPath,
  mockGetSentinelRuns,
  mockGetSentinelConfig,
  MockForemanStore,
  MockProjectRegistry,
  mockInspectFleetHealth,
} = vi.hoisted(() => {
  const mockGetRepoRoot = vi.fn().mockResolvedValue("/mock/project");
  const mockCreateVcs = vi.fn().mockResolvedValue({
    getRepoRoot: mockGetRepoRoot,
  });

  const mockStoreClose = vi.fn();
  const mockGetProjectByPath = vi.fn().mockReturnValue({ id: "proj-1", path: "/mock/project" });
  const mockGetSentinelRuns = vi.fn().mockReturnValue([]);
  const mockGetSentinelConfig = vi.fn().mockReturnValue(null);

  const MockForemanStore = vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    this.getProjectByPath = mockGetProjectByPath;
    this.getSentinelRuns = mockGetSentinelRuns;
    this.getSentinelConfig = mockGetSentinelConfig;
    this.close = mockStoreClose;
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (MockForemanStore as any).forProject = vi.fn(() => new (MockForemanStore as any)());

  const MockProjectRegistry = vi.fn(function MockProjectRegistryImpl(this: Record<string, unknown>) {
    this.list = vi.fn().mockReturnValue([]);
  });

  const mockInspectFleetHealth = vi.fn().mockReturnValue([]);

  return {
    mockCreateVcs,
    mockGetRepoRoot,
    mockStoreClose,
    mockGetProjectByPath,
    mockGetSentinelRuns,
    mockGetSentinelConfig,
    MockForemanStore,
    MockProjectRegistry,
    mockInspectFleetHealth,
  };
});

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: mockCreateVcs,
  },
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: MockForemanStore,
}));

vi.mock("../../lib/project-registry.js", () => ({
  ProjectRegistry: MockProjectRegistry,
}));

vi.mock("../../orchestrator/fleet-monitor.js", () => ({
  inspectFleetHealth: mockInspectFleetHealth,
}));

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: vi.fn(),
}));

vi.mock("../../orchestrator/integration-validator.js", () => ({
  IntegrationValidator: vi.fn(),
}));

import { sentinelCommand } from "../commands/sentinel.js";

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
    await sentinelCommand.parseAsync(["node", "foreman", ...args]);
  } catch (caught) {
    error = caught as Error;
  } finally {
    console.log = origLog;
    console.warn = origWarn;
    console.error = origError;
  }

  return { stdout: stdoutLines.join("\n"), stderr: stderrLines.join("\n"), error };
}

describe("sentinel status --json", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    exitSpy = vi.spyOn(process, "exit").mockImplementation((code?: number | string | null | undefined) => {
      throw new Error(`process.exit unexpectedly called with ${JSON.stringify(code ?? "")}`);
    });

    mockCreateVcs.mockResolvedValue({ getRepoRoot: mockGetRepoRoot });
    mockGetProjectByPath.mockReturnValue({ id: "proj-1", path: "/mock/project" });
    mockGetSentinelRuns.mockReturnValue([]);
    mockGetSentinelConfig.mockReturnValue(null);
    mockInspectFleetHealth.mockReturnValue([]);
  });

  afterEach(() => {
    exitSpy.mockRestore();
  });

  it("outputs valid JSON for project status", async () => {
    mockGetSentinelConfig.mockReturnValue({
      branch: "main",
      test_command: "npm test",
      interval_minutes: 30,
      failure_threshold: 2,
      enabled: 1,
      pid: 4242,
    });
    mockGetSentinelRuns.mockReturnValue([
      {
        id: "sent-1",
        project_id: "proj-1",
        status: "passed",
        started_at: "2026-04-09T10:00:00Z",
        completed_at: "2026-04-09T10:00:10Z",
        commit_hash: "abcdef1234567890",
      },
    ]);

    const { stdout, stderr } = await runCommand(["status", "--json"]);
    const data = JSON.parse(stdout);

    expect(stderr).toBe("");
    expect(data.config.branch).toBe("main");
    expect(data.runs).toHaveLength(1);
    expect(data.runs[0].status).toBe("passed");
  });

  it("emits a machine-readable error when project is not initialized", async () => {
    mockGetProjectByPath.mockReturnValue(null);

    const { stderr, error } = await runCommand(["status", "--json"]);

    expect(error?.message).toMatch(/process\.exit/);
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(JSON.parse(stderr.split("\n")[0] ?? "")).toEqual({ error: "project not initialized. Run `foreman init` first." });
  });

  it("emits a machine-readable error when fleet inspection fails", async () => {
    mockInspectFleetHealth.mockImplementation(() => {
      throw new Error("fleet inspection failed");
    });

    const { stderr, error } = await runCommand(["status", "--all", "--json"]);

    expect(error?.message).toMatch(/process\.exit/);
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(JSON.parse(stderr.split("\n")[0] ?? "")).toEqual({ error: "fleet inspection failed" });
  });
});
