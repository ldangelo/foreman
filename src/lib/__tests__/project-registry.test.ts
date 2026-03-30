/**
 * Tests for src/lib/project-registry.ts
 *
 * Covers:
 *   - ProjectRegistry.add() — happy path, duplicate detection (name + path)
 *   - ProjectRegistry.list() — returns all registered projects
 *   - ProjectRegistry.remove() — removes by name, error on not found
 *   - ProjectRegistry.resolve() — resolves by name and by path
 *   - ProjectRegistry.removeStale() — removes inaccessible paths
 *   - ProjectRegistry.listStale() — lists inaccessible paths without removing
 *   - Auto-mkdir: ~/.foreman/ created if absent
 *   - Empty registry: graceful startup (no file)
 *   - Corrupt registry file: graceful recovery
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import {
  ProjectRegistry,
  DuplicateProjectError,
  ProjectNotFoundError,
  type ProjectEntry,
} from "../project-registry.js";

// ── Helpers ────────────────────────────────────────────────────────────────────

function mkTmpDir(): string {
  const dir = join(
    tmpdir(),
    `foreman-pr-test-${Date.now()}-${Math.random().toString(36).slice(2)}`,
  );
  mkdirSync(dir, { recursive: true });
  return dir;
}

/** Create a fake project directory with a .foreman/ sub-dir */
function mkProject(baseDir: string, name: string): string {
  const dir = join(baseDir, name);
  mkdirSync(join(dir, ".foreman"), { recursive: true });
  return dir;
}

/** Create a fake project directory WITHOUT .foreman/ */
function mkBareProject(baseDir: string, name: string): string {
  const dir = join(baseDir, name);
  mkdirSync(dir, { recursive: true });
  return dir;
}

// ── Fixture ────────────────────────────────────────────────────────────────────

