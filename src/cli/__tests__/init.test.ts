import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { buildInitWizardConfig, formatInitDatabaseError, initBackend, initProjectStore, maybeRegisterInitializedProjectInElixir } from "../commands/init.js";

type InitProjectStore = Parameters<typeof initProjectStore>[2];

function makeStore(overrides: Record<string, unknown> = {}) {
  return {
    getProjectByPath: vi.fn().mockReturnValue(null),
    registerProject: vi.fn().mockReturnValue({ id: "proj-new" }),
    getSentinelConfig: vi.fn().mockReturnValue(null),
    upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
    ...overrides,
  } as InitProjectStore;
}

describe("init wizard config", () => {
  it("renders selected VCS backend and workflow template", () => {
    expect(
      buildInitWizardConfig({
        vcsBackend: "jujutsu",
        workflowTemplate: "smoke",
        issueTracker: "beads",
      }),
    ).toContain("backend: jujutsu");
    expect(
      buildInitWizardConfig({
        vcsBackend: "jujutsu",
        workflowTemplate: "smoke",
        issueTracker: "beads",
      }),
    ).toContain("default: smoke");
  });

  it("outputs valid ProjectConfig schema with taskTypeWorkflowMap", () => {
    const config = buildInitWizardConfig({
      vcsBackend: "auto",
      workflowTemplate: "epic",
      issueTracker: "beads",
    });
    // Should use taskTypeWorkflowMap (ProjectConfig schema) not init: block
    expect(config).toContain("taskTypeWorkflowMap:");
    expect(config).toContain("default: epic");
    expect(config).not.toContain("init:");
    expect(config).not.toContain("issueTracker:");
    expect(config).not.toContain("authenticate:");
  });

  it("renders jira issue tracker config when jira is selected", () => {
    const config = buildInitWizardConfig({
      vcsBackend: "git",
      workflowTemplate: "default",
      issueTracker: "jira",
      jira: {
        apiUrl: "https://test.atlassian.net",
        email: "test@example.com",
        apiToken: "encrypted-token",
        projectKey: "PROJ",
        startStatus: ["In Progress"],
      },
    });
    expect(config).toContain("issueTracker:");
    expect(config).toContain("backend: jira");
    expect(config).toContain("apiUrl: https://test.atlassian.net");
    expect(config).toContain("email: test@example.com");
    expect(config).toContain("apiToken: encrypted-token");
    expect(config).toContain("key: PROJ");
    expect(config).toContain("startStatus:");
    expect(config).toContain("- In Progress");
  });

  it("renders github issue tracker config when github is selected", () => {
    const config = buildInitWizardConfig({
      vcsBackend: "git",
      workflowTemplate: "default",
      issueTracker: "github",
      github: {
        apiUrl: "https://api.github.com",
        token: "encrypted-token",
        owner: "myorg",
        repo: "myrepo",
        triggerLabels: ["foreman", "fixme"],
      },
    });
    expect(config).toContain("issueTracker:");
    expect(config).toContain("backend: github");
    expect(config).toContain("apiUrl: https://api.github.com");
    expect(config).toContain("token: encrypted-token");
    expect(config).toContain("owner: myorg");
    expect(config).toContain("repo: myrepo");
    expect(config).toContain("triggerLabels:");
    expect(config).toContain("- foreman");
    expect(config).toContain("- fixme");
  });

  it("does not render issueTracker block when beads is selected", () => {
    const config = buildInitWizardConfig({
      vcsBackend: "auto",
      workflowTemplate: "default",
      issueTracker: "beads",
    });
    expect(config).not.toContain("issueTracker:");
  });
});

