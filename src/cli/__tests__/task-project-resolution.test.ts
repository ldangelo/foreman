/**
 * Tests for `--project` flag resolution in `foreman task` CLI commands.
 *
 * Covers REQ-016 / AC-016:
 *   - AC-016.1: `--project <name>` resolves via ProjectRegistry.resolve()
 *   - AC-016.2: `--project /absolute/path` (not in registry) warns and proceeds
 *   - AC-016.3: `--project <unknown-name>` exits with error code 1
 *   - AC-016.4: no `--project` flag defaults to process.cwd()
 *
 * Tests the `resolveProjectPath` helper used by all task subcommands.
 *
 * Uses NativeTaskStore directly (no subprocess) for speed.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdirSync, rmSync, writeFileSync, rmSync as rmSyncAlt } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir, homedir } from "node:os";
import chalk from "chalk";
import { ProjectRegistry } from "../../lib/project-registry.js";
import { resolveProjectPath } from "../../lib/project-path.js";
import { ForemanStore } from "../../lib/store.js";
import { NativeTaskStore } from "../../lib/task-store.js";

// ── Test helpers ──────────────────────────────────────────────────────────────

function mkTmpDir(): string {
  const dir = join(
    tmpdir(),
    `foreman-task-pr-test-${Date.now()}-${Math.random().toString(36).slice(2)}`,
  );
  mkdirSync(dir, { recursive: true });
  return dir;
}

/** Create a fake project directory with a .foreman/ sub-dir */
function mkProjectDir(baseDir: string, name: string): string {
  const dir = join(baseDir, name);
  mkdirSync(join(dir, ".foreman"), { recursive: true });
  return dir;
}

/**
 * Build a temporary projects.json registry file for testing.
 * Returns the path to the registry file.
 */
function buildRegistry(tmpBase: string, projects: Array<{ name: string; path: string }>): string {
  // Write to the actual home directory path that ProjectRegistry uses.
  // We use the real homedir() since it cannot be stubbed in vitest.
  const registryDir = join(homedir(), ".foreman", "projects");
  mkdirSync(registryDir, { recursive: true });
  const registryPath = join(registryDir, "projects.json");
  writeFileSync(
    registryPath,
    JSON.stringify({
      version: 1,
      projects: projects.map((p) => ({
        name: p.name,
        path: p.path,
        addedAt: new Date().toISOString(),
      })),
    }) + "\n",
    "utf-8",
  );
  return registryPath;
}

// ── resolveProjectPath test suite ─────────────────────────────────────────────