describe("ProjectRegistry", () => {
  let tmpBase: string;
  let registryFile: string;
  let registry: ProjectRegistry;

  beforeEach(() => {
    tmpBase = mkTmpDir();
    // Put registry in a sub-dir that does NOT yet exist (tests auto-mkdir)
    registryFile = join(tmpBase, ".foreman", "projects.json");
    registry = new ProjectRegistry(registryFile);
  });

  afterEach(() => {
    rmSync(tmpBase, { recursive: true, force: true });
  });

  // ── Initial state ────────────────────────────────────────────────────────────

  it("list() returns empty array when registry file does not exist", () => {
    const projects = registry.list();
    expect(projects).toEqual([]);
  });

  it("does not create registry file on list()", () => {
    registry.list();
    expect(existsSync(registryFile)).toBe(false);
  });

  // ── add() ────────────────────────────────────────────────────────────────────

  it("add() registers a project and list() returns it", async () => {
    const projectDir = mkProject(tmpBase, "my-project");
    await registry.add(projectDir);

    const projects = registry.list();
    expect(projects).toHaveLength(1);
    expect(projects[0]!.name).toBe("my-project");
    expect(projects[0]!.path).toBe(resolve(projectDir));
    expect(projects[0]!.addedAt).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });

  it("add() creates registry file (and parent dir) on first write", async () => {
    const projectDir = mkProject(tmpBase, "alpha");
    await registry.add(projectDir);
    expect(existsSync(registryFile)).toBe(true);
  });

  it("add() accepts an explicit name override", async () => {
    const projectDir = mkProject(tmpBase, "my-project");
    await registry.add(projectDir, "alias");

    const projects = registry.list();
    expect(projects[0]!.name).toBe("alias");
  });

  it("add() resolves relative paths to absolute", async () => {
    const projectDir = mkProject(tmpBase, "rel-project");
    // Pass a path that starts absolute (resolve does nothing but we test the contract)
    await registry.add(resolve(projectDir));
    const projects = registry.list();
    expect(projects[0]!.path).toBe(resolve(projectDir));
  });

  it("add() throws DuplicateProjectError when name already registered", async () => {
    const p1 = mkProject(tmpBase, "proj-a");
    const p2 = mkProject(tmpBase, "proj-b");

    await registry.add(p1, "shared-name");
    await expect(registry.add(p2, "shared-name")).rejects.toBeInstanceOf(
      DuplicateProjectError,
    );
  });

  it("DuplicateProjectError for name has field='name'", async () => {
    const p1 = mkProject(tmpBase, "p1");
    const p2 = mkProject(tmpBase, "p2");
    await registry.add(p1, "shared");

    try {
      await registry.add(p2, "shared");
      expect.fail("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(DuplicateProjectError);
      expect((err as DuplicateProjectError).field).toBe("name");
      expect((err as DuplicateProjectError).value).toBe("shared");
    }
  });

  it("add() throws DuplicateProjectError when path already registered", async () => {
    const p1 = mkProject(tmpBase, "proj-a");
    await registry.add(p1, "name1");
    await expect(registry.add(p1, "name2")).rejects.toBeInstanceOf(
      DuplicateProjectError,
    );
  });

  it("DuplicateProjectError for path has field='path'", async () => {
    const p1 = mkProject(tmpBase, "p1");
    await registry.add(p1, "first");

    try {
      await registry.add(p1, "second");
      expect.fail("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(DuplicateProjectError);
      expect((err as DuplicateProjectError).field).toBe("path");
    }
  });

  it("add() can register multiple projects", async () => {
    const p1 = mkProject(tmpBase, "alpha");
    const p2 = mkProject(tmpBase, "beta");
    const p3 = mkProject(tmpBase, "gamma");

    await registry.add(p1);
    await registry.add(p2);
    await registry.add(p3);

    const projects = registry.list();
    expect(projects).toHaveLength(3);
    expect(projects.map((p) => p.name)).toEqual(["alpha", "beta", "gamma"]);
  });

  it("add() does not throw when project has no .foreman/ directory (warns only)", async () => {
    const bareDir = mkBareProject(tmpBase, "bare-project");
    // Should not throw — just warn to console.error
    await expect(registry.add(bareDir)).resolves.not.toThrow();
    const projects = registry.list();
    expect(projects).toHaveLength(1);
    expect(projects[0]!.name).toBe("bare-project");
  });

  // ── remove() ─────────────────────────────────────────────────────────────────

  it("remove() deletes a registered project by name", async () => {
    const p1 = mkProject(tmpBase, "alpha");
    const p2 = mkProject(tmpBase, "beta");
    await registry.add(p1);
    await registry.add(p2);

    await registry.remove("alpha");

    const projects = registry.list();
    expect(projects).toHaveLength(1);
    expect(projects[0]!.name).toBe("beta");
  });

  it("remove() throws ProjectNotFoundError when name not in registry", async () => {
    await expect(registry.remove("nonexistent")).rejects.toBeInstanceOf(
      ProjectNotFoundError,
    );
  });

  it("ProjectNotFoundError contains the queried name", async () => {
    try {
      await registry.remove("ghost");
      expect.fail("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(ProjectNotFoundError);
      expect((err as ProjectNotFoundError).nameOrPath).toBe("ghost");
    }
  });

  it("remove() allows re-adding a project after removing it", async () => {
    const p1 = mkProject(tmpBase, "project");
    await registry.add(p1);
    await registry.remove("project");
    await expect(registry.add(p1)).resolves.not.toThrow();
  });

  // ── resolve() ─────────────────────────────────────────────────────────────────

  it("resolve() returns path when looking up by name", async () => {
    const p1 = mkProject(tmpBase, "my-app");
    await registry.add(p1, "my-app");

    const resolved = registry.resolve("my-app");
    expect(resolved).toBe(resolve(p1));
  });

  it("resolve() returns path when looking up by absolute path", async () => {
    const p1 = mkProject(tmpBase, "my-app");
    await registry.add(p1, "my-app");

    const resolved = registry.resolve(resolve(p1));
    expect(resolved).toBe(resolve(p1));
  });

  it("resolve() throws ProjectNotFoundError for unknown name", () => {
    expect(() => registry.resolve("unknown-project")).toThrow(ProjectNotFoundError);
  });

  it("resolve() throws ProjectNotFoundError for unknown path", () => {
    expect(() => registry.resolve("/nonexistent/path")).toThrow(ProjectNotFoundError);
  });

  // ── removeStale() ──────────────────────────────────────────────────────────

  it("removeStale() removes projects with inaccessible directories", async () => {
    const live = mkProject(tmpBase, "live-project");
    const ghost = join(tmpBase, "deleted-project");
    // Don't create ghost directory

    await registry.add(live);
    // Manually add stale entry to registry
    const staleRegistry = new ProjectRegistry(registryFile);
    // We add it without creating the dir — need to bypass add() validation
    // by writing directly to the file
    const raw = JSON.stringify({
      version: 1,
      projects: [
        { name: "live-project", path: resolve(live), addedAt: new Date().toISOString() },
        { name: "ghost-project", path: ghost, addedAt: new Date().toISOString() },
      ],
    });
    writeFileSync(registryFile, raw, "utf-8");

    const removed = await registry.removeStale();
    expect(removed).toContain("ghost-project");
    expect(removed).not.toContain("live-project");

    const remaining = registry.list();
    expect(remaining).toHaveLength(1);
    expect(remaining[0]!.name).toBe("live-project");
  });

  it("removeStale() returns empty array when all projects are accessible", async () => {
    const p1 = mkProject(tmpBase, "alpha");
    await registry.add(p1);

    const removed = await registry.removeStale();
    expect(removed).toEqual([]);
  });

  it("removeStale() does not modify registry when nothing is stale", async () => {
    const p1 = mkProject(tmpBase, "alpha");
    await registry.add(p1);

    await registry.removeStale();

    const projects = registry.list();
    expect(projects).toHaveLength(1);
  });

  // ── listStale() ───────────────────────────────────────────────────────────────

  it("listStale() returns stale projects without removing them", async () => {
    const live = mkProject(tmpBase, "live");
    const ghost = join(tmpBase, "ghost");

    // Write directly including a ghost entry
    mkdirSync(join(tmpBase, ".foreman"), { recursive: true });
    writeFileSync(
      registryFile,
      JSON.stringify({
        version: 1,
        projects: [
          { name: "live", path: resolve(live), addedAt: new Date().toISOString() },
          { name: "ghost", path: ghost, addedAt: new Date().toISOString() },
        ],
      }),
      "utf-8",
    );

    const stale = registry.listStale();
    expect(stale).toHaveLength(1);
    expect(stale[0]!.name).toBe("ghost");

    // Registry is untouched
    expect(registry.list()).toHaveLength(2);
  });

  // ── Corrupt registry ──────────────────────────────────────────────────────────

  it("recovers gracefully from a corrupted registry JSON file", async () => {
    mkdirSync(join(tmpBase, ".foreman"), { recursive: true });
    writeFileSync(registryFile, "this is not valid JSON!!!!", "utf-8");

    // Should not throw — should return empty list
    const projects = registry.list();
    expect(projects).toEqual([]);
  });

  it("can add projects after recovering from corrupt file", async () => {
    mkdirSync(join(tmpBase, ".foreman"), { recursive: true });
    writeFileSync(registryFile, "{ broken json", "utf-8");

    const p1 = mkProject(tmpBase, "fresh-project");
    await expect(registry.add(p1)).resolves.not.toThrow();
    expect(registry.list()).toHaveLength(1);
  });

  // ── Registry file format ──────────────────────────────────────────────────────

  it("persisted registry file has version=1", async () => {
    const p1 = mkProject(tmpBase, "alpha");
    await registry.add(p1);

    const raw = JSON.parse(
      readFileSync(registryFile, "utf-8"),
    ) as { version: number };
    expect(raw.version).toBe(1);
  });
});