describe("initBackend", () => {
  let exitSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
    exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("skips beads init for jira projects", async () => {
    const execSync = vi.fn();
    const checkExists = vi.fn();

    await initBackend({ projectDir: "/tmp/project", issueTracker: "jira", execSync, checkExists });

    expect(execSync).not.toHaveBeenCalled();
    expect(checkExists).not.toHaveBeenCalled();
  });

  it("skips beads init for github projects", async () => {
    const execSync = vi.fn();
    const checkExists = vi.fn();

    await initBackend({ projectDir: "/tmp/project", issueTracker: "github", execSync, checkExists });

    expect(execSync).not.toHaveBeenCalled();
    expect(checkExists).not.toHaveBeenCalled();
  });

  it("runs br init for beads projects when .beads is missing", async () => {
    const execSync = vi.fn();
    const checkExists = vi.fn().mockReturnValue(false);

    await initBackend({ projectDir: "/tmp/project", issueTracker: "beads", execSync, checkExists });

    expect(checkExists).toHaveBeenCalledWith("/tmp/project/.beads");
    expect(execSync).toHaveBeenCalledWith(expect.stringContaining(".local/bin/br"), ["init"], { stdio: "pipe" });
  });

  it("skips br init when the beads workspace already exists", async () => {
    const execSync = vi.fn();
    const checkExists = vi.fn().mockReturnValue(true);

    await initBackend({ projectDir: "/tmp/project", issueTracker: "beads", execSync, checkExists });

    expect(execSync).not.toHaveBeenCalled();
  });

  it("fails fast when br init errors", async () => {
    const execSync = vi.fn(() => {
      throw new Error("br init failed");
    });
    const checkExists = vi.fn().mockReturnValue(false);

    await expect(initBackend({ projectDir: "/tmp/project", issueTracker: "beads", execSync, checkExists })).rejects.toThrow("process.exit(1)");

    expect(exitSpy).toHaveBeenCalledWith(1);
  });
});

describe("initProjectStore — sentinel seeding", () => {
  beforeEach(() => {
    vi.spyOn(console, "log").mockImplementation(() => {});
  });

  it("seeds default sentinel config on fresh project", async () => {
    const store = makeStore();

    await initProjectStore("/my/project", "my-project", store);

    expect(store.getSentinelConfig).toHaveBeenCalledWith("proj-new");
    expect(store.upsertSentinelConfig).toHaveBeenCalledWith("proj-new", {
      branch: "main",
      test_command: "npm test",
      interval_minutes: 30,
      failure_threshold: 2,
      enabled: 1,
    });
  });

  it("awaits async Postgres-backed sentinel config methods", async () => {
    const store = makeStore({
      getProjectByPath: vi.fn().mockResolvedValue(null),
      registerProject: vi.fn().mockResolvedValue({ id: "proj-async" }),
      getSentinelConfig: vi.fn().mockResolvedValue(null),
      upsertSentinelConfig: vi.fn().mockResolvedValue({}),
    });

    await initProjectStore("/my/project", "my-project", store);

    expect(store.registerProject).toHaveBeenCalledWith("my-project", "/my/project");
    expect(store.getSentinelConfig).toHaveBeenCalledWith("proj-async");
    expect(store.upsertSentinelConfig).toHaveBeenCalledWith("proj-async", {
      branch: "main",
      test_command: "npm test",
      interval_minutes: 30,
      failure_threshold: 2,
      enabled: 1,
    });
  });

  it("skips sentinel seeding when config already exists", async () => {
    const store = makeStore({
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-existing" }),
      getSentinelConfig: vi.fn().mockReturnValue({ enabled: 1 }),
    });

    await initProjectStore("/my/project", "my-project", store);

    expect(store.upsertSentinelConfig).not.toHaveBeenCalled();
  });

  it("uses existing project id when project is already registered", async () => {
    const store = makeStore({
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-existing" }),
      getSentinelConfig: vi.fn().mockReturnValue(null),
    });

    await initProjectStore("/my/project", "my-project", store);

    expect(store.getSentinelConfig).toHaveBeenCalledWith("proj-existing");
    expect(store.upsertSentinelConfig).toHaveBeenCalledWith("proj-existing", expect.any(Object));
  });
});

