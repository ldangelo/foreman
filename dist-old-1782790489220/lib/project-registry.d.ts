/**
 * ProjectRegistry — project metadata store with JSON + Postgres dual-write.
 *
 * Architecture:
 * - Legacy JSON file at `~/.foreman/projects/projects.json` is retained as a
 *   compatibility mirror and recovery artifact.
 * - When PostgresAdapter is provided, Postgres is the source of truth and the
 *   JSON file is best-effort mirrored after successful DB writes.
 * - Without PostgresAdapter, the registry falls back to the legacy JSON-only mode.
 *
 * Design decisions:
 * - In Postgres-backed mode, writes go to Postgres first and then mirror to
 *   JSON opportunistically for compatibility with remaining sync-only helpers.
 * - In-memory cache invalidated on every write — no TTL, no background refresh.
 *   Registry writes are infrequent (add/remove/sync), so this is acceptable.
 * - Project IDs are deterministic from the normalized name + random hex suffix.
 *   Collision resistance comes from the 5-char hex suffix (16^5 = ~1M combos).
 * - Health check runs `git fetch --quiet` in the clone directory with 5s timeout.
 *   This is a "fast" health indicator — network latency or large repos affect it.
 *
 * @module project-registry
 */
import type { PostgresAdapter } from "./db/postgres-adapter.js";
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
    createdAt: string;
    updatedAt: string;
    lastSyncAt: string | null;
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
/**
 * Jira Cloud instance configuration (partial updates).
 */
export interface JiraConfigUpdate {
    apiUrl?: string;
    email?: string;
    apiToken?: string;
    pollIntervalSeconds?: number;
    webhookEnabled?: boolean;
    webhookSecretEnvVar?: string;
    projects?: Array<{
        key: string;
        startStatus: string[];
        endStatus?: string[];
        issueTypeWorkflowMap: Record<string, string>;
        debounceWindowSeconds?: number;
    }>;
}
export declare class ProjectRegistryError extends Error {
    readonly name: string;
}
export declare class ProjectNotFoundError extends ProjectRegistryError {
    readonly name: string;
    /** The name or path that was looked up and not found. */
    readonly nameOrPath: string;
    constructor(nameOrPath: string);
}
export declare class ProjectIdCollisionError extends ProjectRegistryError {
    readonly name: string;
    /** Which field caused the collision. */
    readonly field: "name" | "path";
    /** The conflicting value. */
    readonly value: string;
    constructor(field: "name" | "path", value: string);
}
export declare class ProjectRegistryJsonError extends ProjectRegistryError {
    readonly name: string;
    constructor(message: string, cause?: unknown);
}
/**
 * Error thrown when a project name or path is already registered.
 * Alias for ProjectIdCollisionError for backward compatibility.
 */
export declare class DuplicateProjectError extends ProjectRegistryError {
    readonly name: string;
    /** Which field caused the collision. */
    readonly field: "name" | "path";
    /** The conflicting value. */
    readonly value: string;
    constructor(field: "name" | "path", value: string);
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
export interface ProjectRegistryOptions {
    /** Override the base directory. Defaults to `~/.foreman`. */
    baseDir?: string;
    /** Override PostgresAdapter instance. Defaults to module-level singleton. */
    pg?: PostgresAdapter;
    /** Override the JSON file path (for testing). */
    jsonPath?: string;
}
export declare class ProjectRegistry {
    private readonly baseDir;
    private readonly jsonFilePath;
    private readonly pg;
    /** In-memory cache — null means cache is invalidated (needs re-read). */
    private cache;
    /**
     * Construct a ProjectRegistry.
     *
     * Accepts either:
     * - A string path (old API, backward compat) — treated as `jsonPath`
     * - An options object (new API)
     * - No argument (defaults to `~/.foreman/projects/projects.json`)
     */
    constructor(options?: ProjectRegistryOptions | string);
    /** Ensure the projects directory and JSON file directory exist. */
    private ensureDir;
    /** Read and parse the JSON registry file. Returns `[]` if file doesn't exist. */
    private readJson;
    /**
     * Migrate legacy { version, projects[] } format to new flat array format.
     * The old `addedAt` becomes `createdAt` and `updatedAt`.
     */
    private migrateLegacyRecords;
    /**
     * Write the JSON registry file atomically: write to a temp file first,
     * then rename to the target path. This avoids corruption on write failure.
     */
    private writeJson;
    /** Invalidate the in-memory cache. Call after any write. */
    private invalidateCache;
    private projectRowToRecord;
    private writeJsonMirror;
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
    generateProjectId(name: string): string;
    /**
     * Add a new project to the registry.
     *
     * Supports both the new API (ProjectMetadata object) and the old API
     * (path string with optional name override) for backward compatibility.
     *
     * In Postgres-backed mode, writes to Postgres first and mirrors JSON for
     * compatibility. In legacy mode, writes directly to JSON.
     *
     * @param metadata - Project metadata (new API)
     * @param name - Optional name override (old API second arg — ignored when metadata is object)
     */
    add(metadata: ProjectMetadata | string, name?: string): Promise<ProjectRecord>;
    /**
     * Get a single project by ID or name. Returns `null` if not found.
     * Tries ID first, then falls back to name (backward compat).
     */
    get(projectIdOrName: string): Promise<ProjectRecord | null>;
    /**
     * List all registered projects.
     * In Postgres-backed mode this reads from Postgres; otherwise it falls back
     * to the legacy JSON registry. Results are cached in memory per instance.
     */
    list(): Promise<ProjectRecord[]>;
    /**
     * Update a project's metadata by ID or name.
     * Tries ID first, then falls back to name (backward compat).
     *
     * @param projectIdOrName - The project ID or name to update
     * @param patch - Partial metadata to merge
     * @throws ProjectNotFoundError if project doesn't exist
     */
    update(projectIdOrName: string, patch: Partial<ProjectMetadata>): Promise<ProjectRecord>;
    /**
     * Update Jira configuration for a project by persisting to project YAML.
     *
     * Reads the existing `~/.foreman/config.yaml` from the project directory,
     * merges the Jira updates, and writes it back.
     *
     * @param projectIdOrName - The project ID or name
     * @param jiraUpdate - Partial Jira config to merge
     * @throws ProjectNotFoundError if project doesn't exist
     */
    updateJiraConfig(projectIdOrName: string, jiraUpdate: JiraConfigUpdate): Promise<void>;
    /**
     * Remove a project from the registry.
     *
     * @param projectIdOrName - The project ID or project name to remove
     * @throws ProjectNotFoundError if project doesn't exist
     */
    remove(projectIdOrName: string): Promise<void>;
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
    isHealthy(projectId: string): Promise<boolean>;
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
    resolve(nameOrIdOrPath: string): string;
    /**
     * List stale projects — registry entries whose clone paths are inaccessible.
     * Does not modify the registry.
     */
    listStale(): Promise<StaleProject[]>;
    /**
     * Remove all stale projects — registry entries whose clone paths are inaccessible.
     * Returns the names of removed projects.
     */
    removeStale(): Promise<string[]>;
    /** Sync version of migrateLegacyRecords for the resolve path. */
    private migrateLegacyRecordsSync;
    /**
     * Sync a project: run `git fetch --quiet` and update `lastSyncAt`.
     *
     * @param projectId - The project ID to sync
     * @throws ProjectNotFoundError if project doesn't exist
     */
    sync(projectId: string): Promise<ProjectRecord>;
    /**
     * Get the projects directory path.
     */
    getProjectsDir(): string;
}
//# sourceMappingURL=project-registry.d.ts.map