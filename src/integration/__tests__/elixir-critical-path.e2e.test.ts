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

function writeFakeGhBin(dir: string): string {
  const binDir = join(dir, "bin");
  mkdirSync(binDir, { recursive: true });
  const gh = join(binDir, "gh");
  writeFileSync(gh, `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] !== "api") process.exit(1);
const endpoint = args[1] || "";
const issue = {
  id: 7001,
  number: 7001,
  title: "Elixir imported GitHub issue",
  body: "Imported through fake gh for Elixir e2e",
  state: "open",
  user: { login: "octocat", id: 1 },
  labels: [{ id: 2, name: "bug", color: "b60205" }],
  assignees: [],
  milestone: { id: 3, title: "v1", number: 1 },
  created_at: "2026-06-29T00:00:00Z",
  updated_at: "2026-06-29T01:00:00Z",
  closed_at: null,
  url: "https://api.github.com/repos/owner/repo/issues/7001",
  html_url: "https://github.com/owner/repo/issues/7001"
};
if (endpoint === "/repos/owner/repo/issues/7001") {
  console.log(JSON.stringify(issue));
  process.exit(0);
}
if (endpoint.startsWith("/repos/owner/repo/issues")) {
  console.log(JSON.stringify([issue]));
  process.exit(0);
}
console.error("unexpected fake gh endpoint " + endpoint);
process.exit(1);
`, "utf8");
  chmodSync(gh, 0o755);
  return binDir;
}

