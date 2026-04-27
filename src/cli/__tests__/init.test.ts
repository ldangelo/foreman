import { describe, it, expect, vi, beforeEach } from "vitest";
import { initProjectStore } from "../commands/init.js";

function makeStore(overrides: Record<string, unknown> = {}) {
  return {
    getProjectByPath: vi.fn().mockReturnValue(null),
    registerProject: vi.fn().mockReturnValue({ id: "proj-new" }),
    getSentinelConfig: vi.fn().mockReturnValue(null),
    upsertSentinelConfig: vi.fn().mockReturnValue({}),
    ...overrides,
  } as unknown as import("../../lib/store.js").ForemanStore;
}

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
