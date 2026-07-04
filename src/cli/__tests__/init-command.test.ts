import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const {
  mockEnsureCliPostgresPool,
  mockRegisterProjectInElixir,
  mockInstallBundledPrompts,
  mockInstallBundledSkills,
  mockInstallBundledWorkflows,
  mockForemanBackendMode,
  mockRegistryList,
  mockRegistryAdd,
  mockPostgresStoreForProject,
  mockQuestion,
  mockRlClose,
  mockExecFileSync,
} = vi.hoisted(() => ({
  mockEnsureCliPostgresPool: vi.fn(),
  mockRegisterProjectInElixir: vi.fn(),
  mockInstallBundledPrompts: vi.fn(),
  mockInstallBundledSkills: vi.fn(),
  mockInstallBundledWorkflows: vi.fn(),
  mockForemanBackendMode: vi.fn(),
  mockRegistryList: vi.fn(),
  mockRegistryAdd: vi.fn(),
  mockPostgresStoreForProject: vi.fn(),
  mockQuestion: vi.fn(),
  mockRlClose: vi.fn(),
  mockExecFileSync: vi.fn(),
}));

vi.mock("node:child_process", () => ({
  execFileSync: (...args: unknown[]) => mockExecFileSync(...args),
}));

vi.mock("../commands/project-task-support.js", () => ({
  ensureCliPostgresPool: (...args: unknown[]) => mockEnsureCliPostgresPool(...args),
  registerProjectInElixir: (...args: unknown[]) => mockRegisterProjectInElixir(...args),
}));

vi.mock("../../lib/prompt-loader.js", () => ({
  installBundledPrompts: (...args: unknown[]) => mockInstallBundledPrompts(...args),
  installBundledSkills: (...args: unknown[]) => mockInstallBundledSkills(...args),
}));

vi.mock("../../lib/workflow-loader.js", () => ({
  installBundledWorkflows: (...args: unknown[]) => mockInstallBundledWorkflows(...args),
  BUNDLED_WORKFLOW_NAMES: ["default", "epic", "smoke"],
}));

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: (...args: unknown[]) => mockForemanBackendMode(...args),
}));

vi.mock("node:readline/promises", () => ({
  createInterface: () => ({
    question: (...args: unknown[]) => mockQuestion(...args),
    close: (...args: unknown[]) => mockRlClose(...args),
  }),
}));

vi.mock("../../lib/project-registry.js", () => ({
  ProjectRegistry: vi.fn().mockImplementation(function MockProjectRegistry() {
    return {
      list: mockRegistryList,
      add: mockRegistryAdd,
    };
  }),
}));

vi.mock("../../lib/postgres-store.js", () => ({
  PostgresStore: {
    forProject: (...args: unknown[]) => mockPostgresStoreForProject(...args),
  },
}));

vi.mock("ora", () => ({
  default: () => {
    const spinner = {
      start: vi.fn().mockReturnThis(),
      succeed: vi.fn(),
      info: vi.fn(),
      fail: vi.fn(),
      warn: vi.fn(),
      text: "",
    };
    return spinner;
  },
}));

import { initCommand } from "../commands/init.js";

async function invokeInit(opts: Record<string, unknown> = {}): Promise<void> {
  await (initCommand as unknown as { _actionHandler: (args: unknown[]) => Promise<void> })._actionHandler([opts]);
}

describe("init command", () => {
  const tempDirs: string[] = [];
  let originalCwd: string;
  let exitSpy: ReturnType<typeof vi.spyOn>;

  function makeTempProject(name: string): string {
    const dir = mkdtempSync(join(tmpdir(), `foreman-init-command-${name}-`));
    tempDirs.push(dir);
    mkdirSync(join(dir, ".beads"), { recursive: true });
    return dir;
  }

  beforeEach(() => {
    vi.clearAllMocks();
    originalCwd = process.cwd();
    mockForemanBackendMode.mockReturnValue("node");
    mockQuestion.mockResolvedValue("");
    mockRegistryList.mockResolvedValue([]);
    mockRegistryAdd.mockResolvedValue({ id: "proj-1", name: "demo", path: "/tmp/project", status: "active" });
    mockPostgresStoreForProject.mockReturnValue({
      getSentinelConfig: vi.fn().mockResolvedValue(null),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      close: vi.fn(),
    });
    mockInstallBundledPrompts.mockReturnValue({ installed: ["default/developer.md"], skipped: [] });
    mockInstallBundledSkills.mockReturnValue({ installed: [] });
    mockInstallBundledWorkflows.mockReturnValue({ installed: [], skipped: ["default.yaml"] });
    mockRegisterProjectInElixir.mockResolvedValue({ id: "proj-1" });
    process.env.FOREMAN_MASTER_KEY = Buffer.alloc(32, 1).toString("base64");
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
  });

  afterEach(() => {
    process.chdir(originalCwd);
    delete process.env.FOREMAN_MASTER_KEY;
    vi.restoreAllMocks();
    for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
    tempDirs.length = 0;
  });

  it("initializes a new project without the wizard and registers it in Postgres", async () => {
    const projectDir = makeTempProject("fresh");
    process.chdir(projectDir);
    mockRegistryAdd.mockResolvedValue({ id: "proj-1", name: "fresh", path: projectDir, status: "active" });

    await invokeInit({});

    expect(mockExecFileSync).toHaveBeenCalledWith(
      process.execPath,
      expect.arrayContaining([expect.stringContaining("node-pg-migrate"), "up"]),
      expect.objectContaining({ stdio: "pipe" }),
    );
    expect(mockInstallBundledPrompts).toHaveBeenCalled();
    expect(mockPostgresStoreForProject).toHaveBeenCalledWith("proj-1");
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Foreman initialized successfully!");
  });

  it("reuses an existing registry project instead of adding a duplicate", async () => {
    const projectDir = makeTempProject("existing");
    process.chdir(projectDir);
    mockRegistryList.mockResolvedValue([{ id: "proj-existing", name: projectDir.split("/").pop(), path: projectDir, status: "active" }]);
    mockPostgresStoreForProject.mockReturnValue({
      getSentinelConfig: vi.fn().mockResolvedValue({ enabled: 1 }),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      close: vi.fn(),
    });

    await invokeInit({});

    expect(mockRegistryAdd).not.toHaveBeenCalled();
    expect(mockPostgresStoreForProject).toHaveBeenCalledWith("proj-existing");
  });

  it("fails with formatted database errors during registry setup", async () => {
    const projectDir = makeTempProject("dbfail");
    process.chdir(projectDir);
    mockRegistryList.mockRejectedValue(new Error("database offline"));

    await expect(invokeInit({})).rejects.toThrow("process.exit(1)");

    expect(exitSpy).toHaveBeenCalledWith(1);
    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Failed to initialize the Postgres database schema or project registry.");
    expect(rendered).toContain("database offline");
  });

  it("fails closed when Elixir project registration errors", async () => {
    const projectDir = makeTempProject("elixirfail");
    process.chdir(projectDir);
    mockForemanBackendMode.mockReturnValue("elixir");
    mockRegisterProjectInElixir.mockRejectedValue(new Error("elixir registry unavailable"));

    await expect(invokeInit({})).rejects.toThrow("process.exit(1)");

    expect(exitSpy).toHaveBeenCalledWith(1);
    const rendered = vi.mocked(console.error).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("elixir registry unavailable");
  });
});