function buildEnv(home: string, projectDir: string, eventLog: string, port: number, workerBin: string, ghBinDir: string): NodeJS.ProcessEnv {
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
    PATH: `${ghBinDir}:${process.env.PATH ?? ""}`,
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
    const ghBinDir = writeFakeGhBin(tempRoot);
    env = buildEnv(home, projectDir, eventLog, port, workerBin, ghBinDir);
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
    expectSuccess(await cli(["metrics", "--costs", "--compact", "--phase", "developer"], projectDir, env), "metrics --costs --compact");
    expectSuccess(await cli(["sentinel", "run-once", "--json"], projectDir, env), "sentinel run-once");
    expectSuccess(await cli(["sentinel", "start", "--json"], projectDir, env), "sentinel start");
    expectSuccess(await cli(["sentinel", "stop", "--json"], projectDir, env), "sentinel stop");
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

  it("imports TRD tasks through sling into Elixir", async () => {
    const trdDir = join(projectDir, "docs", "TRD");
    mkdirSync(trdDir, { recursive: true });
    writeFileSync(join(trdDir, "e2e-sling.md"), `# TRD: E2E Sling Import

**Document ID:** TRD-E2E-SLING

## 2. Master Task List

### 2.1 Sprint 1: Import

#### Story 1.1: Create one task

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| E2E-T001 | Verify Elixir sling import | 1h | -- | \`README.md\` | [ ] |
`, "utf8");

    const sling = await cli(["sling", "trd", "docs/TRD/e2e-sling.md", "--auto"], projectDir, env);
    expectSuccess(sling, "sling trd");
    expect(sling.stdout).toContain("Summary: native:");
    const tasks = await client.listTasks();
    expect(tasks.some((task) => task.external_id === "trd:TRD-E2E-SLING")).toBe(true);
    expect(tasks.some((task) => task.external_id === "trd:E2E-T001")).toBe(true);
  });

  it("imports a GitHub issue through Elixir integration ingestion", async () => {
    const imported = await cli(["issue", "import", "--repo", "owner/repo", "--issue", "7001", "--project", PROJECT_ID], projectDir, env);
    expectSuccess(imported, "issue import");
    expect(imported.stdout).toContain("Imported #7001 as task");

    const tasks = await client.listTasks();
    const task = tasks.find((row) => row.external_id === "github:owner/repo#7001");
    expect(task?.title).toBe("Elixir imported GitHub issue");
    expect(task?.source).toBe("github");
    expect(task?.labels).toEqual(expect.arrayContaining(["github:bug"]));
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
    expectSuccess(await cli(["pr", "--json"], projectDir, env), "pr --json");
    expectSuccess(await cli(["stop", "--list"], projectDir, env), "stop --list");
    expectSuccess(await cli(["stop", "--dry-run"], projectDir, env), "stop --dry-run");
    expectSuccess(await cli(["reset", "--dry-run"], projectDir, env), "reset --dry-run");
    expectSuccess(await cli(["purge", "logs", "--dry-run"], projectDir, env), "purge logs --dry-run");
    const stale = await client.sendCommand({
      command_id: "e2e-stale-run-fail",
      command_type: "run.fail",
      payload: { run_id: "e2e-stale-run", reason: "e2e stale run" },
    });
    expect(stale.ok, JSON.stringify(stale)).toBe(true);
    expectSuccess(await cli(["purge", "runs", "--dry-run"], projectDir, env), "purge runs --dry-run");
    expectSuccess(await cli(["purge", "runs"], projectDir, env), "purge runs");
    const staleRun = (await client.listRuns()).find((run) => run.run_id === "e2e-stale-run");
    expect(staleRun?.status).toBe("archived");
    expectSuccess(await cli(["logs", runId, "--raw", "--tail", "20"], projectDir, env), "logs --raw");
  });

  it("routes attach kill, stop, and reset through Elixir run events", async () => {
    const attachKill = await cli(["attach", runId, "--kill"], projectDir, env);
    expectSuccess(attachKill, "attach --kill");
    expect(attachKill.stdout).toContain("Elixir run stopped");

    const create = await cli(["task", "create", "--title", "Elixir stop task", "--type", "feature", "--priority", "2"], projectDir, env);
    expectSuccess(create, "task create for stop");
    const stopTaskId = create.stdout.match(/\[([^\]]+)\]/)?.[1] ?? "";
    expect(stopTaskId, create.stdout).toBeTruthy();
    expectSuccess(await cli(["task", "approve", stopTaskId], projectDir, env), "task approve for stop");
    expectSuccess(await cli(["run", "--no-watch"], projectDir, env), "run for stop");

    const stop = await cli(["stop", "--force"], projectDir, env);
    expectSuccess(stop, "stop");
    expect(stop.stdout).toContain("Elixir");
    const reset = await cli(["reset"], projectDir, env);
    expectSuccess(reset, "reset");
    expect(reset.stdout).toContain("Resetting");
  });

  it("dispatches foreman run task through Elixir scheduler", async () => {
    const create = await cli(["task", "create", "--title", "Elixir direct run task", "--type", "feature", "--priority", "2"], projectDir, env);
    expectSuccess(create, "task create for direct run");
    const directTaskId = create.stdout.match(/\[([^\]]+)\]/)?.[1] ?? "";
    expect(directTaskId, create.stdout).toBeTruthy();

    let runTask = await cli(["run", "task", directTaskId, "default", "--no-watch"], projectDir, env);
    if (runTask.exitCode !== 0 && runTask.stderr.includes("global_capacity_exhausted")) {
      expectSuccess(await cli(["stop", "--force"], projectDir, env), "stop before run task retry");
      runTask = await cli(["run", "task", directTaskId, "default", "--no-watch"], projectDir, env);
    }
    expectSuccess(runTask, "run task");
    expect(runTask.stdout).toContain("Elixir scheduler claimed");

    const task = await client.getTask(directTaskId);
    expect(task?.status).toBe("in_progress");
    expect(task?.workflow).toBe("default");
  });

  it("fails closed for legacy-only mutating commands", async () => {
    for (const [args, expected] of [
      [["doctor", "--fix"], "FOREMAN_BACKEND=node"],
    ] as Array<[string[], string]>) {
      const result = await cli(args, projectDir, env);
      expectFailure(result, args.join(" "));
      expect(`${result.stdout}\n${result.stderr}`).toContain(expected);
    }
  });
});
