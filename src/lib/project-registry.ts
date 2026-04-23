/**
 * ProjectRegistry — project metadata store with JSON + Postgres dual-write.
 *
 * Architecture:
 * - JSON file at `~/.foreman/projects/projects.json` is the source of truth.
 *   All reads and writes go through this file.
 * - Postgres (via PostgresAdapter) is a query mirror for fast listing and filtering.
 *   It is updated after JSON write succeeds, but Postgres failure is non-fatal.
 *
 * Design decisions:
 * - Dual-write: JSON first (must succeed), Postgres second (warning on failure).
 *   This means the file system is always authoritative — a corrupted Postgres
 *   can be rebuilt from JSON, but not vice versa.
 * - In-memory cache invalidated on every write — no TTL, no background refresh.
 *   Registry writes are infrequent (add/remove/sync), so this is acceptable.
 * - Project IDs are deterministic from the normalized name + random hex suffix.
 *   Collision resistance comes from the 5-char hex suffix (16^5 = ~1M combos).
 * - Health check runs `git fetch --quiet` in the clone directory with 5s timeout.
 *   This is a "fast" health indicator — network latency or large repos affect it.
 *
 * @module project-registry
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFile, writeFile, mkdir, access, constants } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { basename, dirname, join, resolve as pathResolve } from "node:path";
import { homedir } from "node:os";
import { randomBytes } from "node:crypto";
import type { PostgresAdapter } from "./db/postgres-adapter.js";

const execFileAsync = promisify(execFile);

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** Sub-directory under baseDir for project data. */
const PROJECTS_SUBDIR = "projects";
const PROJECTS_JSON = "projects.json";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface ProjectRecord {
  /** Stable ID derived from normalized name, e.g. `foreman-a3f2b`. */
  id: string;
  /** Display name, e.g. `foreman`. */
  name: string;
  /** Absolute clone path, e.g. `/Users/…/.foreman/projects/foreman-a3f2b`. */
  path: string;
  /** GitHub repository URL. */
  githubUrl: string;
  /** Canonical lowercased owner/repo key for GitHub-backed projects. */
  repoKey?: string | null;
  /** Default branch name, e.g. `main`. */
  defaultBranch: string;
  /** Project lifecycle status. */
  status: "active" | "paused" | "archived";
  createdAt: string; // ISO 8601
  updatedAt: string; // ISO 8601
  lastSyncAt: string | null; // ISO 8601
}

export interface ProjectMetadata {
  name: string;
  path: string;
  githubUrl?: string;
  repoKey?: string | null;
  defaultBranch?: string;
  status?: "active" | "paused" | "archived";
  /** Updated by sync(). Not required in input. */
  lastSyncAt?: string | null;
}

// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------

export class ProjectRegistryError extends Error {
  override readonly name = "ProjectRegistryError" as string;
}

export class ProjectNotFoundError extends ProjectRegistryError {
  override readonly name = "ProjectNotFoundError" as string;
  /** The name or path that was looked up and not found. */
  readonly nameOrPath: string;
  constructor(nameOrPath: string) {
    super(`Project not found: '${nameOrPath}'`);
    this.nameOrPath = nameOrPath;
  }
}

export class ProjectIdCollisionError extends ProjectRegistryError {
  override readonly name = "ProjectIdCollisionError" as string;
  /** Which field caused the collision. */
  readonly field: "name" | "path";
  /** The conflicting value. */
  readonly value: string;
  constructor(field: "name" | "path", value: string) {
    super(`A project with ${field} '${value}' already exists in the registry`);
    this.field = field;
    this.value = value;
  }
}

export class ProjectRegistryJsonError extends ProjectRegistryError {
  override readonly name = "ProjectRegistryJsonError" as string;
  constructor(message: string, cause?: unknown) {
    super(message);
    if (cause instanceof Error) {
      (this as unknown as { cause: unknown }).cause = cause;
    }
  }
}

/**
 * Error thrown when a project name or path is already registered.
 * Alias for ProjectIdCollisionError for backward compatibility.
 */
