import { PostgreSqlContainer, type StartedPostgreSqlContainer } from "@testcontainers/postgresql";
import { spawn, spawnSync, execFileSync, type ChildProcessWithoutNullStreams } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:net";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { installBundledPrompts } from "../../lib/prompt-loader.js";
import { installBundledWorkflows } from "../../lib/workflow-loader.js";
import { runCommand } from "../../cli/commands/run.js";

const SERVER_DIR = join(process.cwd(), "packages", "foreman_server");
const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const PHASE_RUNNER_MODULE = join(PROJECT_ROOT, "src", "test-support", "deterministic-phase-runner.ts");
const WORKFLOWS = ["smoke", "default", "feature", "task", "bug", "chore", "docs", "question", "quick", "epic"] as const;

async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close(() => typeof address === "object" && address ? resolve(address.port) : reject(new Error("no port")));
    });
  });
}

async function waitForHealth(baseUrl: string, proc: ChildProcessWithoutNullStreams, logs: string[]): Promise<void> {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (proc.exitCode !== null) throw new Error(`Elixir server exited early: ${proc.exitCode}\n${logs.join("")}`);
    try {
      const response = await fetch(new URL("/api/v1/health", baseUrl));
      if (response.ok) return;
    } catch { /* retry */ }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`Elixir server did not become healthy\n${logs.join("")}`);
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
}

function git(cwd: string, args: string[]) {
  execFileSync("git", args, { cwd, stdio: "pipe" });
}

function createProject() {
  const projectPath = realpathSync(mkdtempSync(join(tmpdir(), "foreman-workflow-e2e-project-")));
  mkdirSync(join(projectPath, ".foreman"), { recursive: true });
  writeFileSync(join(projectPath, "package.json"), JSON.stringify({
    type: "module",
    scripts: {
      test: "node -e \"process.exit(0)\"",
      "test:unit": "node -e \"process.exit(0)\"",
    },
    devDependencies: {},
  }, null, 2));
  writeFileSync(join(projectPath, "README.md"), "# Workflow E2E\n");
  writeFileSync(join(projectPath, "test.txt"), "base\n");
  git(projectPath, ["init", "-b", "main"]);
  git(projectPath, ["config", "user.name", "Foreman Test"]);
  git(projectPath, ["config", "user.email", "foreman-test@example.com"]);
  git(projectPath, ["add", "-A"]);
  git(projectPath, ["commit", "-m", "Initial commit"]);
  installBundledPrompts(projectPath, true);
  installBundledWorkflows(projectPath, true);
  return projectPath;
}

async function taskStatuses(baseUrl: string, projectId: string): Promise<Record<string, string>> {
  const response = await fetch(new URL(`/api/v1/tasks?project_id=${projectId}`, baseUrl));
  expect(response.ok).toBe(true);
  const payload = await response.json() as { tasks?: Array<{ task_id: string; status: string }> };
  return Object.fromEntries((payload.tasks ?? []).map((task) => [task.task_id, task.status]));
}

async function waitForSettled(baseUrl: string, projectId: string, taskIds: string[]) {
  const active = new Set(["open", "ready", "approved", "in_progress", "in-progress"]);
  const deadline = Date.now() + 120_000;
  let latest: Record<string, string> = {};
  while (Date.now() < deadline) {
    latest = await taskStatuses(baseUrl, projectId);
    if (taskIds.every((taskId) => latest[taskId] && !active.has(latest[taskId]))) return latest;
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`workflow tasks did not settle: ${JSON.stringify(latest)}`);
}

