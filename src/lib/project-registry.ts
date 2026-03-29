/**
 * Global Project Registry for Foreman multi-project orchestration.
 *
 * Manages a JSON registry at `~/.foreman/projects.json` that maps project
 * names to filesystem paths, enabling cross-project operations.
 *
 * Registry schema:
 * ```json
 * {
 *   "version": 1,
 *   "projects": [
 *     {
 *       "name": "foreman",
 *       "path": "/Users/user/Development/foreman",
 *       "addedAt": "2026-03-29T00:00:00Z"
 *     }
 *   ]
 * }
 * ```
 *
 * @module src/lib/project-registry
 */

import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  accessSync,
  constants as fsConstants,
} from "node:fs";
import { dirname, resolve, basename, normalize } from "node:path";
import { homedir } from "node:os";

// ── Types ─────────────────────────────────────────────────────────────────────

/** A single registered project entry. */
export interface ProjectEntry {
  /** Short human-readable alias for the project. */
  name: string;
  /** Absolute filesystem path to the project root. */
  path: string;
  /** ISO 8601 timestamp when the project was added to the registry. */
  addedAt: string;
}

/** Shape of the `~/.foreman/projects.json` file. */
export interface ProjectRegistryFile {
  /** Schema version — currently always `1`. */
  version: number;
  /** Ordered list of registered projects. */
  projects: ProjectEntry[];
}

// ── Error classes ─────────────────────────────────────────────────────────────

/**
 * Thrown when attempting to add a project that is already registered
 * (either by the same name or the same resolved path).
 */
export class DuplicateProjectError extends Error {
  constructor(
    public readonly field: "name" | "path",
    public readonly value: string,
  ) {
    super(
      field === "name"
        ? `Project '${value}' is already registered`
        : `Path '${value}' is already registered as a project`,
    );
    this.name = "DuplicateProjectError";
  }
}

/**
 * Thrown when resolving a project name or path that is not in the registry.
 */
export class ProjectNotFoundError extends Error {
  constructor(public readonly nameOrPath: string) {
    super(`Project '${nameOrPath}' not found in registry`);
    this.name = "ProjectNotFoundError";
  }
}

// ── Default registry path ─────────────────────────────────────────────────────

/**
 * Returns the default path to the global registry file: `~/.foreman/projects.json`.
 */
function defaultRegistryPath(): string {
  return resolve(homedir(), ".foreman", "projects.json");
}

// ── ProjectRegistry class ─────────────────────────────────────────────────────

/**
 * Manages the global Foreman project registry stored at `~/.foreman/projects.json`.
 *
 * All write operations use a read-modify-write pattern for atomicity.
 * The registry directory (`~/.foreman/`) is created automatically on first write.
 */
export class ProjectRegistry {
  private readonly registryPath: string;

  /**
   * @param registryPath - Override the registry file location (default: `~/.foreman/projects.json`).
   *                       Useful for testing with temporary directories.
   */
  constructor(registryPath?: string) {
    this.registryPath = registryPath ?? defaultRegistryPath();
  }

  // ── Private helpers ──────────────────────────────────────────────────────────

  /**
   * Load the registry file from disk.
   * Returns an empty registry if the file does not yet exist.
   */
  private loadRegistry(): ProjectRegistryFile {
    if (!existsSync(this.registryPath)) {
      return { version: 1, projects: [] };
    }

    try {
      const raw = readFileSync(this.registryPath, "utf-8");
      const parsed = JSON.parse(raw) as unknown;
      return this.validateRegistryFile(parsed);
    } catch (err) {
      if (err instanceof SyntaxError) {
        // Corrupted JSON — start fresh (log warning)
        console.error(
          `[ProjectRegistry] Warning: registry file is corrupted (${String(err.message)}). Starting fresh.`,
        );
        return { version: 1, projects: [] };
      }
      throw err;
    }
  }

  /**
   * Validate a raw parsed registry file.
   * Returns a well-typed `ProjectRegistryFile` on success.
   */
  private validateRegistryFile(raw: unknown): ProjectRegistryFile {
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
      return { version: 1, projects: [] };
    }

    const obj = raw as Record<string, unknown>;
    const version = typeof obj["version"] === "number" ? obj["version"] : 1;
    const projectsRaw = Array.isArray(obj["projects"]) ? obj["projects"] : [];

    const projects: ProjectEntry[] = projectsRaw
      .filter(
        (p): p is Record<string, unknown> =>
          typeof p === "object" && p !== null && !Array.isArray(p),
      )
      .filter(
        (p) => typeof p["name"] === "string" && typeof p["path"] === "string",
      )
      .map((p) => ({
        name: p["name"] as string,
        path: p["path"] as string,
        addedAt:
          typeof p["addedAt"] === "string" ? p["addedAt"] : new Date().toISOString(),
      }));

