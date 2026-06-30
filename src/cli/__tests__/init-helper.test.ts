import { beforeEach, describe, expect, it, vi } from "vitest";

const { mockRegisterProjectInElixir, mockForemanBackendMode } = vi.hoisted(() => ({
  mockRegisterProjectInElixir: vi.fn(),
  mockForemanBackendMode: vi.fn(),
}));

vi.mock("../commands/project-task-support.js", () => ({
  ensureCliPostgresPool: vi.fn(),
  registerProjectInElixir: (...args: unknown[]) => mockRegisterProjectInElixir(...args),
}));

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: (...args: unknown[]) => mockForemanBackendMode(...args),
}));

import {
  buildInitWizardConfig,
  formatInitDatabaseError,
  initBackend,
  initProjectStore,
  maybeRegisterInitializedProjectInElixir,
} from "../commands/init.js";
import { DatabaseConfigError, DatabaseError } from "../../lib/db/pool-manager.js";

describe("init helpers", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
    mockForemanBackendMode.mockReturnValue("node");
    mockRegisterProjectInElixir.mockResolvedValue({ id: "proj-1" });
  });

  it("buildInitWizardConfig emits Jira config with normalized project key", () => {
    const yaml = buildInitWizardConfig({
      vcsBackend: "git",
      workflowTemplate: "default",
      issueTracker: "jira",
      jira: {
        apiUrl: "https://jira.example.test",
        email: "dev@example.test",
        apiToken: "enc-token",
        projectKey: "abc",
        startStatus: ["In Progress", "To Do"],
      },
    });

    expect(yaml).toContain("backend: git");
    expect(yaml).toContain("default: default");
    expect(yaml).toContain("backend: jira");
    expect(yaml).toContain("apiToken: enc-token");
    expect(yaml).toContain("- key: ABC");
    expect(yaml).toContain("- In Progress");
  });

  it("buildInitWizardConfig emits GitHub config", () => {
    const yaml = buildInitWizardConfig({
      vcsBackend: "auto",
      workflowTemplate: "smoke",
      issueTracker: "github",
      github: {
        apiUrl: "https://api.github.com",
        token: "enc-gh-token",
        owner: "acme",
        repo: "foreman",
        triggerLabels: ["foreman", "fixme"],
      },
    });

    expect(yaml).toContain("backend: github");
    expect(yaml).toContain("token: enc-gh-token");
    expect(yaml).toContain("owner: acme");
    expect(yaml).toContain("repo: foreman");
    expect(yaml).toContain("- foreman");
    expect(yaml).toContain("- fixme");
  });

  it("initBackend skips beads init for non-beads trackers", async () => {
    const execSync = vi.fn();

    await initBackend({ projectDir: "/tmp/project", issueTracker: "jira", execSync });

    expect(execSync).not.toHaveBeenCalled();
    expect(vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("Skipping beads init");
  });

  it("initBackend skips when .beads already exists", async () => {
    const execSync = vi.fn();

    await initBackend({
      projectDir: "/tmp/project",
      issueTracker: "beads",
      execSync,
      checkExists: (path) => path.endsWith(".beads"),
    });

    expect(execSync).not.toHaveBeenCalled();
    expect(vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n")).toContain("already exists");
  });

  it("initProjectStore seeds sentinel config only when missing", async () => {
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue(null),
      registerProject: vi.fn().mockResolvedValue({ id: "proj-1" }),
      getSentinelConfig: vi.fn().mockResolvedValue(null),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
    };

    await initProjectStore("/tmp/project", "demo", store as any);

    expect(store.registerProject).toHaveBeenCalledWith("demo", "/tmp/project");
    expect(store.upsertSentinelConfig).toHaveBeenCalledWith("proj-1", expect.objectContaining({ enabled: 1, branch: "main" }));
  });

  it("initProjectStore reuses existing project and existing sentinel config", async () => {
    const store = {
      getProjectByPath: vi.fn().mockResolvedValue({ id: "proj-existing" }),
      registerProject: vi.fn(),
      getSentinelConfig: vi.fn().mockResolvedValue({ enabled: 1 }),
      upsertSentinelConfig: vi.fn(),
    };

    await initProjectStore("/tmp/project", "demo", store as any);

    expect(store.registerProject).not.toHaveBeenCalled();
    expect(store.upsertSentinelConfig).not.toHaveBeenCalled();
  });

  it("maybeRegisterInitializedProjectInElixir only runs in Elixir mode", async () => {
    mockForemanBackendMode.mockReturnValue("node");
    await maybeRegisterInitializedProjectInElixir("/tmp/project", "demo");
    expect(mockRegisterProjectInElixir).not.toHaveBeenCalled();

    mockForemanBackendMode.mockReturnValue("elixir");
    await maybeRegisterInitializedProjectInElixir("/tmp/project", "demo");
    expect(mockRegisterProjectInElixir).toHaveBeenCalledWith("/tmp/project", { name: "demo", status: "active" });
  });

  it("formatInitDatabaseError expands config and password guidance", () => {
    const projectDir = "/tmp/project";
    const configMsg = formatInitDatabaseError(new DatabaseConfigError("DATABASE_URL missing", ""), projectDir);
    expect(configMsg).toContain("Failed to initialize the Postgres-backed project registry.");
    expect(configMsg).toContain("DATABASE_URL missing");
    expect(configMsg).toContain("/tmp/project/.env");

    const passwordMsg = formatInitDatabaseError(new DatabaseError("client password must be a string", "DB_ERROR", new Error("bad password")), projectDir);
    expect(passwordMsg).toContain("missing a password");
    expect(passwordMsg).toContain("postgresql://user:password@host:5432/database");
  });
});