describe("workflow matrix e2e on Elixir/Postgres", () => {
  let container: StartedPostgreSqlContainer;
  let tmpHome: string;
  let foremanHome: string;
  let projectPath: string;
  let baseUrl: string;
  let foremanExecutable: string;
  let server: ChildProcessWithoutNullStreams | undefined;
  let serverLogs: string[] = [];

  beforeAll(async () => {
    container = await new PostgreSqlContainer("postgres:16-alpine").start();
    tmpHome = await mkdtemp(join(tmpdir(), "foreman-workflow-e2e-home-"));
    foremanHome = join(tmpHome, ".foreman");
    mkdirSync(foremanHome, { recursive: true });
    process.env.FOREMAN_HOME = foremanHome;
    foremanExecutable = join(tmpHome, "foreman-local");
    writeFileSync(foremanExecutable, `#!/usr/bin/env bash\nexec ${JSON.stringify(join(process.cwd(), "node_modules", ".bin", "tsx"))} ${JSON.stringify(join(process.cwd(), "src", "cli", "index.ts"))} "$@"\n`);
    chmodSync(foremanExecutable, 0o755);
    projectPath = createProject();

    const databaseUrl = container.getConnectionUri();
    const migrate = spawnSync("mix", ["ecto.migrate"], {
      cwd: SERVER_DIR,
      env: { ...process.env, MIX_ENV: "test", DATABASE_URL: databaseUrl, FOREMAN_SERVER_EVENT_STORE_ADAPTER: "postgres" },
      encoding: "utf8",
    });
    expect(migrate.status, `${migrate.stdout}\n${migrate.stderr}`).toBe(0);

    const port = await freePort();
    baseUrl = `http://127.0.0.1:${port}`;
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
        FOREMAN_SERVER_EVENT_LOG: join(tmpHome, "unused.term.log"),
        FOREMAN_EXECUTABLE: foremanExecutable,
        FOREMAN_RUNTIME_MODE: "test",
        FOREMAN_PHASE_RUNNER_MODULE: PHASE_RUNNER_MODULE,
        FOREMAN_HOME: foremanHome,
      },
    });
    server.stdout.on("data", (chunk) => serverLogs.push(String(chunk)));
    server.stderr.on("data", (chunk) => serverLogs.push(String(chunk)));
    await waitForHealth(baseUrl, server, serverLogs);
  }, 120_000);

  afterAll(async () => {
    server?.kill("SIGTERM");
    await container?.stop();
    if (tmpHome) await rm(tmpHome, { recursive: true, force: true });
    if (projectPath) rmSync(projectPath, { recursive: true, force: true, maxRetries: 20, retryDelay: 250 });
    delete process.env.FOREMAN_SERVER_URL;
    delete process.env.FOREMAN_RUNTIME_MODE;
    delete process.env.FOREMAN_PHASE_RUNNER_MODULE;
    delete process.env.FOREMAN_HOME;
    delete process.env.FOREMAN_EXECUTABLE;
  });

  it("runs every bundled workflow through existing YAML and prompts", { timeout: 180_000 }, async () => {
    const projectId = `workflow-e2e-${Date.now()}`;
    process.env.FOREMAN_SERVER_URL = baseUrl;
    process.env.FOREMAN_RUNTIME_MODE = "test";
    process.env.FOREMAN_PHASE_RUNNER_MODULE = PHASE_RUNNER_MODULE;
    process.env.FOREMAN_HOME = foremanHome;
    process.env.FOREMAN_EXECUTABLE = foremanExecutable;

    await sendCommand(baseUrl, "project.register", {
      project_id: projectId,
      path: projectPath,
      status: "active",
      default_branch: "main",
      config: { name: "Workflow E2E" },
    }, serverLogs);

    for (const workflow of WORKFLOWS) {
      const taskId = `e2e-${workflow}-${Date.now()}`;
      await sendCommand(baseUrl, "task.create", {
        task_id: taskId,
        project_id: projectId,
        title: `E2E ${workflow}`,
        description: `Run ${workflow}\nFOREMAN_TEST_SCENARIO={"kind":"append","file":"test.txt","content":"${workflow}\\n"}`,
        task_type: workflow,
        status: "open",
      }, serverLogs);
      await sendCommand(baseUrl, "task.approve", { task_id: taskId }, serverLogs);

      const originalCwd = process.cwd();
      const errors: string[] = [];
      const originalError = console.error;
      console.error = (...args: unknown[]) => {
        errors.push(args.map(String).join(" "));
        originalError(...args);
      };
      try {
        process.chdir(projectPath);
        await runCommand.parseAsync(["--runtime-mode", "test", "--no-watch", "--max-agents", "1"], { from: "user" });
      } catch (error) {
        throw new Error(`${workflow}: ${error instanceof Error ? error.message : String(error)}\n${errors.join("\n")}`);
      } finally {
        console.error = originalError;
        process.chdir(originalCwd);
      }

      const settled = await waitForSettled(baseUrl, projectId, [taskId]);
      if (["failed", "blocked"].includes(settled[taskId] ?? "missing")) {
        const events = await fetch(new URL(`/api/v1/events?project_id=${projectId}&limit=80`, baseUrl));
        throw new Error(`${workflow} failed with ${JSON.stringify(settled, null, 2)}\n${await events.text()}`);
      }
    }
  });
});
