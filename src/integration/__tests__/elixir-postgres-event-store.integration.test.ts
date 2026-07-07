import { PostgreSqlContainer, type StartedPostgreSqlContainer } from "@testcontainers/postgresql";
import { spawn, spawnSync, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:net";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const SERVER_DIR = join(process.cwd(), "packages", "foreman_server");
const MIX_SPAWN_MAX_BUFFER = 50 * 1024 * 1024;
const MIX_AVAILABLE = spawnSync("mix", ["--version"], { stdio: "ignore" }).status === 0;

async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close(() => {
        if (typeof address === "object" && address) resolve(address.port);
        else reject(new Error("failed to allocate port"));
      });
    });
  });
}

async function waitForHealth(baseUrl: string, proc: ChildProcessWithoutNullStreams, logs: string[]): Promise<void> {
  const deadline = Date.now() + 30_000;
  let lastError: unknown;

  while (Date.now() < deadline) {
    if (proc.exitCode !== null) throw new Error(`Elixir server exited early with code ${proc.exitCode}\n${logs.join("")}`);

    try {
      const response = await fetch(new URL("/api/v1/health", baseUrl));
      if (response.ok) return;
      lastError = new Error(`health returned ${response.status}`);
    } catch (error) {
      lastError = error;
    }

    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  throw new Error(`Elixir server did not become healthy: ${String(lastError)}\n${logs.join("")}`);
}

async function sendCommand(baseUrl: string, commandType: string, payload: Record<string, unknown>, logs: string[]) {
  const response = await fetch(new URL("/api/v1/commands", baseUrl), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      command_id: `${commandType}-${Date.now()}-${Math.random().toString(16).slice(2)}`,
      command_type: commandType,
      payload,
      metadata: {},
    }),
  });

  if (!response.ok) throw new Error(`${commandType} failed: ${response.status} ${await response.text()}\n${logs.join("")}`);
  return response.json();
}

describe.skipIf(!MIX_AVAILABLE)("Elixir Postgres event store", () => {
  let container: StartedPostgreSqlContainer;
  let tmpHome: string;
  let server: ChildProcessWithoutNullStreams | undefined;
  let baseUrl: string;
  let databaseUrl: string;
  let port: number;
  let serverLogs: string[] = [];

  async function startServer(): Promise<void> {
    serverLogs = [];
    server = spawn("mix", ["run", "--no-halt"], {
      cwd: SERVER_DIR,
      env: {
        ...process.env,
        MIX_ENV: "test",
        DATABASE_URL: databaseUrl,
        FOREMAN_SERVER_EVENT_STORE_ADAPTER: "postgres",
        FOREMAN_SERVER_HTTP_ENABLED: "true",
        FOREMAN_SERVER_HTTP_PORT: String(port),
        FOREMAN_SERVER_PROJECT_STORE: join(tmpHome, "projects.term"),
        FOREMAN_SERVER_EVENT_LOG: join(tmpHome, "should-not-be-used.term.log"),
      },
    });

    server.stdout.on("data", (chunk) => serverLogs.push(String(chunk)));
    server.stderr.on("data", (chunk) => serverLogs.push(String(chunk)));

    await waitForHealth(baseUrl, server, serverLogs);
  }

  async function stopServer(): Promise<void> {
    if (!server || server.killed) return;
    server.kill("SIGTERM");
    await new Promise((resolve) => setTimeout(resolve, 750));
    server = undefined;
  }

  beforeAll(async () => {
    container = await new PostgreSqlContainer("postgres:16-alpine").start();
    tmpHome = await mkdtemp(join(tmpdir(), "foreman-elixir-pg-"));
    databaseUrl = container.getConnectionUri();

    const migrate = spawnSync("mix", ["ecto.migrate"], {
      cwd: SERVER_DIR,
      env: {
        ...process.env,
        MIX_ENV: "test",
        DATABASE_URL: databaseUrl,
        FOREMAN_SERVER_EVENT_STORE_ADAPTER: "postgres",
      },
      encoding: "utf8",
      maxBuffer: MIX_SPAWN_MAX_BUFFER,
    });

    expect(migrate.status, `${migrate.error?.message ?? ""}\n${migrate.stdout}\n${migrate.stderr}`).toBe(0);

    port = await freePort();
    baseUrl = `http://127.0.0.1:${port}`;

    await startServer();
  }, 120_000);

  afterAll(async () => {
    await stopServer();
    await container?.stop();
    if (tmpHome) await rm(tmpHome, { recursive: true, force: true });
  });

  it("persists command events in Postgres and serves rebuilt projections", async () => {
    const projectId = `proj-${Date.now()}`;
    const taskId = `task-${Date.now()}`;

    await sendCommand(baseUrl, "project.register", {
      project_id: projectId,
      path: tmpHome,
      status: "active",
      default_branch: "main",
      config: { name: "Elixir PG E2E" },
    }, serverLogs);
    await sendCommand(baseUrl, "task.create", {
      task_id: taskId,
      project_id: projectId,
      title: "Persist through Postgres",
      description: "Created through Elixir command API",
      task_type: "smoke",
      status: "open",
    }, serverLogs);
    await sendCommand(baseUrl, "task.approve", { task_id: taskId }, serverLogs);

    const health = await fetch(new URL("/api/v1/health", baseUrl));
    expect(health.ok).toBe(true);
    const healthPayload = await health.json() as { runtime?: { projection_store?: { adapter?: string } } };
    expect(healthPayload.runtime?.projection_store?.adapter).toBe("postgres");

    const projects = await fetch(new URL("/api/v1/projects", baseUrl));
    expect(projects.ok).toBe(true);
    const projectPayload = await projects.json() as { projects?: Array<{ project_id: string }> };
    expect(projectPayload.projects ?? []).toEqual(expect.arrayContaining([expect.objectContaining({ project_id: projectId })]));

    const tasks = await fetch(new URL(`/api/v1/tasks?project_id=${projectId}`, baseUrl));
    expect(tasks.ok).toBe(true);
    const taskPayload = await tasks.json() as { tasks?: Array<{ task_id: string; status: string }> };
    expect(taskPayload.tasks ?? []).toEqual(expect.arrayContaining([expect.objectContaining({ task_id: taskId })]));

    const rebuild = await fetch(new URL("/api/v1/projections/rebuild", baseUrl), { method: "POST" });
    expect(rebuild.ok).toBe(true);
    const rebuildPayload = await rebuild.json() as { tasks?: number; projects?: number };
    expect(rebuildPayload.tasks).toBeGreaterThanOrEqual(1);
    expect(rebuildPayload.projects).toBeGreaterThanOrEqual(1);

    await stopServer();
    await startServer();

    const afterRestart = await fetch(new URL(`/api/v1/tasks?project_id=${projectId}`, baseUrl));
    expect(afterRestart.ok).toBe(true);
    const reloadedPayload = await afterRestart.json() as { tasks?: Array<{ task_id: string; status: string }> };
    expect(reloadedPayload.tasks ?? []).toEqual(expect.arrayContaining([expect.objectContaining({ task_id: taskId })]));
  }, 60_000);
});