export class DuplicateProjectError extends ProjectRegistryError {
  override readonly name = "DuplicateProjectError" as string;
  /** Which field caused the collision. */
  readonly field: "name" | "path";
  /** The conflicting value. */
  readonly value: string;
  constructor(field: "name" | "path", value: string) {
    super(`Duplicate project: ${field} '${value}'`);
    this.field = field;
    this.value = value;
  }
}

/**
 * Backward-compatible project entry used by old consumers.
 * Alias for ProjectRecord with the fields that old code expected.
 */
export interface ProjectEntry {
  name: string;
  path: string;
  addedAt: string;
}

/**
 * Stale project — a registry entry whose clone path is no longer accessible.
 */
export interface StaleProject {
  name: string;
  path: string;
}

/**
 * Legacy project entry format from `~/.foreman/projects.json` (old v1 format).
 */
interface LegacyProjectEntry {
  name: string;
  path: string;
  addedAt?: string;
  githubUrl?: string;
  defaultBranch?: string;
}

// ---------------------------------------------------------------------------
// ProjectRegistry
// ---------------------------------------------------------------------------

export interface ProjectRegistryOptions {
  /** Override the base directory. Defaults to `~/.foreman`. */
  baseDir?: string;
  /** Override PostgresAdapter instance. Defaults to module-level singleton. */
  pg?: PostgresAdapter;
  /** Override the JSON file path (for testing). */
  jsonPath?: string;
}

export class ProjectRegistry {
  private readonly baseDir: string;
  private readonly jsonFilePath: string;
  private readonly pg: PostgresAdapter | null;
  /** In-memory cache — null means cache is invalidated (needs re-read). */
  private cache: ProjectRecord[] | null = null;

  /**
   * Construct a ProjectRegistry.
   *
   * Accepts either:
   * - A string path (old API, backward compat) — treated as `jsonPath`
   * - An options object (new API)
   * - No argument (defaults to `~/.foreman/projects/projects.json`)
   */
  constructor(options: ProjectRegistryOptions | string = {}) {
    if (typeof options === "string") {
      // Old API: `new ProjectRegistry(registryPath: string)`
      this.jsonFilePath = options;
      this.baseDir = dirname(options);
      this.pg = null;
    } else {
    this.baseDir = options.baseDir ??
      process.env.FOREMAN_REGISTRY_BASE_DIR ??
      join(homedir(), ".foreman");
    this.jsonFilePath =
      options.jsonPath ??
      join(this.baseDir, PROJECTS_SUBDIR, PROJECTS_JSON);
      this.pg = options.pg ?? null;
    }
  }

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  /** Ensure the projects directory and JSON file directory exist. */
  private async ensureDir(): Promise<void> {
    const dir = dirname(this.jsonFilePath);
    await mkdir(dir, { recursive: true });
  }

  /** Read and parse the JSON registry file. Returns `[]` if file doesn't exist. */
  private async readJson(): Promise<ProjectRecord[]> {
    try {
      const content = await readFile(this.jsonFilePath, "utf8");
      const parsed = JSON.parse(content);

      // Support both old format ({ version, projects[] }) and new format (array)
      if (!Array.isArray(parsed)) {
        const legacy = parsed as { version?: number; projects?: unknown[] };
        if (typeof legacy?.version === "number" && Array.isArray(legacy?.projects)) {
          // Old format — migrate to new flat array
          return this.migrateLegacyRecords(legacy.projects as LegacyProjectEntry[]);
        }
        throw new ProjectRegistryJsonError(
          `Invalid projects.json: expected array, got ${typeof parsed}`
        );
      }
      return parsed as ProjectRecord[];
    } catch (err: unknown) {
      if ((err as NodeJS.ErrnoException).code === "ENOENT") {
        return [];
      }
      if (err instanceof ProjectRegistryJsonError) throw err;
      // Corrupt JSON file — recover gracefully by returning empty list
      // (matching old behavior for backward compatibility)
      console.warn(
        `[ProjectRegistry] Corrupted projects.json (${(err as Error).message}), ` +
          "returning empty registry. Data may need to be re-imported."
      );
      return [];
    }
  }

