import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

export type ElixirRuntimeIdentity = {
  mix_env?: string;
  http?: { enabled?: boolean; port?: number };
  event_store?: { adapter?: string; path?: string | null; table?: string | null };
  projection_store?: { adapter?: string; tables?: string[] | null };
  project_config_store?: { adapter?: string; path?: string | null };
  project_store?: { adapter?: string; path?: string | null };
};

export type ElixirServerStatus = {
  running: boolean;
  pid?: number;
  url: string;
  pidPath: string;
};

const USER_HTTP_PORT = 4766;
const TEST_HTTP_PORT = 14766;

export class ElixirServerManager {
  readonly url: string;
  readonly port: number;
  readonly pidPath: string;
  readonly packagePath: string;
  readonly authToken?: string;
  readonly mixEnv: string;

  constructor(opts: { port?: number; pidPath?: string; packagePath?: string; authToken?: string; url?: string; mixEnv?: string } = {}) {
    const envUrl = opts.url ?? process.env.FOREMAN_SERVER_URL;
    this.mixEnv = opts.mixEnv ?? process.env.MIX_ENV ?? "dev";
    this.port = opts.port ?? parsePort(process.env.FOREMAN_SERVER_HTTP_PORT) ?? defaultPort(this.mixEnv);
    this.url = envUrl ?? `http://127.0.0.1:${this.port}`;
    this.pidPath = opts.pidPath ?? defaultPidPath(this.mixEnv);
    this.packagePath = opts.packagePath ?? resolve(repoRoot(), "packages", "foreman_server");
    this.authToken = opts.authToken ?? process.env.FOREMAN_SERVER_AUTH_TOKEN;
  }

  status(): ElixirServerStatus {
    const pid = this.readPid();
    return { running: pid !== undefined && isProcessAlive(pid), pid, url: this.url, pidPath: this.pidPath };
  }

  async health(): Promise<{ ok: boolean; body?: unknown; error?: string }> {
    return this.getJson("/api/v1/health", { authenticated: Boolean(this.authToken) });
  }

  async runtimeIdentity(): Promise<ElixirRuntimeIdentity | undefined> {
    const health = await this.health();
    if (!health.ok || !isRecord(health.body) || !isRecord(health.body.runtime)) return undefined;
    return health.body.runtime as ElixirRuntimeIdentity;
  }

  async doctor(): Promise<{ ok: boolean; body?: unknown; error?: string }> {
    return this.getJson("/api/v1/doctor", { authenticated: true });
  }

  async metrics(): Promise<{ ok: boolean; body?: unknown; error?: string }> {
    return this.getJson("/api/v1/metrics", { authenticated: true });
  }

  private async getJson(
    path: string,
    opts: { authenticated?: boolean } = {},
  ): Promise<{ ok: boolean; body?: unknown; error?: string }> {
    try {
      const headers = opts.authenticated ? this.authHeaders() : undefined;
      const response = await fetch(new URL(path, this.url), headers ? { headers } : undefined);
      const body = (await response.json()) as unknown;
      return { ok: response.ok, body };
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
  }

  async ensureRunning(): Promise<ElixirServerStatus> {
    const status = this.status();
    if (status.running && (await this.health()).ok) return status;
    const startError = this.start();
    await Promise.race([
      waitFor(async () => (await this.health()).ok, 10_000),
      startError,
    ]);
    return this.status();
  }

  start(): Promise<never> {
    if (this.status().running) return new Promise(() => undefined);
    validateStartSafety(this);
    mkdirSync(dirname(this.pidPath), { recursive: true });

    const child = spawn("mix", ["run", "--no-halt"], {
      cwd: this.packagePath,
      detached: true,
      stdio: "ignore",
      env: {
        ...process.env,
        MIX_ENV: this.mixEnv,
        FOREMAN_SERVER_HTTP_ENABLED: "true",
        FOREMAN_SERVER_HTTP_PORT: String(this.port),
      },
    });

    child.unref();
    if (child.pid !== undefined) {
      writeFileSync(this.pidPath, String(child.pid), "utf8");
    }

    return new Promise((_, reject) => {
      child.once("error", reject);
    });
  }

  stop(): void {
    const pid = this.readPid();
    if (pid !== undefined && isProcessAlive(pid)) process.kill(pid, "SIGTERM");
    rmSync(this.pidPath, { force: true });
  }

  private readPid(): number | undefined {
    if (!existsSync(this.pidPath)) return undefined;
    const pid = Number(readFileSync(this.pidPath, "utf8").trim());
    return Number.isInteger(pid) && pid > 0 ? pid : undefined;
  }

  private authHeaders(): Record<string, string> | undefined {
    if (!this.authToken) return undefined;
    return { Authorization: `Bearer ${this.authToken}` };
  }
}

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitFor(fn: () => Promise<boolean>, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await fn()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("Elixir server did not become healthy before timeout");
}

function repoRoot(): string {
  const thisFile = fileURLToPath(import.meta.url);
  return resolve(dirname(thisFile), "..", "..");
}

function defaultPort(mixEnv: string): number {
  return mixEnv === "test" ? TEST_HTTP_PORT : USER_HTTP_PORT;
}

function parsePort(value: string | undefined): number | undefined {
  if (value === undefined || value.trim() === "") return undefined;
  const port = Number(value);
  return Number.isInteger(port) && port >= 0 && port <= 65_535 ? port : undefined;
}

function defaultPidPath(mixEnv: string): string {
  return mixEnv === "test"
    ? resolve(process.cwd(), ".foreman", "test", "elixir-server.pid")
    : resolve(process.cwd(), ".foreman", "elixir-server.pid");
}

function validateStartSafety(manager: ElixirServerManager): void {
  if (manager.mixEnv !== "test") return;

  if (manager.port === USER_HTTP_PORT && process.env.FOREMAN_ALLOW_TEST_PORT_COLLISION !== "1") {
    throw new Error(
      `refusing to start Foreman with MIX_ENV=test on user HTTP port ${USER_HTTP_PORT}; use port ${TEST_HTTP_PORT} or set FOREMAN_ALLOW_TEST_PORT_COLLISION=1`,
    );
  }

  if (process.env.FOREMAN_ALLOW_TEST_PERSISTENT_STORAGE === "1") return;

  const unsafeStorage = [
    ["event log", process.env.FOREMAN_SERVER_EVENT_LOG],
    ["project store", process.env.FOREMAN_SERVER_PROJECT_STORE],
  ].find(([, path]) => typeof path === "string" && path.length > 0 && !isSafeTestPath(path));

  if (unsafeStorage) {
    throw new Error(
      `refusing to start Foreman with MIX_ENV=test using non-temp ${unsafeStorage[0]} path ${resolve(String(unsafeStorage[1]))}; use packages/tmp/test or an OS temp path, or set FOREMAN_ALLOW_TEST_PERSISTENT_STORAGE=1`,
    );
  }
}

function isSafeTestPath(path: string): boolean {
  const absolutePath = resolve(path);
  return isWithin(absolutePath, resolve(repoRoot(), "packages", "tmp", "test")) || isWithin(absolutePath, resolve(tmpdir()));
}

function isWithin(path: string, root: string): boolean {
  const result = relative(root, path);
  return result === "" || (!result.startsWith("..") && !result.startsWith("/") && result !== "..");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