describe("maybeRegisterInitializedProjectInElixir", () => {
  it("registers the initialized project with Elixir in default Elixir mode", async () => {
    process.env.FOREMAN_BACKEND = "elixir";
    const spy = vi.spyOn(await import("../commands/project-task-support.js"), "registerProjectInElixir")
      .mockResolvedValue({ id: "proj-1", name: "my-project", path: "/my/project", defaultBranch: "main", status: "active" });

    await maybeRegisterInitializedProjectInElixir("/my/project", "my-project");

    expect(spy).toHaveBeenCalledWith("/my/project", { name: "my-project", status: "active" });
    spy.mockRestore();
    delete process.env.FOREMAN_BACKEND;
  });

  it("does nothing in explicit node mode", async () => {
    process.env.FOREMAN_BACKEND = "node";
    const spy = vi.spyOn(await import("../commands/project-task-support.js"), "registerProjectInElixir")
      .mockResolvedValue({ id: "proj-1", name: "my-project", path: "/my/project", defaultBranch: "main", status: "active" });

    await maybeRegisterInitializedProjectInElixir("/my/project", "my-project");

    expect(spy).not.toHaveBeenCalled();
    spy.mockRestore();
    delete process.env.FOREMAN_BACKEND;
  });
});

describe("formatInitDatabaseError", () => {
  it("turns missing-password registry failures into actionable guidance", async () => {
    const { DatabaseError } = await import("../../lib/db/pool-manager.js");
    const err = new DatabaseError(
      "Query failed after 4 attempts: SASL: SCRAM-SERVER-FIRST-MESSAGE: client password must be a string",
      "UNKNOWN",
      new Error("SASL: SCRAM-SERVER-FIRST-MESSAGE: client password must be a string"),
    );

    expect(formatInitDatabaseError(err, "/tmp/prompts")).toContain(
      "DATABASE_URL is missing a password for the configured Postgres user.",
    );
    expect(formatInitDatabaseError(err, "/tmp/prompts")).toContain("/tmp/prompts/.env");
  });

  it("includes config validation errors verbatim", async () => {
    const { DatabaseConfigError } = await import("../../lib/db/pool-manager.js");
    const err = new DatabaseConfigError(
      "Invalid DATABASE_URL. User 'foreman' is missing a password.",
      "postgresql://foreman@db.example.com/foreman",
    );

    expect(formatInitDatabaseError(err, "/tmp/prompts")).toContain(
      "Invalid DATABASE_URL. User 'foreman' is missing a password.",
    );
  });
});

// ── installPrompts ────────────────────────────────────────────────────────────

import { describe as describeInstall, it as itInstall, expect as expectInstall } from "vitest";
import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { installPrompts } from "../commands/init.js";

describeInstall("installPrompts", () => {
  itInstall("installs bundled prompts to .foreman/prompts/ on first init", () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "foreman-init-prompts-test-"));
    try {
      process.env["FOREMAN_HOME"] = tmpDir;
      const { installed, skipped } = installPrompts(tmpDir, false);
      expectInstall(installed.length).toBeGreaterThan(0);
      expectInstall(skipped.length).toBe(0);
      // Verify key files exist
      expectInstall(existsSync(join(tmpDir, "prompts", "default", "explorer.md"))).toBe(true);
      expectInstall(existsSync(join(tmpDir, "prompts", "default", "developer.md"))).toBe(true);
      expectInstall(existsSync(join(tmpDir, "prompts", "smoke", "explorer.md"))).toBe(true);
    } finally {
      delete process.env["FOREMAN_HOME"];
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  itInstall("skips existing files when force=false", () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "foreman-init-prompts-skip-"));
    try {
      process.env["FOREMAN_HOME"] = tmpDir;
      // First install
      installPrompts(tmpDir, false);
      // Second install — should skip all
      const { installed, skipped } = installPrompts(tmpDir, false);
      expectInstall(installed.length).toBe(0);
      expectInstall(skipped.length).toBeGreaterThan(0);
    } finally {
      delete process.env["FOREMAN_HOME"];
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  itInstall("overwrites existing files when force=true", () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "foreman-init-prompts-force-"));
    try {
      process.env["FOREMAN_HOME"] = tmpDir;
      installPrompts(tmpDir, false);
      const { installed, skipped } = installPrompts(tmpDir, true);
      expectInstall(installed.length).toBeGreaterThan(0);
      expectInstall(skipped.length).toBe(0);
    } finally {
      delete process.env["FOREMAN_HOME"];
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
