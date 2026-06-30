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
import { Pool } from "pg";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------
/** Thrown when the Postgres pool is exhausted and no connection can be acquired. */
export class PoolExhaustedError extends Error {
    code = "POOL_EXHAUSTED";
    constructor(message = "Postgres connection pool exhausted") {
        super(message);
        this.name = "PoolExhaustedError";
    }
}
/** Thrown when a database operation fails (wraps pg errors). */
export class DatabaseError extends Error {
    code;
    cause;
    constructor(message, code, cause) {
        super(message);
        this.name = "DatabaseError";
        this.code = code;
        this.cause = cause;
    }
}
/** Thrown when DATABASE_URL is malformed or missing required auth fields. */
export class DatabaseConfigError extends Error {
    databaseUrl;
    constructor(message, databaseUrl) {
        super(message);
        this.name = "DatabaseConfigError";
        this.databaseUrl = databaseUrl;
    }
}
function validateDatabaseUrl(databaseUrl) {
    let parsed;
    try {
        parsed = new URL(databaseUrl);
    }
    catch (cause) {
        throw new DatabaseConfigError("Invalid DATABASE_URL. Expected a postgres:// or postgresql:// URL.", databaseUrl);
    }
    if (parsed.protocol !== "postgres:" && parsed.protocol !== "postgresql:") {
        throw new DatabaseConfigError("Invalid DATABASE_URL. Expected a postgres:// or postgresql:// URL.", databaseUrl);
    }
    if (parsed.username && parsed.password === "") {
        throw new DatabaseConfigError(`Invalid DATABASE_URL. User '${decodeURIComponent(parsed.username)}' is missing a password.`, databaseUrl);
    }
}
// ---------------------------------------------------------------------------
// Default configuration
// ---------------------------------------------------------------------------
const DEFAULT_POOL_SIZE = 20;
const DEFAULT_IDLE_TIMEOUT_MS = 30_000;
const DEFAULT_CONNECTION_TIMEOUT_MS = 5_000;
function resolveDatabaseUrl() {
    const dotEnvPath = join(process.cwd(), ".env");
    if (process.env.DATABASE_URL) {
        return process.env.DATABASE_URL;
    }
    if (existsSync(dotEnvPath)) {
        const match = readFileSync(dotEnvPath, "utf8").match(/^\s*DATABASE_URL=(.+)\s*$/m);
        if (match?.[1]) {
            return match[1].trim().replace(/^['"]|['"]$/g, "");
        }
    }
    return ("postgresql://localhost/foreman");
}
/** Default number of retries for transient connection errors (TRD-068). */
export const MAX_RETRIES = 3;
/**
 * Agent continues on Postgres disconnect, resumes on reconnect.
 * Transient errors (ECONNREFUSED, connection terminated) are retried up to
 * MAX_RETRIES times with exponential backoff.
 */
async function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}
// ---------------------------------------------------------------------------
// PoolManager
// ---------------------------------------------------------------------------
let _pool = null;
let _config = null;
/** Returns the current Pool instance. Throws if not yet initialised. */
export function getPool() {
    if (!_pool) {
        throw new Error("PoolManager not initialised. Call PoolManager.init() before use.");
    }
    return _pool;
}
/** Returns the config used to initialise the pool, or null. */
export function getPoolConfig() {
    return _config;
}
/** True if the pool has been initialised. */
export function isPoolInitialised() {
    return _pool !== null;
}
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
export function initPool(overrides) {
    if (_pool) {
        throw new Error("PoolManager already initialised. Call destroyPool() first.");
    }
    const databaseUrl = overrides?.databaseUrl ?? resolveDatabaseUrl();
    validateDatabaseUrl(databaseUrl);
    const poolSize = overrides?.poolSize ?? DEFAULT_POOL_SIZE;
    const idleTimeoutMs = overrides?.idleTimeoutMs ?? DEFAULT_IDLE_TIMEOUT_MS;
    const connectionTimeoutMs = overrides?.connectionTimeoutMs ?? DEFAULT_CONNECTION_TIMEOUT_MS;
    if (overrides?.poolOverride) {
        // Test path: use injected mock pool.
        _config = {
            connectionString: databaseUrl,
            max: poolSize,
            idleTimeoutMillis: idleTimeoutMs,
            connectionTimeoutMillis: connectionTimeoutMs,
        };
        // @ts-ignore - poolOverride is PoolLike, _pool is PoolLike.
        _pool = overrides.poolOverride;
        return _pool;
    }
    const config = {
        connectionString: databaseUrl,
        max: poolSize,
        idleTimeoutMillis: idleTimeoutMs,
        connectionTimeoutMillis: connectionTimeoutMs,
        allowExitOnIdle: true,
    };
    _config = config;
    // @ts-ignore - Pool satisfies PoolLike at runtime.
    _pool = new Pool(config);
    _pool.on("error", (err) => {
        // Unhandled errors on idle clients — log but don't throw (pg recommends this)
        console.error("[PoolManager] unexpected pool error:", err.message);
    });
    return _pool;
}
/** Destroy the pool, releasing all connections.
 *
 * Call on daemon shutdown.
 */
export async function destroyPool() {
    if (_pool) {
        await _pool.end();
        _pool = null;
        _config = null;
    }
}
// ---------------------------------------------------------------------------
// Query helpers
// ---------------------------------------------------------------------------
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
export async function query(text, params, maxRetries = MAX_RETRIES) {
    let lastError;
    for (let attempt = 0; attempt <= maxRetries; attempt++) {
        try {
            const pool = getPool();
            const result = await pool.query(text, params);
            return result.rows;
        }
        catch (err) {
            lastError = err;
            const code = err.code;
            // Transient errors worth retrying
            const isTransient = code === "ECONNREFUSED" ||
                code === "ENOTFOUND" ||
                code === "ETIMEDOUT" ||
                code === "ENETUNREACH" ||
                err.message?.includes("Connection terminated") ||
                err.message?.includes("connection to remote host refused") ||
                err.message?.includes("Connection lost");
            if (isTransient && attempt < maxRetries) {
                const delay = Math.min(100 * 2 ** attempt, 2000);
                await sleep(delay);
                continue;
            }
        }
    }
    throw new DatabaseError(`Query failed after ${maxRetries + 1} attempts: ${lastError.message}`, lastError.code ?? "UNKNOWN", lastError);
}
/**
 * Execute a parameterised INSERT/UPDATE/DELETE query with retry on transient errors.
 *
 * @param text - SQL with $1, $2, … placeholders.
 * @param params - Values for the placeholders.
 * @returns Number of rows affected.
 */
export async function execute(text, params, maxRetries = MAX_RETRIES) {
    let lastError;
    for (let attempt = 0; attempt <= maxRetries; attempt++) {
        try {
            const pool = getPool();
            const result = await pool.query(text, params);
            return result.rowCount ?? 0;
        }
        catch (err) {
            lastError = err;
            const code = err.code;
            const isTransient = code === "ECONNREFUSED" ||
                code === "ENOTFOUND" ||
                code === "ETIMEDOUT" ||
                code === "ENETUNREACH" ||
                err.message?.includes("Connection terminated") ||
                err.message?.includes("connection to remote host refused") ||
                err.message?.includes("Connection lost");
            if (isTransient && attempt < maxRetries) {
                const delay = Math.min(100 * 2 ** attempt, 2000);
                await sleep(delay);
                continue;
            }
        }
    }
    throw new DatabaseError(`Execute failed after ${maxRetries + 1} attempts: ${lastError.message}`, lastError.code ?? "UNKNOWN", lastError);
}
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
export async function acquireClient() {
    const pool = getPool();
    try {
        return await pool.connect();
    }
    catch (err) {
        if (err instanceof Error &&
            (err.message.includes("connection pool") ||
                err.code === "ECONNREFUSED")) {
            throw new PoolExhaustedError();
        }
        throw err;
    }
}
/** Release a client back to the pool. */
export function releaseClient(client) {
    client.release();
}
// ---------------------------------------------------------------------------
// Health check
// ---------------------------------------------------------------------------
/** Validate the database connection by running SELECT 1.
 *
 * Throws DatabaseError if the connection is not healthy.
 *
 * @returns The result of SELECT 1 (unused — presence of result = healthy).
 */
export async function healthCheck() {
    const pool = getPool();
    try {
        await pool.query("SELECT 1");
    }
    catch (err) {
        throw new DatabaseError(`Health check failed: ${err.message}`, err.code ?? "UNKNOWN", err);
    }
}
// ---------------------------------------------------------------------------
// Named export for convenience (mirrors old ForemanStore API shape)
// ---------------------------------------------------------------------------
export const PoolManager = {
    init: initPool,
    destroy: destroyPool,
    query,
    execute,
    acquireClient,
    releaseClient,
    healthCheck,
    getPool,
    getPoolConfig,
    isPoolInitialised,
    PoolExhaustedError,
    DatabaseError,
    DatabaseConfigError,
};
//# sourceMappingURL=pool-manager.js.map