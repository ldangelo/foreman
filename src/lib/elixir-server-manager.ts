import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

export type ElixirServerStatus = {
  running: boolean;
  pid?: number;
  url: string;
  pidPath: string;
};

export class ElixirServerManager {
  readonly url: string;
  readonly port: number;
  readonly pidPath: string;
  readonly packagePath: string;

  constructor(opts: { port?: number; pidPath?: string; packagePath?: string } = {}) {
    this.port = opts.port ?? Number(process.env.FOREMAN_SERVER_HTTP_PORT ?? 4766);
    this.url = `http://127.0.0.1:${this.port}`;
    this.pidPath = opts.pidPath ?? resolve(process.cwd(), ".foreman", "elixir-server.pid");
    this.packagePath = opts.packagePath ?? resolve(repoRoot(), "packages", "foreman_server");
  }

  status(): ElixirServerStatus {
    const pid = this.readPid();
    return { running: pid !== undefined && isProcessAlive(pid), pid, url: this.url, pidPath: this.pidPath };
  }

  async health(): Promise<{ ok: boolean; body?: unknown; error?: string }> {
    return this.getJson("/api/v1/health");
  }

  async doctor(): Promise<{ ok: boolean; body?: unknown; error?: string }> {
    return this.getJson("/api/v1/doctor");
  }

  private async getJson(path: string): Promise<{ ok: boolean; body?: unknown; error?: string }> {
    try {
      const response = await fetch(new URL(path, this.url));
      const body = (await response.json()) as unknown;
      return { ok: response.ok, body };
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
  }

  async ensureRunning(): Promise<ElixirServerStatus> {
    const status = this.status();
    if (status.running && (await this.health()).ok) return status;
    this.start();
    await waitFor(async () => (await this.health()).ok, 10_000);
    return this.status();
  }

  start(): void {
    if (this.status().running) return;
    mkdirSync(dirname(this.pidPath), { recursive: true });

    const child = spawn("mix", ["run", "--no-halt"], {
      cwd: this.packagePath,
      detached: true,
      stdio: "ignore",
      env: {
        ...process.env,
        FOREMAN_SERVER_HTTP_ENABLED: "true",
        FOREMAN_SERVER_HTTP_PORT: String(this.port),
      },
    });

    child.unref();
    writeFileSync(this.pidPath, String(child.pid), "utf8");
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
