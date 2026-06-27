import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { chmodSync, closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync, spawn } from "node:child_process";
import { ElixirServerClient } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { runTsxModule, type ExecResult } from "../../test-support/tsx-subprocess.js";

const CLI = join(import.meta.dirname, "..", "..", "cli", "index.ts");
const PROJECT_ID = "elixir-e2e-project";

function pickPort(): number {
  return 4766;
}

function initGitProject(projectDir: string): void {
  execFileSync("git", ["init", "-b", "main"], { cwd: projectDir, stdio: "pipe" });
  execFileSync("git", ["config", "user.email", "foreman-e2e@example.com"], { cwd: projectDir, stdio: "pipe" });
  execFileSync("git", ["config", "user.name", "Foreman E2E"], { cwd: projectDir, stdio: "pipe" });
  writeFileSync(join(projectDir, "README.md"), "# elixir e2e\n", "utf8");
  execFileSync("git", ["add", "README.md"], { cwd: projectDir, stdio: "pipe" });
  execFileSync("git", ["commit", "-m", "Initial commit"], { cwd: projectDir, stdio: "pipe" });
}

function writeFakeWorkerBin(dir: string): string {
  const worker = join(dir, "fake-foreman-worker.sh");
  writeFileSync(worker, "#!/usr/bin/env bash\necho '[fake-worker] foreman $*'\nexit 0\n", "utf8");
  chmodSync(worker, 0o755);
  return worker;
}

function buildEnv(home: string, projectDir: string, eventLog: string, port: number, workerBin: string): NodeJS.ProcessEnv {
  const realHome = process.env.HOME;
  return {
    ...process.env,
    HOME: home,
    MIX_HOME: realHome ? join(realHome, ".mix") : process.env.MIX_HOME,
    HEX_HOME: realHome ? join(realHome, ".hex") : process.env.HEX_HOME,
    FOREMAN_BACKEND: "elixir",
    FOREMAN_RUNTIME_MODE: "test",
    FOREMAN_SERVER_HTTP_ENABLED: "true",
    FOREMAN_SERVER_HTTP_PORT: String(port),
    FOREMAN_SERVER_EVENT_LOG: eventLog,
    FOREMAN_WORKER_BIN: workerBin,
    FOREMAN_REGISTRY_BASE_DIR: join(home, ".foreman"),
    NO_COLOR: "1",
    GIT_TERMINAL_PROMPT: "0",
    GIT_ASKPASS: "true",
    PWD: projectDir,
  };
}

async function cli(args: string[], cwd: string, env: NodeJS.ProcessEnv, timeout = 60_000): Promise<ExecResult> {
  return runTsxModule(CLI, args, { cwd, env, timeout });
}

function expectSuccess(result: ExecResult, label: string): void {
  expect(result.exitCode, `${label}\nSTDOUT:\n${result.stdout}\nSTDERR:\n${result.stderr}`).toBe(0);
}

function expectFailure(result: ExecResult, label: string): void {
  expect(result.exitCode, `${label}\nSTDOUT:\n${result.stdout}\nSTDERR:\n${result.stderr}`).not.toBe(0);
}

async function waitFor<T>(fn: () => Promise<T>, predicate: (value: T) => boolean, timeoutMs = 30_000): Promise<T> {
  const start = Date.now();
  let value = await fn();
  while (Date.now() - start < timeoutMs) {
    if (predicate(value)) return value;
    await new Promise((resolve) => setTimeout(resolve, 250));
    value = await fn();
  }
  return value;
}