    return { version, projects };
  }

  /**
   * Persist the registry to disk.
   * Creates the parent directory (`~/.foreman/`) if it does not exist.
   */
  private saveRegistry(data: ProjectRegistryFile): void {
    const dir = dirname(this.registryPath);
    mkdirSync(dir, { recursive: true });
    writeFileSync(this.registryPath, JSON.stringify(data, null, 2) + "\n", "utf-8");
  }

  /**
   * Derive a project name from a directory path.
   * Uses `basename()` — e.g. `/Users/user/my-project` → `my-project`.
   */
  private deriveName(projectPath: string): string {
    return basename(normalize(projectPath));
  }

  // ── Public API ───────────────────────────────────────────────────────────────

  /**
   * Register a project in the global registry.
   *
   * @param projectPath - Absolute or relative path to the project root.
   *                      Will be resolved to an absolute path.
   * @param name        - Optional alias. If omitted, derived from the directory basename.
   * @throws {DuplicateProjectError} If a project with the same name or resolved path already exists.
   */
  async add(projectPath: string, name?: string): Promise<void> {
    const resolvedPath = resolve(projectPath);
    const projectName = name ?? this.deriveName(resolvedPath);

    const registry = this.loadRegistry();

    // Check for duplicate name
    const existingByName = registry.projects.find((p) => p.name === projectName);
    if (existingByName !== undefined) {
      throw new DuplicateProjectError("name", projectName);
    }

    // Check for duplicate path
    const existingByPath = registry.projects.find((p) => p.path === resolvedPath);
    if (existingByPath !== undefined) {
      throw new DuplicateProjectError("path", resolvedPath);
    }

    // Warn if no .foreman/ directory (project not yet initialized with foreman)
    const foremanDir = resolve(resolvedPath, ".foreman");
    if (!existsSync(foremanDir)) {
      console.error(
        `[ProjectRegistry] Warning: '${resolvedPath}' has no .foreman/ directory. ` +
          `Run 'foreman init' inside the project before using it with foreman.`,
      );
    }

    registry.projects.push({
      name: projectName,
      path: resolvedPath,
      addedAt: new Date().toISOString(),
    });

    this.saveRegistry(registry);
  }

  /**
   * Return all registered projects.
   */
  list(): ProjectEntry[] {
    return this.loadRegistry().projects;
  }

  /**
   * Remove a registered project from the registry by name.
   *
   * @param name - The project alias to remove.
   * @throws {ProjectNotFoundError} If no project with that name is registered.
   */
  async remove(name: string): Promise<void> {
    const registry = this.loadRegistry();

    const index = registry.projects.findIndex((p) => p.name === name);
    if (index === -1) {
      throw new ProjectNotFoundError(name);
    }

    registry.projects.splice(index, 1);
    this.saveRegistry(registry);
  }

  /**
   * Resolve a project name or path to an absolute filesystem path.
   *
   * Resolution order:
   * 1. Exact match on `name`
   * 2. Exact match on `path`
   *
   * @param nameOrPath - Registry name or absolute path to resolve.
   * @returns The absolute path of the registered project.
   * @throws {ProjectNotFoundError} If the name/path is not found in the registry.
   */
  resolve(nameOrPath: string): string {
    const registry = this.loadRegistry();

    // Try exact name match first
    const byName = registry.projects.find((p) => p.name === nameOrPath);
    if (byName !== undefined) {
      return byName.path;
    }

    // Try exact path match (resolve in case it's relative)
    const resolvedInput = resolve(nameOrPath);
    const byPath = registry.projects.find((p) => p.path === resolvedInput);
    if (byPath !== undefined) {
      return byPath.path;
    }

    throw new ProjectNotFoundError(nameOrPath);
  }

  /**
   * Remove all projects whose directories are no longer accessible.
   *
   * A project is considered stale if its path does not exist or is not readable.
   *
   * @returns Array of project names that were removed.
   */
  async removeStale(): Promise<string[]> {
    const registry = this.loadRegistry();

    const stale: ProjectEntry[] = [];
    const active: ProjectEntry[] = [];

    for (const project of registry.projects) {
      if (!this.isAccessible(project.path)) {
        stale.push(project);
      } else {
        active.push(project);
      }
    }

    if (stale.length > 0) {
      registry.projects = active;
      this.saveRegistry(registry);
    }

    return stale.map((p) => p.name);
  }

  /**
   * Return all projects whose directories are no longer accessible (without removing them).
   */
  listStale(): ProjectEntry[] {
    const registry = this.loadRegistry();
    return registry.projects.filter((p) => !this.isAccessible(p.path));
  }

  /**
   * Check whether a project path is accessible (exists and is readable).
   */
  private isAccessible(projectPath: string): boolean {
    try {
      accessSync(projectPath, fsConstants.R_OK);
      return true;
    } catch {
      return false;
    }
  }
}