describe("resolveProjectPath (--project flag resolution)", () => {
  let tmpBase: string;
  let originalHome: string | undefined;
  let originalExit: typeof process.exit;
  let originalError: typeof console.error;
  let originalWarn: typeof console.warn;

  beforeEach(() => {
    tmpBase = mkTmpDir();
    originalExit = process.exit;
    originalError = console.error;
    originalWarn = console.warn;

    // Capture exit calls instead of actually exiting
    vi.stubGlobal("process", {
      ...process,
      exit: vi.fn((code?: number) => {
        throw new Error(`process.exit called with code: ${code}`);
      }) as typeof process.exit,
    });
    // Spy on console.error and console.warn
    console.error = vi.fn();
    console.warn = vi.fn();
  });

  afterEach(() => {
    process.exit = originalExit;
    console.error = originalError;
    console.warn = originalWarn;
    rmSync(tmpBase, { recursive: true, force: true });
    // Clean up real home directory registry
    rmSyncAlt(join(homedir(), ".foreman", "projects"), {
      recursive: true,
      force: true,
    });
    vi.restoreAllMocks();
  });

  // ── AC-016.4 ─────────────────────────────────────────────────────────────────

  it("AC-016.4: no --project flag returns process.cwd()", () => {
    const cwd = tmpBase;
    buildRegistry(tmpBase, []);
    vi.stubGlobal("process", {
      ...process,
      cwd: () => cwd,
    });

    const result = resolveProjectPath({});
    expect(result).toBe(cwd);
  });

  // ── AC-016.1 ─────────────────────────────────────────────────────────────────

  it("AC-016.1: --project <registered-name> resolves via ProjectRegistry.resolve()", () => {
    const projectDir = mkProjectDir(tmpBase, "my-app");
    buildRegistry(tmpBase, [
      { name: "my-app", path: resolve(projectDir) },
    ]);
    const result = resolveProjectPath({ project: "my-app" });
    expect(result).toBe(resolve(projectDir));
  });

  // ── AC-016.2 ─────────────────────────────────────────────────────────────────

  it("AC-016.2: --project /absolute/path (not in registry) warns and proceeds", () => {
    const unregisteredPath = join(tmpBase, "unregistered-project");
    mkdirSync(join(unregisteredPath, ".foreman"), { recursive: true });

    buildRegistry(tmpBase, []);
    const result = resolveProjectPath({ project: unregisteredPath });
    expect(result).toBe(unregisteredPath);
    expect(console.warn).toHaveBeenCalledWith(
      chalk.yellow("`--project` with an absolute path is deprecated; use `--project-path` instead."),
    );
  });

  // ── AC-016.3 ─────────────────────────────────────────────────────────────────

  it("AC-016.3: --project <unknown-name> exits with error code 1", () => {
    buildRegistry(tmpBase, []);
    expect(() => resolveProjectPath({ project: "unknown-project" })).toThrow(
      "process.exit called with code: 1",
    );
    expect(console.error).toHaveBeenCalledWith(
      chalk.red(
        `Project 'unknown-project' not found. Run 'foreman project list' to see registered projects.`,
      ),
    );
  });

  // ── Additional cases ──────────────────────────────────────────────────────────

  it("resolves project by exact path match in registry", () => {
    const projectDir = mkProjectDir(tmpBase, "path-test");
    const resolvedPath = resolve(projectDir);
    const registryPath = buildRegistry(tmpBase, [
      { name: "path-test", path: resolvedPath },
    ]);
    const registry = new ProjectRegistry(registryPath);

    // Direct path lookup should work
    const result = registry.resolve(resolvedPath);
    expect(result).toBe(resolvedPath);
  });

  it("relative path (not in registry, not absolute) exits with code 1", () => {
    buildRegistry(tmpBase, []);
    // Relative path without registry entry should trigger error exit
    expect(() => resolveProjectPath({ project: "relative/path" })).toThrow(
      "process.exit called with code: 1",
    );
  });

  it("multiple registered projects — resolves correct one by name", () => {
    const projectA = mkProjectDir(tmpBase, "project-a");
    const projectB = mkProjectDir(tmpBase, "project-b");
    const projectC = mkProjectDir(tmpBase, "project-c");

    buildRegistry(tmpBase, [
      { name: "proj-a", path: resolve(projectA) },
      { name: "proj-b", path: resolve(projectB) },
      { name: "proj-c", path: resolve(projectC) },
    ]);
    expect(resolveProjectPath({ project: "proj-b" })).toBe(resolve(projectB));
    expect(resolveProjectPath({ project: "proj-c" })).toBe(resolve(projectC));
  });
});

describe("getTaskStore helper", () => {
  let tmpBase: string;

  beforeEach(() => {
    tmpBase = mkTmpDir();
  });

  afterEach(() => {
    rmSync(tmpBase, { recursive: true, force: true });
  });

  it("opens a foreman.db at the correct project path", () => {
    const projectDir = mkProjectDir(tmpBase, "test-project");

    const store = ForemanStore.forProject(projectDir);
    const taskStore = new NativeTaskStore(store.getDb());

    // Should be able to create a task in the newly opened store
    const task = taskStore.create({ title: "Test Task" });
    expect(task.title).toBe("Test Task");
    expect(task.status).toBe("backlog");

    store.close();
  });

  it("separate project dirs have separate databases", () => {
    const projectA = mkProjectDir(tmpBase, "project-a");
    const projectB = mkProjectDir(tmpBase, "project-b");

    const storeA = ForemanStore.forProject(projectA);
    const storeB = ForemanStore.forProject(projectB);
    const taskStoreA = new NativeTaskStore(storeA.getDb());
    const taskStoreB = new NativeTaskStore(storeB.getDb());

    taskStoreA.create({ title: "Task in A" });
    taskStoreB.create({ title: "Task in B" });

    // Each store has only its own tasks
    expect(taskStoreA.list()).toHaveLength(1);
    expect(taskStoreA.list()[0]!.title).toBe("Task in A");
    expect(taskStoreB.list()).toHaveLength(1);
    expect(taskStoreB.list()[0]!.title).toBe("Task in B");

    storeA.close();
    storeB.close();
  });
});
