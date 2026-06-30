/**
 * PoolManager — Postgres connection pool singleton.
 *
 * Singleton inside the Foreman daemon process. All database operations go through
 * this pool. No database connections are held by CLI processes.
 *
 * Design decisions:
 * - Singleton via module-level instance (one per Node.js process lifetime).
 * - Falls back to DATABASE_URL env var, then project-local `.env`, then
 *   postgresql://localhost/foreman default.
 * - All queries use parameterized placeholders ($1, $2, …) — caller is responsible
 *   for passing only trusted values; PoolManager does NOT re-parameterize strings.
 * - pool_size, idle_timeout_ms, connection_timeout_ms are configurable via
 *   ~/.foreman/config.yaml (read by the caller before instantiating).
 * - healthCheck() is used by the daemon startup to validate the connection before
 *   accepting tRPC traffic.
 *
 * @module pool-manager
 */
import { PoolConfig, PoolClient, QueryResultRow } from "pg";
/** Minimal pool interface used internally — covers what PoolManager needs. */
export interface PoolLike {
    query<T extends QueryResultRow = Record<string, unknown>>(text: string, params?: unknown[]): Promise<{
        rows: T[];
        rowCount: number | null;
    }>;
    connect(): Promise<PoolClient>;
    end(): Promise<void>;
    on(event: string, handler: (err: Error) => void): any;
}
/** Thrown when the Postgres pool is exhausted and no connection can be acquired. */
export declare class PoolExhaustedError extends Error {
    readonly code = "POOL_EXHAUSTED";
    constructor(message?: string);
}
/** Thrown when a database operation fails (wraps pg errors). */
export declare class DatabaseError extends Error {
    readonly code: string;
    readonly cause: unknown;
    constructor(message: string, code: string, cause: unknown);
}
/** Thrown when DATABASE_URL is malformed or missing required auth fields. */
export declare class DatabaseConfigError extends Error {
    readonly databaseUrl: string;
    constructor(message: string, databaseUrl: string);
}
/** Default number of retries for transient connection errors (TRD-068). */
export declare const MAX_RETRIES = 3;
/** Returns the current Pool instance. Throws if not yet initialised. */
export declare function getPool(): PoolLike;
/** Returns the config used to initialise the pool, or null. */
export declare function getPoolConfig(): PoolConfig | null;
/** True if the pool has been initialised. */
export declare function isPoolInitialised(): boolean;
/** Initialise the Postgres pool singleton.
 *
 * Call once at daemon startup, before any database operations.
 *
 * @param overrides - Override defaults. Fields mirror pg PoolConfig.
 * @param overrides.databaseUrl - Overrides DATABASE_URL resolution.
 * @param overrides.poolSize - Pool size (default: 20).
 * @param overrides.idleTimeoutMs - Idle timeout in ms (default: 30000).
 * @param overrides.connectionTimeoutMs - Connection timeout in ms (default: 5000).
 * @param overrides.poolOverride - Inject a mock pool (for testing). When provided,
 *   the pg Pool constructor is not called; this object is used directly.
 */
export declare function initPool(overrides?: {
    databaseUrl?: string;
    poolSize?: number;
    idleTimeoutMs?: number;
    connectionTimeoutMs?: number;
    poolOverride?: PoolLike;
}): PoolLike;
/** Destroy the pool, releasing all connections.
 *
 * Call on daemon shutdown.
 */
export declare function destroyPool(): Promise<void>;
/**
 * Execute a parameterised SELECT query with retry on transient errors.
 *
 * Transient errors (ECONNREFUSED, ENOTFOUND, connection lost) are retried up to
 * MAX_RETRIES times with exponential backoff. This allows the pool to recover from
 * brief network interruptions without callers needing to implement retry logic.
 *
 * @param text - SQL with $1, $2, … placeholders.
 * @param params - Values for the placeholders.
 * @returns pg QueryResult.
 */
export declare function query<T extends QueryResultRow = Record<string, unknown>>(text: string, params?: unknown[], maxRetries?: number): Promise<T[]>;
/**
 * Execute a parameterised INSERT/UPDATE/DELETE query with retry on transient errors.
 *
 * @param text - SQL with $1, $2, … placeholders.
 * @param params - Values for the placeholders.
 * @returns Number of rows affected.
 */
export declare function execute(text: string, params?: unknown[], maxRetries?: number): Promise<number>;
/** Acquire a client for a transaction.
 *
 * Usage:
 * ```
 * const client = await acquireClient();
 * try {
 *   await client.query('BEGIN');
 *   await client.query('INSERT INTO ...');
 *   await client.query('COMMIT');
 * } catch {
 *   await client.query('ROLLBACK');
 *   throw;
 * } finally {
 *   releaseClient(client);
 * }
 * ```
 */
export declare function acquireClient(): Promise<PoolClient>;
/** Release a client back to the pool. */
export declare function releaseClient(client: PoolClient): void;
/** Validate the database connection by running SELECT 1.
 *
 * Throws DatabaseError if the connection is not healthy.
 *
 * @returns The result of SELECT 1 (unused — presence of result = healthy).
 */
export declare function healthCheck(): Promise<void>;
export declare const PoolManager: {
    init: typeof initPool;
    destroy: typeof destroyPool;
    query: typeof query;
    execute: typeof execute;
    acquireClient: typeof acquireClient;
    releaseClient: typeof releaseClient;
    healthCheck: typeof healthCheck;
    getPool: typeof getPool;
    getPoolConfig: typeof getPoolConfig;
    isPoolInitialised: typeof isPoolInitialised;
    PoolExhaustedError: typeof PoolExhaustedError;
    DatabaseError: typeof DatabaseError;
    DatabaseConfigError: typeof DatabaseConfigError;
};
//# sourceMappingURL=pool-manager.d.ts.map