  /**
   * Migrate legacy { version, projects[] } format to new flat array format.
   * The old `addedAt` becomes `createdAt` and `updatedAt`.
   */
  private migrateLegacyRecords(
    entries: LegacyProjectEntry[]
  ): ProjectRecord[] {
    const now = new Date().toISOString();
    return entries.map((entry) => ({
      id: this.generateProjectId(entry.name),
      name: entry.name,
      path: entry.path,
      githubUrl: (entry as LegacyProjectEntry & { githubUrl?: string }).githubUrl ?? "",
      repoKey: null,
      defaultBranch: (entry as LegacyProjectEntry & { defaultBranch?: string }).defaultBranch ?? "main",
      status: "active" as const,
      createdAt: entry.addedAt ?? now,
      updatedAt: now,
      lastSyncAt: null,
    }));
  }

  /**
   * Write the JSON registry file atomically: write to a temp file first,
   * then rename to the target path. This avoids corruption on write failure.
   */
  private async writeJson(records: ProjectRecord[]): Promise<void> {
    await this.ensureDir();
    const tmpPath = `${this.jsonFilePath}.tmp.${Date.now()}`;
    try {
      await writeFile(tmpPath, JSON.stringify(records, null, 2), "utf8");
      await access(tmpPath, constants.W_OK); // verify write succeeded
      // Atomic rename on POSIX; this is close enough on macOS
      const { rename } = await import("node:fs/promises");
      await rename(tmpPath, this.jsonFilePath);
    } catch (err: unknown) {
      try {
        const { unlink } = await import("node:fs/promises");
        await unlink(tmpPath).catch(() => {});
      } catch {
        // ignore
      }
      throw new ProjectRegistryJsonError(
        `Failed to write projects.json: ${(err as Error).message}`,
        err
      );
    }
  }

  /** Invalidate the in-memory cache. Call after any write. */
  private invalidateCache(): void {
    this.cache = null;
  }

  private projectRowToRecord(row: import("./db/postgres-adapter.js").ProjectRow): ProjectRecord {
    return {
      id: row.id,
      name: row.name,
      path: row.path,
      githubUrl: row.github_url ?? "",
      repoKey: row.repo_key,
      defaultBranch: row.default_branch ?? "main",
      status: row.status,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
      lastSyncAt: row.last_sync_at,
    };
  }

  private async writeJsonMirror(records: ProjectRecord[]): Promise<void> {
    try {
      await this.writeJson(records);
      this.invalidateCache();
    } catch (err) {
      console.warn(
        `[ProjectRegistry] JSON mirror write failed: ${(err as Error).message}. ` +
          "Postgres source of truth remains current."
      );
    }
  }

  // -------------------------------------------------------------------------
  // ID generation
  // -------------------------------------------------------------------------

  /**
   * Generate a stable project ID from a name.
   *
   * Format: `<normalized-name>-<hex5>`
   * - Normalize: lowercase, replace non-alphanumeric with dashes,
   *   collapse consecutive dashes, trim leading/trailing dashes.
   * - Hex5: 5 random hex chars for collision resistance.
   *
   * Examples:
   *   `Foreman Dashboard` → `foreman-dashboard-a3f2b`
   *   `my-api-v2`         → `my-api-v2-c91fe`
   *   `React⚛️App`        → `react-app-7f2a1`
   */
  generateProjectId(name: string): string {
    const normalized = name
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .replace(/-+/g, "-");

    const hex5 = randomBytes(3)
      .toString("hex")
      .slice(0, 5);

    return `${normalized}-${hex5}`;
  }

  // -------------------------------------------------------------------------
  // CRUD operations
  // -------------------------------------------------------------------------

