/**
 * PoolManager — Postgres connection pool singleton.
 *
 * Singleton inside the Foreman daemon process. All database operations go through
 * this pool. No database connections are held by CLI processes.
 *
 * Design decisions:
 * - Singleton via module-level instance (one per Node.js process lifetime).
 * - Falls back to DATABASE_URL env var, then postgresql://localhost/foreman default.
 * - All queries use parameterized placeholders ($1, $2, …) — caller is responsible
 *   for passing only trusted values; PoolManager does NOT re-parameterize strings.
 * - pool_size, idle_timeout_ms, connection_timeout_ms are configurable via
 *   ~/.foreman/config.yaml (read by the caller before instantiating).
 * - healthCheck() is used by the daemon startup to validate the connection before
 *   accepting tRPC traffic.
 *
 * @module pool-manager
 */

import { Pool, PoolConfig, PoolClient, QueryResultRow } from "pg";

/** Minimal pool interface used internally — covers what PoolManager needs. */
export interface PoolLike {
  query<T extends QueryResultRow = Record<string, unknown>>(
    text: string,
    params?: unknown[]
  ): Promise<{ rows: T[]; rowCount: number | null }>;
  connect(): Promise<PoolClient>;
  end(): Promise<void>;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  on(event: string, handler: (err: Error) => void): any;
}

// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------

/** Thrown when the Postgres pool is exhausted and no connection can be acquired. */
export class PoolExhaustedError extends Error {
  readonly code = "POOL_EXHAUSTED";

  constructor(message = "Postgres connection pool exhausted") {
    super(message);
    this.name = "PoolExhaustedError";
  }
}

/** Thrown when a database operation fails (wraps pg errors). */
export class DatabaseError extends Error {
  readonly code: string;
  readonly cause: unknown;

  constructor(message: string, code: string, cause: unknown) {
    super(message);
    this.name = "DatabaseError";
    this.code = code;
    this.cause = cause;
  }
}

// ---------------------------------------------------------------------------
// Default configuration
// ---------------------------------------------------------------------------

const DEFAULT_POOL_SIZE = 20;
const DEFAULT_IDLE_TIMEOUT_MS = 30_000;
const DEFAULT_CONNECTION_TIMEOUT_MS = 5_000;

function resolveDatabaseUrl(): string {
  return (
    process.env.DATABASE_URL ??
    "postgresql://localhost/foreman"
  );
}

/** Default number of retries for transient connection errors (TRD-068). */
export const MAX_RETRIES = 3;

/**
 * Agent continues on Postgres disconnect, resumes on reconnect.
 * Transient errors (ECONNREFUSED, connection terminated) are retried up to
 * MAX_RETRIES times with exponential backoff.
 */

async function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ---------------------------------------------------------------------------
// PoolManager
// ---------------------------------------------------------------------------

let _pool: PoolLike | null = null;
let _config: PoolConfig | null = null;

/** Returns the current Pool instance. Throws if not yet initialised. */
export function getPool(): PoolLike {
  if (!_pool) {
    throw new Error(
      "PoolManager not initialised. Call PoolManager.init() before use."
    );
  }
  return _pool;
}

/** Returns the config used to initialise the pool, or null. */
export function getPoolConfig(): PoolConfig | null {
  return _config;
}

