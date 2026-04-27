import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, mkdirSync, existsSync, readFileSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { spawn, type ChildProcess } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { Client } from "pg";
import { runTsxModule } from "../../test-support/tsx-subprocess.js";
import { initPool, destroyPool } from "../../lib/db/pool-manager.js";
import { PostgresAdapter } from "../../lib/db/postgres-adapter.js";
import { ProjectRegistry } from "../../lib/project-registry.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const CLI = join(__dirname, "..", "..", "cli", "index.ts");
const TSX_LOADER = join(__dirname, "..", "..", "..", "node_modules", "tsx", "dist", "loader.mjs");
const DAEMON_ENTRY = join(__dirname, "..", "..", "daemon", "index.ts");

function readDatabaseUrl(): string {
  const envPath = join(process.cwd(), ".env");
  const match = readFileSync(envPath, "utf8").match(/^\s*DATABASE_URL=(.+)\s*$/m);
  if (!match?.[1]) {
    throw new Error("DATABASE_URL missing from repo .env");
  }
  return match[1].trim().replace(/^['"]|['"]$/g, "");
}

async function waitForSocket(socketPath: string, timeoutMs = 10_000): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (existsSync(socketPath)) return;
    await sleep(100);
  }
  throw new Error(`Timed out waiting for daemon socket at ${socketPath}`);
}

async function waitForDaemonReady(cliPath: string, cwd: string, env: NodeJS.ProcessEnv, timeoutMs = 15_000): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const result = await runTsxModule(cliPath, ["project", "list"], {
      cwd,
      timeout: 5_000,
      env,
    });
    if (result.exitCode === 0) {
      return;
    }
    await sleep(250);
  }
  throw new Error("Timed out waiting for daemon RPC readiness");
}

async function canConnect(databaseUrl: string): Promise<boolean> {
  const client = new Client({ connectionString: databaseUrl });
  try {
    await client.connect();
    return true;
  } catch {
    return false;
  } finally {
    await client.end().catch(() => undefined);
  }
}

describe("task CLI daemon/Postgres integration", () => {
  let tempHome: string;
  let projectDir: string;
  let projectName: string;
  let daemon: ChildProcess | null = null;
  let registry: ProjectRegistry;
  let projectId: string;
  const databaseUrl = readDatabaseUrl();

  beforeEach(async () => {
    if (!(await canConnect(databaseUrl))) {
      return;
    }

    tempHome = mkdtempSync(join(tmpdir(), "foreman-task-daemon-home-"));
    mkdirSync(join(tempHome, ".foreman"), { recursive: true });
    projectDir = mkdtempSync(join(tmpdir(), "foreman-task-daemon-project-"));
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });
    projectName = `task-daemon-test-${Date.now().toString(36)}`;

    process.env.HOME = tempHome;
    await destroyPool();
    initPool({ databaseUrl });
    registry = new ProjectRegistry({ baseDir: join(tempHome, ".foreman"), pg: new PostgresAdapter() });
    const record = await registry.add({
      name: projectName,
      path: projectDir,
      defaultBranch: "main",
      status: "active",
    });
    projectId = record.id;

    daemon = spawn(process.execPath, ["--import", TSX_LOADER, DAEMON_ENTRY], {
      cwd: process.cwd(),
      env: {
        ...process.env,
        HOME: tempHome,
        DATABASE_URL: databaseUrl,
      },
      stdio: "ignore",
    });
    await waitForSocket(join(tempHome, ".foreman", "daemon.sock"));
    await waitForDaemonReady(CLI, projectDir, {
      ...process.env,
      HOME: tempHome,
      DATABASE_URL: databaseUrl,
    });
  });

  afterEach(async () => {
    if (!tempHome) {
      return;
    }

    if (daemon && !daemon.killed) {
      daemon.kill("SIGTERM");
      await sleep(500);
    }
    try {
      await registry.remove(projectId);
    } catch {
      // best effort cleanup
    }
    await destroyPool();
    rmSync(projectDir, { recursive: true, force: true });
    rmSync(tempHome, { recursive: true, force: true });
  });

  it("creates, lists, shows, and approves tasks through the daemon/Postgres path", async () => {
    if (!(await canConnect(databaseUrl))) {
      return;
    }

    const env = {
      ...process.env,
      HOME: tempHome,
      DATABASE_URL: databaseUrl,
    };

    const create = await runTsxModule(
      CLI,
      ["task", "create", "--project", projectName, "--title", "Daemon Task"],
      { cwd: projectDir, timeout: 20_000, env },
    );
    expect(create.exitCode).toBe(0);
    const createdIdMatch = (create.stdout + create.stderr).match(new RegExp(`\\[(${projectName}-[0-9a-f]{5})\\]`, "i"));
    expect(createdIdMatch).not.toBeNull();
    const taskId = createdIdMatch![1];

    const list = await runTsxModule(
      CLI,
      ["task", "list", "--project", projectName],
      { cwd: projectDir, timeout: 20_000, env },
    );
    expect(list.exitCode).toBe(0);
    expect(list.stdout + list.stderr).toContain(taskId);

    const show = await runTsxModule(
      CLI,
      ["task", "show", taskId, "--project", projectName],
      { cwd: projectDir, timeout: 20_000, env },
    );
    expect(show.exitCode).toBe(0);
    expect(show.stdout + show.stderr).toContain(`ID:          ${taskId}`);

    const approve = await runTsxModule(
      CLI,
      ["task", "approve", taskId, "--project", projectName],
      { cwd: projectDir, timeout: 20_000, env },
    );
    expect(approve.exitCode).toBe(0);

    const adapter = new PostgresAdapter();
    const task = await adapter.getTask(projectId, taskId);
    expect(task?.status).toBe("ready");
    expect(task?.title).toBe("Daemon Task");
  });
});