  /**
   * Add a new project to the registry.
   *
   * Supports both the new API (ProjectMetadata object) and the old API
   * (path string with optional name override) for backward compatibility.
   *
   * Writes to JSON first (source of truth), then Postgres (query mirror).
   * Throws if JSON write fails (source of truth would be inconsistent).
   * Logs a warning (does not throw) if Postgres write fails.
   *
   * @param metadata - Project metadata (new API)
   * @param name - Optional name override (old API second arg — ignored when metadata is object)
   */
  async add(
    metadata: ProjectMetadata | string,
    name?: string
  ): Promise<ProjectRecord> {
    let path: string;
    let projectName: string;
    let githubUrl: string;
    let repoKey: string | null;
    let defaultBranch: string;

    if (typeof metadata === "string") {
      // Old API: add(path: string, name?: string)
      path = metadata;
      projectName = name ?? basename(metadata);
      githubUrl = "";
      repoKey = null;
      defaultBranch = "main";
    } else {
      // New API: add(metadata: ProjectMetadata)
      path = metadata.path;
      projectName = metadata.name;
      githubUrl = metadata.githubUrl ?? "";
      repoKey = metadata.repoKey ?? null;
      defaultBranch = metadata.defaultBranch ?? "main";
    }

    const existing = this.pg
      ? await this.list()
      : await this.readJson();
    if (existing.some((p) => p.path === path)) {
      const dup = existing.find((p) => p.path === path)!;
      throw new DuplicateProjectError("path", dup.path);
    }
    if (existing.some((p) => p.name === projectName)) {
      const dup = existing.find((p) => p.name === projectName)!;
      throw new DuplicateProjectError("name", dup.name);
    }
    if (repoKey && existing.some((p) => p.repoKey === repoKey)) {
      throw new DuplicateProjectError("path", repoKey);
    }

    const now = new Date().toISOString();
    const id = this.generateProjectId(projectName);

    const record: ProjectRecord = {
      id,
      name: projectName,
      path,
      githubUrl,
      repoKey,
      defaultBranch,
      status: "active",
      createdAt: now,
      updatedAt: now,
      lastSyncAt: null,
    };

    if (this.pg) {
      const row = await this.pg.createProject({
        name: record.name,
        path: record.path,
        githubUrl: record.githubUrl,
        repoKey: record.repoKey,
        defaultBranch: record.defaultBranch,
        status: record.status,
      });
      const persisted = this.projectRowToRecord(row);
      this.invalidateCache();
      await this.writeJsonMirror([
        ...existing.filter((project) => project.id !== persisted.id && project.path !== persisted.path),
        persisted,
      ]);
      return persisted;
    }

    // JSON write first — source of truth must persist in legacy mode
    await this.writeJson([...existing, record]);
    this.invalidateCache();

    return record;
  }

  /**
   * Get a single project by ID or name. Returns `null` if not found.
   * Tries ID first, then falls back to name (backward compat).
   */
  async get(projectIdOrName: string): Promise<ProjectRecord | null> {
    if (this.pg) {
      const records = await this.list();
      return records.find((p) => p.id === projectIdOrName || p.name === projectIdOrName) ?? null;
    }
    const records = await this.readJson();
    return records.find((p) => p.id === projectIdOrName || p.name === projectIdOrName) ?? null;
  }

  /**
   * List all registered projects. Reads from JSON (source of truth).
   * Results are cached in memory for the lifetime of the registry instance.
   */
  async list(): Promise<ProjectRecord[]> {
    if (this.pg) {
      const records = (await this.pg.listProjects()).map((row) => this.projectRowToRecord(row));
      this.cache = records;
      return [...records];
    }
    if (this.cache !== null) {
      return [...this.cache];
    }
    const records = await this.readJson();
    this.cache = records;
    return [...records];
  }