/** True if the pool has been initialised. */
export function isPoolInitialised(): boolean {
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
export function initPool(overrides?: {
  databaseUrl?: string;
  poolSize?: number;
  idleTimeoutMs?: number;
  connectionTimeoutMs?: number;
  poolOverride?: PoolLike;
}): PoolLike {
  if (_pool) {
    throw new Error("PoolManager already initialised. Call destroyPool() first.");
  }

  const databaseUrl = overrides?.databaseUrl ?? resolveDatabaseUrl();
  const poolSize = overrides?.poolSize ?? DEFAULT_POOL_SIZE;
  const idleTimeoutMs = overrides?.idleTimeoutMs ?? DEFAULT_IDLE_TIMEOUT_MS;
  const connectionTimeoutMs =
    overrides?.connectionTimeoutMs ?? DEFAULT_CONNECTION_TIMEOUT_MS;

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

  const config: PoolConfig = {
    connectionString: databaseUrl,
    max: poolSize,
    idleTimeoutMillis: idleTimeoutMs,
    connectionTimeoutMillis: connectionTimeoutMs,
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
export async function destroyPool(): Promise<void> {
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
export async function query<T extends QueryResultRow = Record<string, unknown>>(
  text: string,
  params?: unknown[],
  maxRetries = MAX_RETRIES,
): Promise<T[]> {
  let lastError: unknown;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      const pool = getPool();
      const result = await pool.query<T>(text, params);
      return result.rows;
    } catch (err: unknown) {
      lastError = err;
      const code = (err as { code?: string }).code;
      // Transient errors worth retrying
      const isTransient =
        code === "ECONNREFUSED" ||
        code === "ENOTFOUND" ||
        code === "ETIMEDOUT" ||
        code === "ENETUNREACH" ||
        (err as Error).message?.includes("Connection terminated") ||
        (err as Error).message?.includes("connection to remote host refused") ||
        (err as Error).message?.includes("Connection lost");
      if (isTransient && attempt < maxRetries) {
        const delay = Math.min(100 * 2 ** attempt, 2000);
        await sleep(delay);
        continue;
      }
    }
  }
  throw new DatabaseError(
    `Query failed after ${maxRetries + 1} attempts: ${(lastError as Error).message}`,
    (lastError as { code?: string }).code ?? "UNKNOWN",
    lastError
  );
}

/**
 * Execute a parameterised INSERT/UPDATE/DELETE query with retry on transient errors.
 *
 * @param text - SQL with $1, $2, … placeholders.
 * @param params - Values for the placeholders.
 * @returns Number of rows affected.
 */
export async function execute(
  text: string,
  params?: unknown[],
  maxRetries = MAX_RETRIES,
): Promise<number> {
  let lastError: unknown;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      const pool = getPool();
      const result = await pool.query(text, params);
      return result.rowCount ?? 0;
    } catch (err: unknown) {
      lastError = err;
      const code = (err as { code?: string }).code;
      const isTransient =
        code === "ECONNREFUSED" ||
        code === "ENOTFOUND" ||
        code === "ETIMEDOUT" ||
        code === "ENETUNREACH" ||
        (err as Error).message?.includes("Connection terminated") ||
        (err as Error).message?.includes("connection to remote host refused") ||
        (err as Error).message?.includes("Connection lost");
      if (isTransient && attempt < maxRetries) {
        const delay = Math.min(100 * 2 ** attempt, 2000);
        await sleep(delay);
        continue;
      }
    }
  }
  throw new DatabaseError(
    `Execute failed after ${maxRetries + 1} attempts: ${(lastError as Error).message}`,
    (lastError as { code?: string }).code ?? "UNKNOWN",
    lastError
  );
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
export async function acquireClient(): Promise<PoolClient> {
  const pool = getPool();
  try {
    return await pool.connect();
  } catch (err: unknown) {
    if (
      err instanceof Error &&
      (err.message.includes("connection pool") ||
        (err as { code?: string }).code === "ECONNREFUSED")
    ) {
      throw new PoolExhaustedError();
    }
    throw err;
  }
}

/** Release a client back to the pool. */
export function releaseClient(client: PoolClient): void {
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
export async function healthCheck(): Promise<void> {
  const pool = getPool();
  try {
    await pool.query("SELECT 1");
  } catch (err: unknown) {
    throw new DatabaseError(
      `Health check failed: ${(err as Error).message}`,
      (err as { code?: string }).code ?? "UNKNOWN",
      err
    );
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
};
