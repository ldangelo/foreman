import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type * as WorkflowLoaderModule from "../../lib/workflow-loader.js";

const STANDARD_REMOTE_WORKFLOWS = ["bug", "default", "epic", "feature", "smoke", "task"] as const;

const {
  mockEnsureCliPostgresPool,
  mockRegisterProjectInElixir,
  mockInstallBundledPrompts,
  mockInstallBundledSkills,
  mockInstallBundledWorkflows,
  mockInstallRemoteWorkflows,
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
  mockInstallRemoteWorkflows: vi.fn(),
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

vi.mock("../../lib/workflow-loader.js", async () => {
  const actual = await vi.importActual<typeof WorkflowLoaderModule>(
    "../../lib/workflow-loader.js",
  );

  return {
    ...actual,
    installBundledWorkflows: (...args: unknown[]) => mockInstallBundledWorkflows(...args),
    installRemoteWorkflows: (...args: unknown[]) => mockInstallRemoteWorkflows(...args),
  };
});

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

type InitCommandTestHarness = {
  _actionHandler: (args: unknown[]) => Promise<void>;
  setOptionValue: (key: string, value: unknown) => unknown;
};

async function invokeInit(opts: Record<string, unknown> = {}): Promise<void> {
  const command = initCommand as unknown as InitCommandTestHarness;
  command.setOptionValue("name", opts.name);
  command.setOptionValue("force", opts.force);
  command.setOptionValue("wizard", opts.wizard);
  await command._actionHandler([]);
}

describe("init command", () => {
  const tempDirs: string[] = [];
  let originalCwd: string;
  let exitSpy: ReturnType<typeof vi.spyOn>;

  function makeTempProject(name: string): string {
    const dir = mkdtempSync(join(tmpdir(), `foreman-init-command-${name}-`));
    tempDirs.push(dir);
    mkdirSync(join(dir, ".tasks"), { recursive: true });
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
    mockInstallRemoteWorkflows.mockResolvedValue({
      ok: false,
      reason: "no_url_configured",
      message: "FOREMAN_WORKFLOW_TEMPLATE_URL not set",
    });
    exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
  });

  afterEach(() => {
    process.chdir(originalCwd);
    delete process.env.FOREMAN_MASTER_KEY;
    delete process.env.FOREMAN_HOME;
    delete process.env.FOREMAN_WORKFLOW_TEMPLATE_URL;
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
    for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
    tempDirs.length = 0;
  });

  it("initializes a new project without the wizard and does not open a database pool", async () => {
    const tempProjectDir = makeTempProject("fresh");
    process.chdir(tempProjectDir);
    const projectDir = process.cwd();
    mockRegistryAdd.mockResolvedValue({ id: "proj-1", name: "fresh", path: projectDir, status: "active" });

    await invokeInit({});

    expect(mockExecFileSync).not.toHaveBeenCalled();
    expect(mockInstallBundledPrompts).toHaveBeenCalledWith(projectDir, false);
    expect(mockInstallBundledWorkflows).toHaveBeenCalledWith(projectDir, false);
    expect(mockQuestion).not.toHaveBeenCalled();
    expect(mockPostgresStoreForProject).not.toHaveBeenCalled();
  });

  it("reinstalls bundled assets with force without opening the wizard", async () => {
    const tempProjectDir = makeTempProject("force");
    process.chdir(tempProjectDir);
    const projectDir = process.cwd();

    await invokeInit({ force: true });

    expect(mockInstallBundledPrompts).toHaveBeenCalledWith(projectDir, true);
    expect(mockInstallBundledWorkflows).toHaveBeenCalledWith(projectDir, true);
    expect(mockQuestion).not.toHaveBeenCalled();
  });

  it("continues force init when Elixir reports the project already exists", async () => {
    const tempProjectDir = makeTempProject("elixirexisting");
    process.chdir(tempProjectDir);
    const projectDir = process.cwd();
    mockForemanBackendMode.mockReturnValue("elixir");
    mockRegisterProjectInElixir.mockRejectedValue(new Error('{:already_exists, :project, "proj-existing"}'));

    await expect(invokeInit({ force: true })).resolves.toBeUndefined();

    expect(exitSpy).not.toHaveBeenCalled();
    expect(mockInstallBundledPrompts).toHaveBeenCalledWith(projectDir, true);
    expect(mockInstallBundledWorkflows).toHaveBeenCalledWith(projectDir, true);
  });

  it("runs the wizard when explicitly requested and writes the prompted config", async () => {
    const projectDir = makeTempProject("wizard");
    process.chdir(projectDir);
    mockQuestion
      .mockResolvedValueOnce("git")
      .mockResolvedValueOnce("smoke")
      .mockResolvedValueOnce("github")
      .mockResolvedValueOnce("https://api.github.test")
      .mockResolvedValueOnce("ghp_secret")
      .mockResolvedValueOnce("fortium")
      .mockResolvedValueOnce("foreman")
      .mockResolvedValueOnce("foreman,ready");

    await invokeInit({ wizard: true });

    expect(mockQuestion).toHaveBeenCalled();
    const config = readFileSync(join(projectDir, ".foreman", "config.yaml"), "utf8");
    expect(config).toContain("  backend: git");
    expect(config).toContain("  default: smoke");
    expect(config).toContain("  backend: github");
    expect(config).toContain("    apiUrl: https://api.github.test");
    expect(config).toContain("      - owner: fortium");
    expect(config).toContain("        repo: foreman");
    expect(config).toContain("          - foreman");
    expect(config).toContain("          - ready");
  });

  it("skips legacy registry/store setup for existing projects", async () => {
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
    expect(mockPostgresStoreForProject).not.toHaveBeenCalled();
  });

  it("does not read the legacy registry during node-mode init", async () => {
    const projectDir = makeTempProject("noregistry");
    process.chdir(projectDir);
    mockRegistryList.mockRejectedValue(new Error("database offline"));

    await expect(invokeInit({})).resolves.toBeUndefined();

    expect(exitSpy).not.toHaveBeenCalled();
    expect(mockRegistryList).not.toHaveBeenCalled();
  });

  it("calls remote workflow install and returns the no-url fallback when bundled install is empty and no remote URL is configured", async () => {
    const projectDir = makeTempProject("noremoteurl");
    const foremanHome = join(projectDir, ".foreman-home");
    process.chdir(projectDir);
    process.env.FOREMAN_HOME = foremanHome;
    mockInstallBundledWorkflows.mockReturnValue({ installed: [], skipped: [] });

    await invokeInit({});

    expect(mockInstallRemoteWorkflows).toHaveBeenCalledTimes(1);
    expect(existsSync(join(foremanHome, "workflows"))).toBe(false);
  });

  it("does not call remote workflow install when bundled workflows already installed", async () => {
    const projectDir = makeTempProject("bundledsuccess");
    const foremanHome = join(projectDir, ".foreman-home");
    process.chdir(projectDir);
    process.env.FOREMAN_HOME = foremanHome;
    process.env.FOREMAN_WORKFLOW_TEMPLATE_URL = "https://example.test/workflows";
    mockInstallBundledWorkflows.mockReturnValue({ installed: ["default.yaml"], skipped: [] });

    await invokeInit({});

    expect(mockInstallRemoteWorkflows).not.toHaveBeenCalled();
    expect(existsSync(join(foremanHome, "workflows"))).toBe(false);
  });

  it("calls remote workflow install and preserves written files when bundled workflows are unavailable", async () => {
    const projectDir = makeTempProject("remotesuccess");
    const foremanHome = join(projectDir, ".foreman-home");
    const workflowsDir = join(foremanHome, "workflows");
    process.chdir(projectDir);
    process.env.FOREMAN_HOME = foremanHome;
    process.env.FOREMAN_WORKFLOW_TEMPLATE_URL = "https://example.test/workflows/";
    mockInstallBundledWorkflows.mockReturnValue({ installed: [], skipped: [] });
    mockInstallRemoteWorkflows.mockImplementation(async () => {
      mkdirSync(workflowsDir, { recursive: true });
      for (const workflowName of STANDARD_REMOTE_WORKFLOWS) {
        writeFileSync(
          join(workflowsDir, `${workflowName}.yaml`),
          [
            `name: ${workflowName}`,
            "phases:",
            "  - name: developer",
            "    prompt: developer.md",
          ].join("\n"),
        );
      }

      const installed = [...STANDARD_REMOTE_WORKFLOWS];
      return { ok: true, installed, fromRemote: installed };
    });

    await invokeInit({});

    expect(mockInstallRemoteWorkflows).toHaveBeenCalledTimes(1);
    expect(readdirSync(workflowsDir).sort()).toEqual(
      [...STANDARD_REMOTE_WORKFLOWS].map((name) => `${name}.yaml`),
    );
    expect(readFileSync(join(workflowsDir, "bug.yaml"), "utf8")).toContain("name: bug");
    expect(readFileSync(join(workflowsDir, "task.yaml"), "utf8")).toContain("name: task");
  });

  it("calls remote workflow install but leaves no files when remote fallback reports an HTTP failure", async () => {
    const projectDir = makeTempProject("remotefail");
    const foremanHome = join(projectDir, ".foreman-home");
    process.chdir(projectDir);
    process.env.FOREMAN_HOME = foremanHome;
    process.env.FOREMAN_WORKFLOW_TEMPLATE_URL = "https://example.test/workflows";
    mockInstallBundledWorkflows.mockReturnValue({ installed: [], skipped: [] });
    mockInstallRemoteWorkflows.mockResolvedValue({
      ok: false,
      reason: "http_error",
      message: "Failed to fetch https://example.test/workflows/smoke.yaml: HTTP 404",
    });

    await invokeInit({});

    expect(mockInstallRemoteWorkflows).toHaveBeenCalledTimes(1);
    expect(existsSync(join(foremanHome, "workflows"))).toBe(false);
  });

  it("returns a tagged no-url result when the remote template URL is not configured", async () => {
    const projectDir = makeTempProject("remoteimplnourl");
    const foremanHome = join(projectDir, ".foreman-home");
    process.chdir(projectDir);
    process.env.FOREMAN_HOME = foremanHome;

    const { installRemoteWorkflows } = await vi.importActual<typeof WorkflowLoaderModule>(
      "../../lib/workflow-loader.js",
    );

    const result = await installRemoteWorkflows();

    expect(result).toEqual({
      ok: false,
      reason: "no_url_configured",
      message: "FOREMAN_WORKFLOW_TEMPLATE_URL not set",
    });
    expect(existsSync(join(foremanHome, "workflows"))).toBe(false);
  });

  it("fetches remote workflows with the expected URLs and writes them on success", async () => {
    const projectDir = makeTempProject("remoteimplsuccess");
    const foremanHome = join(projectDir, ".foreman-home");
    const workflowsDir = join(foremanHome, "workflows");
    process.chdir(projectDir);
    process.env.FOREMAN_HOME = foremanHome;
    process.env.FOREMAN_WORKFLOW_TEMPLATE_URL = "https://example.test/workflows/";

    const { installRemoteWorkflows } = await vi.importActual<typeof WorkflowLoaderModule>(
      "../../lib/workflow-loader.js",
    );
    const fetchMock = vi.fn(async (input: string | URL) => {
      const url = String(input);
      const workflowName = url.split("/").pop()?.replace(/\.yaml$/, "") ?? "unknown";
      return new Response(
        [
          `name: ${workflowName}`,
          "phases:",
          "  - name: developer",
          "    prompt: developer.md",
        ].join("\n"),
        { status: 200 },
      );
    });

    const result = await installRemoteWorkflows(fetchMock as typeof globalThis.fetch);

    expect(fetchMock.mock.calls.map(([url]) => String(url))).toEqual(
      STANDARD_REMOTE_WORKFLOWS.map(
        (workflowName) => `https://example.test/workflows/${workflowName}.yaml`,
      ),
    );
    expect(result).toEqual({
      ok: true,
      installed: [...STANDARD_REMOTE_WORKFLOWS],
      fromRemote: [...STANDARD_REMOTE_WORKFLOWS],
    });
    expect(readdirSync(workflowsDir).sort()).toEqual(
      [...STANDARD_REMOTE_WORKFLOWS].map((workflowName) => `${workflowName}.yaml`),
    );
  });

  it("returns a tagged HTTP error with the failing URL and writes no files when any remote fetch fails", async () => {
    const projectDir = makeTempProject("remoteimplfail");
    const foremanHome = join(projectDir, ".foreman-home");
    process.chdir(projectDir);
    process.env.FOREMAN_HOME = foremanHome;
    process.env.FOREMAN_WORKFLOW_TEMPLATE_URL = "https://example.test/workflows";

    const { installRemoteWorkflows } = await vi.importActual<typeof WorkflowLoaderModule>(
      "../../lib/workflow-loader.js",
    );
    const fetchMock = vi.fn(async (input: string | URL) => {
      const url = String(input);
      if (url.endsWith("/smoke.yaml")) {
        return new Response("missing", { status: 404 });
      }

      const workflowName = url.split("/").pop()?.replace(/\.yaml$/, "") ?? "unknown";
      return new Response(
        [
          `name: ${workflowName}`,
          "phases:",
          "  - name: developer",
          "    prompt: developer.md",
        ].join("\n"),
        { status: 200 },
      );
    });

    const result = await installRemoteWorkflows(fetchMock as typeof globalThis.fetch);

    expect(result).toMatchObject({
      ok: false,
      reason: "http_error",
    });
    expect(result.message).toContain("https://example.test/workflows/smoke.yaml");
    expect(existsSync(join(foremanHome, "workflows"))).toBe(false);
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