  /**
   * Update a project's metadata by ID or name.
   * Tries ID first, then falls back to name (backward compat).
   *
   * @param projectIdOrName - The project ID or name to update
   * @param patch - Partial metadata to merge
   * @throws ProjectNotFoundError if project doesn't exist
   */
  async update(
    projectIdOrName: string,
    patch: Partial<ProjectMetadata>
  ): Promise<ProjectRecord> {
    if (this.pg) {
      const existing = await this.get(projectIdOrName);
      if (!existing) {
        throw new ProjectNotFoundError(projectIdOrName);
      }

      await this.pg.updateProject(existing.id, {
        ...(patch.name !== undefined ? { name: patch.name } : {}),
        ...(patch.path !== undefined ? { path: patch.path } : {}),
        ...(patch.status !== undefined ? { status: patch.status } : {}),
        ...(patch.githubUrl !== undefined ? { github_url: patch.githubUrl } : {}),
        ...(patch.repoKey !== undefined ? { repo_key: patch.repoKey } : {}),
        ...(patch.defaultBranch !== undefined ? { default_branch: patch.defaultBranch } : {}),
        ...(patch.lastSyncAt !== undefined ? { last_sync_at: patch.lastSyncAt } : {}),
      });

      const updated = await this.pg.getProject(existing.id);
      if (!updated) {
        throw new ProjectNotFoundError(projectIdOrName);
      }
      const record = this.projectRowToRecord(updated);
      await this.writeJsonMirror([
        ...(await this.readJson()).filter((project) => project.id !== record.id && project.path !== record.path),
        record,
      ]);
      this.cache = null;
      return record;
    }

    const records = await this.readJson();
    let idx = records.findIndex((p) => p.id === projectIdOrName);
    if (idx === -1) {
      idx = records.findIndex((p) => p.name === projectIdOrName);
    }

    if (idx === -1) {
      throw new ProjectNotFoundError(projectIdOrName);
    }

    const updated: ProjectRecord = {
      ...records[idx],
      ...patch,
      // Prevent overwriting immutable fields
      id: records[idx].id,
      path: patch.path ?? records[idx].path,
      createdAt: records[idx].createdAt,
      updatedAt: new Date().toISOString(),
      lastSyncAt: patch.lastSyncAt !== undefined
        ? patch.lastSyncAt
        : records[idx].lastSyncAt,
    };

    records[idx] = updated;
    await this.writeJson(records);
    this.invalidateCache();

    return updated;
  }

  /**
   * Remove a project from the registry.
   *
   * @param projectIdOrName - The project ID or project name to remove
   * @throws ProjectNotFoundError if project doesn't exist
   */
  async remove(projectIdOrName: string): Promise<void> {
    if (this.pg) {
      const existing = await this.get(projectIdOrName);
      if (!existing) {
        throw new ProjectNotFoundError(projectIdOrName);
      }
      await this.pg.removeProject(existing.id);
      await this.writeJsonMirror((await this.readJson()).filter((project) => project.id !== existing.id));
      this.cache = null;
      return;
    }

    const records = await this.readJson();
    // Try ID first, then fall back to name (backward compat)
    let idx = records.findIndex((p) => p.id === projectIdOrName);
    let actualId = records[idx]?.id;
    if (idx === -1) {
      idx = records.findIndex((p) => p.name === projectIdOrName);
      actualId = records[idx]?.id;
    }
    if (idx === -1) {
      throw new ProjectNotFoundError(projectIdOrName);
    }

    records.splice(idx, 1);
    await this.writeJson(records);
    this.invalidateCache();
  }

  // -------------------------------------------------------------------------
  // Health & sync
  // -------------------------------------------------------------------------

