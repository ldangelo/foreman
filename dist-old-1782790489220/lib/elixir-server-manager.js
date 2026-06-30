import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
export class ElixirServerManager {
    url;
    port;
    pidPath;
    packagePath;
    authToken;
    constructor(opts = {}) {
        this.port = opts.port ?? Number(process.env.FOREMAN_SERVER_HTTP_PORT ?? 4766);
        this.url = `http://127.0.0.1:${this.port}`;
        this.pidPath = opts.pidPath ?? resolve(process.cwd(), ".foreman", "elixir-server.pid");
        this.packagePath = opts.packagePath ?? resolve(repoRoot(), "packages", "foreman_server");
        this.authToken = opts.authToken ?? process.env.FOREMAN_SERVER_AUTH_TOKEN;
    }
    status() {
        const pid = this.readPid();
        return { running: pid !== undefined && isProcessAlive(pid), pid, url: this.url, pidPath: this.pidPath };
    }
    async health() {
        return this.getJson("/api/v1/health");
    }
    async doctor() {
        return this.getJson("/api/v1/doctor", { authenticated: true });
    }
    async metrics() {
        return this.getJson("/api/v1/metrics", { authenticated: true });
    }
    async getJson(path, opts = {}) {
        try {
            const headers = opts.authenticated ? this.authHeaders() : undefined;
            const response = await fetch(new URL(path, this.url), headers ? { headers } : undefined);
            const body = (await response.json());
            return { ok: response.ok, body };
        }
        catch (error) {
            return { ok: false, error: error instanceof Error ? error.message : String(error) };
        }
    }
    async ensureRunning() {
        const status = this.status();
        if (status.running && (await this.health()).ok)
            return status;
        this.start();
        await waitFor(async () => (await this.health()).ok, 10_000);
        return this.status();
    }
    start() {
        if (this.status().running)
            return;
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
    stop() {
        const pid = this.readPid();
        if (pid !== undefined && isProcessAlive(pid))
            process.kill(pid, "SIGTERM");
        rmSync(this.pidPath, { force: true });
    }
    readPid() {
        if (!existsSync(this.pidPath))
            return undefined;
        const pid = Number(readFileSync(this.pidPath, "utf8").trim());
        return Number.isInteger(pid) && pid > 0 ? pid : undefined;
    }
    authHeaders() {
        if (!this.authToken)
            return undefined;
        return { Authorization: `Bearer ${this.authToken}` };
    }
}
function isProcessAlive(pid) {
    try {
        process.kill(pid, 0);
        return true;
    }
    catch {
        return false;
    }
}
async function waitFor(fn, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (await fn())
            return;
        await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error("Elixir server did not become healthy before timeout");
}
function repoRoot() {
    const thisFile = fileURLToPath(import.meta.url);
    return resolve(dirname(thisFile), "..", "..");
}
//# sourceMappingURL=elixir-server-manager.js.map