describe("Elixir native critical-path e2e", () => {
  const originalEnv = {
    HOME: process.env.HOME,
    MIX_HOME: process.env.MIX_HOME,
    HEX_HOME: process.env.HEX_HOME,
  };

  let tempRoot: string | undefined;
  let projectDir: string;
  let env: NodeJS.ProcessEnv;
  let manager: ElixirServerManager;
  let client: ElixirServerClient;
  let serverPort: number | undefined;
  let taskId: string;
  let runId: string;

  beforeAll(async () => {
    tempRoot = mkdtempSync(join(tmpdir(), "foreman-elixir-e2e-"));
    const home = join(tempRoot, "home");
    const projectDirRaw = join(tempRoot, "project");
    mkdirSync(join(home, ".foreman"), { recursive: true });
    mkdirSync(join(projectDirRaw, ".foreman"), { recursive: true });
    projectDir = realpathSync(projectDirRaw);
    initGitProject(projectDir);

    const port = pickPort();
    serverPort = port;
    const eventLog = join(tempRoot, "events.term.log");
    const workerBin = writeFakeWorkerBin(tempRoot);
    env = buildEnv(home, projectDir, eventLog, port, workerBin);
    Object.assign(process.env, env);

    const pidPath = join(projectDir, ".foreman", "elixir-server.pid");
    manager = new ElixirServerManager({ port, pidPath });
    const serverLog = join(tempRoot, "elixir-server.log");
    const logFd = openSync(serverLog, "a");
    const child = spawn("bash", ["-lc", "exec mix run --no-halt"], {
      cwd: join(import.meta.dirname, "..", "..", "..", "packages", "foreman_server"),
      detached: true,
      env,
      stdio: ["ignore", logFd, logFd],
    });
    closeSync(logFd);
    child.unref();
    writeFileSync(pidPath, String(child.pid), "utf8");

    const health = await waitFor(() => manager.health(), (result) => result.ok, 60_000);
    const logTail = existsSync(serverLog) ? readFileSync(serverLog, "utf8").slice(-4000) : "";
    expect(health.ok, `server health: ${health.error ?? JSON.stringify(health.body)}\n${logTail}`).toBe(true);
    try {
      const listenerPid = execFileSync("lsof", [`-tiTCP:${port}`, "-sTCP:LISTEN"], { encoding: "utf8" }).trim().split("\n")[0];
      if (listenerPid) writeFileSync(pidPath, listenerPid, "utf8");
    } catch {
      // CLI commands may start their own server if pid discovery is unavailable.
    }

    client = new ElixirServerClient(manager.url, env.FOREMAN_SERVER_AUTH_TOKEN);
    const register = await client.sendCommand({
      command_id: "e2e-project-register",
      command_type: "project.register",
      payload: {
        project_id: PROJECT_ID,
        name: "Elixir E2E Project",
        path: projectDir,
        status: "active",
        default_branch: "main",
      },
    });
    expect(register.ok, JSON.stringify(register)).toBe(true);
  }, 120_000);

  afterAll(() => {
    if (serverPort !== undefined) {
      try {
        const pids = execFileSync("lsof", [`-tiTCP:${serverPort}`, "-sTCP:LISTEN"], { encoding: "utf8" })
          .split("\n")
          .map((pid) => Number(pid.trim()))
          .filter((pid) => Number.isInteger(pid) && pid > 0);
        for (const pid of pids) process.kill(pid, "SIGTERM");
      } catch {
        // best effort cleanup
      }
    }
    serverPort = undefined;
    manager?.stop();
    delete process.env.FOREMAN_BACKEND;
    delete process.env.FOREMAN_RUNTIME_MODE;
    delete process.env.FOREMAN_SERVER_HTTP_ENABLED;
    delete process.env.FOREMAN_SERVER_HTTP_PORT;
    delete process.env.FOREMAN_SERVER_EVENT_LOG;
    delete process.env.FOREMAN_WORKER_BIN;
    delete process.env.FOREMAN_REGISTRY_BASE_DIR;
    for (const [key, value] of Object.entries(originalEnv)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    if (tempRoot) rmSync(tempRoot, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 });
  });

  it("reports server status and Elixir health", async () => {
    expectSuccess(await cli(["server", "status", "--port", String(serverPort)], projectDir, env), "server status");
    const daemonStatus = await cli(["daemon", "status", "--json"], projectDir, env);
    expectSuccess(daemonStatus, "daemon status");
    expect(daemonStatus.stdout).toContain('"running"');
    expect((await manager.health()).ok).toBe(true);
  });

  it("renders doctor and metrics views", async () => {
    expectSuccess(await cli(["doctor"], projectDir, env), "doctor");
    const doctorJson = await cli(["doctor", "--json"], projectDir, env);
    expectSuccess(doctorJson, "doctor --json");
    expect(doctorJson.stdout).toContain('"ok"');
    expectSuccess(await cli(["metrics", "--compact"], projectDir, env), "metrics --compact");
  });

  it("runs bare planning through Elixir", async () => {
    const plan = await cli(["plan", "Sketch an Elixir parity test", "--prd-only", "--output-dir", "docs/plans"], projectDir, env);
    expectSuccess(plan, "plan");
    expect(plan.stdout).toContain("Planning PRD command accepted");
  });

  it("creates, approves, lists, and shows a native task", async () => {
    const create = await cli(["task", "create", "--title", "Elixir E2E task", "--type", "feature", "--priority", "2"], projectDir, env);
    expectSuccess(create, "task create");
    taskId = create.stdout.match(/\[([^\]]+)\]/)?.[1] ?? "";
    expect(taskId, create.stdout).toBeTruthy();

    expectSuccess(await cli(["task", "approve", taskId], projectDir, env), "task approve");
    expectSuccess(await cli(["task", "list"], projectDir, env), "task list");
    expectSuccess(await cli(["task", "show", taskId], projectDir, env), "task show");
  });

  it("claims approved work through foreman run", async () => {
    expect(taskId).toBeTruthy();
    const run = await cli(["run", "--no-watch"], projectDir, env);
    expectSuccess(run, "run");
    expect(run.stdout).toContain("Elixir scheduler tick");

    const runs = await waitFor(() => client.listRuns(PROJECT_ID), (rows) => rows.length > 0, 20_000);
    expect(runs.length).toBeGreaterThan(0);
    runId = String(runs[0]!.run_id ?? runs[0]!.id);
    expect(runId).toBeTruthy();
  });

  it("renders Elixir read-only operator views", async () => {
    expect(runId).toBeTruthy();
    expectSuccess(await cli(["runs"], projectDir, env), "runs");
    expectSuccess(await cli(["status"], projectDir, env), "status");
    expectSuccess(await cli(["worktree", "list"], projectDir, env), "worktree list");
    expectSuccess(await cli(["worktree", "clean", "--dry-run"], projectDir, env), "worktree clean --dry-run");
    expectSuccess(await cli(["stop", "--list"], projectDir, env), "stop --list");
    expectSuccess(await cli(["stop", "--dry-run"], projectDir, env), "stop --dry-run");
    expectSuccess(await cli(["reset", "--dry-run"], projectDir, env), "reset --dry-run");
    expectSuccess(await cli(["purge", "logs", "--dry-run"], projectDir, env), "purge logs --dry-run");
    expectSuccess(await cli(["purge", "runs", "--dry-run"], projectDir, env), "purge runs --dry-run");
    expectSuccess(await cli(["logs", runId, "--raw", "--tail", "20"], projectDir, env), "logs --raw");
  });

  it("routes stop and reset through Elixir run events", async () => {
    const stop = await cli(["stop", "--force"], projectDir, env);
    expectSuccess(stop, "stop");
    expect(stop.stdout).toContain("Elixir");
    const reset = await cli(["reset"], projectDir, env);
    expectSuccess(reset, "reset");
    expect(reset.stdout).toContain("Resetting");
  });

  it("fails closed for legacy-only mutating commands", async () => {
    for (const [args, expected] of [
      [["worktree", "clean"], "FOREMAN_BACKEND=node"],
      [["purge", "logs"], "FOREMAN_BACKEND=node"],
      [["purge", "runs"], "FOREMAN_BACKEND=node"],
      [["doctor", "--fix"], "FOREMAN_BACKEND=node"],
      [["merge"], "FOREMAN_BACKEND=node"],
    ] as Array<[string[], string]>) {
      const result = await cli(args, projectDir, env);
      expectFailure(result, args.join(" "));
      expect(`${result.stdout}\n${result.stderr}`).toContain(expected);
    }
  });
});