  /**
   * Check whether a project clone is healthy by running `git fetch --quiet`.
   *
   * Returns `true` if fetch succeeds within 5 seconds.
   * Returns `false` if:
   * - Clone directory doesn't exist
   * - Not a git repository
   * - Fetch times out (5s)
   * - Any other git error
   */
  async isHealthy(projectId: string): Promise<boolean> {
    const record = await this.get(projectId);
    if (!record) {
      return false;
    }

    // Check clone directory exists
    try {
      await access(record.path, constants.F_OK);
    } catch {
      return false;
    }

    try {
      await execFileAsync("git", ["fetch", "--quiet"], {
        cwd: record.path,
        timeout: 5_000,
        encoding: "utf8",
      });
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Resolve a project name or ID to an absolute path.
   *
   * Resolution order:
   * 1. Match by ID (new API)
   * 2. Match by name (backward compat with old API)
   * 3. If input is an absolute path not in registry, return it as-is
   *    (backward compat with old behavior)
   *
   * @param nameOrIdOrPath - Project name, ID, or absolute path
   * @throws ProjectNotFoundError if not found and not an absolute path
   */
  resolve(nameOrIdOrPath: string): string {
    // Try to use cache first for synchronous lookup
    const records = this.cache;

    if (records !== null) {
      // Cache hit
      const byId = records.find((p) => p.id === nameOrIdOrPath);
      if (byId) return byId.path;
      const byName = records.find((p) => p.name === nameOrIdOrPath);
      if (byName) return byName.path;
      const byPath = records.find((p) => p.path === nameOrIdOrPath);
      if (byPath) return byPath.path;
      // Unregistered path: throw (matching old behavior)
      throw new ProjectNotFoundError(nameOrIdOrPath);
    }

    // Cache miss — do a sync read
    try {
      const content = readFileSync(this.jsonFilePath, "utf8");
      const parsed = JSON.parse(content);
      let arr: ProjectRecord[];
      if (!Array.isArray(parsed)) {
        const legacy = parsed as { version?: number; projects?: unknown[] };
        if (typeof legacy?.version === "number" && Array.isArray(legacy?.projects)) {
          arr = this.migrateLegacyRecordsSync(legacy.projects as LegacyProjectEntry[]);
        } else {
          arr = [];
        }
      } else {
        arr = parsed as ProjectRecord[];
      }
      this.cache = arr;
      const byId = arr.find((p) => p.id === nameOrIdOrPath);
      if (byId) return byId.path;
      const byName = arr.find((p) => p.name === nameOrIdOrPath);
      if (byName) return byName.path;
      const byPath = arr.find((p) => p.path === nameOrIdOrPath);
      if (byPath) return byPath.path;
      // Unregistered path: throw (matching old behavior)
      throw new ProjectNotFoundError(nameOrIdOrPath);
    } catch (err: unknown) {
      if ((err as NodeJS.ErrnoException).code === "ENOENT") {
        throw new ProjectNotFoundError(nameOrIdOrPath);
      }
      if (err instanceof ProjectNotFoundError) throw err;
      throw new ProjectNotFoundError(nameOrIdOrPath);
    }
  }

  /**
   * List stale projects — registry entries whose clone paths are inaccessible.
   * Does not modify the registry.
   */
  async listStale(): Promise<StaleProject[]> {
    const records = await this.list();
    const stale: StaleProject[] = [];
    for (const record of records) {
      try {
        await access(record.path, constants.F_OK);
      } catch {
        stale.push({ name: record.name, path: record.path });
      }
    }
    return stale;
  }

  /**
   * Remove all stale projects — registry entries whose clone paths are inaccessible.
   * Returns the names of removed projects.
   */
  async removeStale(): Promise<string[]> {
    const stale = await this.listStale();
    if (stale.length === 0) return [];

    const staleNames = new Set(stale.map((s) => s.name));
    if (this.pg) {
      for (const name of staleNames) {
        await this.remove(name);
      }
    } else {
      const records = await this.readJson();
      const remaining = records.filter((r) => !staleNames.has(r.name));
      await this.writeJson(remaining);
      this.invalidateCache();
    }
    return stale.map((s) => s.name);
  }

  /** Sync version of migrateLegacyRecords for the resolve path. */
  private migrateLegacyRecordsSync(
    entries: LegacyProjectEntry[]
  ): ProjectRecord[] {
    const now = new Date().toISOString();
    return entries.map((entry) => ({
      id: this.generateProjectId(entry.name),
      name: entry.name,
      path: entry.path,
      githubUrl: entry.githubUrl ?? "",
      repoKey: null,
      defaultBranch: entry.defaultBranch ?? "main",
      status: "active" as const,
      createdAt: entry.addedAt ?? now,
      updatedAt: now,
      lastSyncAt: null,
    }));
  }

  /**
   * Sync a project: run `git fetch --quiet` and update `lastSyncAt`.
   *
   * @param projectId - The project ID to sync
   * @throws ProjectNotFoundError if project doesn't exist
   */
  async sync(projectId: string): Promise<ProjectRecord> {
    const record = await this.get(projectId);
    if (!record) {
      throw new ProjectNotFoundError(projectId);
    }

    // Run git fetch
    try {
      await execFileAsync("git", ["fetch", "--quiet"], {
        cwd: record.path,
        timeout: 30_000,
        encoding: "utf8",
      });
    } catch (err) {
      // Network errors during fetch are non-fatal — log and continue
      console.warn(
        `[ProjectRegistry] git fetch failed for '${projectId}': ${(err as Error).message}`
      );
    }

    const now = new Date().toISOString();
    return this.update(projectId, { lastSyncAt: now });
  }

  // -------------------------------------------------------------------------
  // Directory helpers
  // -------------------------------------------------------------------------

  /**
   * Get the projects directory path.
   */
  getProjectsDir(): string {
    return join(this.baseDir, PROJECTS_SUBDIR);
  }
}
