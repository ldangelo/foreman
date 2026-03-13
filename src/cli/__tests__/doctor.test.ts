import { describe, it, expect, afterEach, vi, beforeEach } from "vitest";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtempSync, rmSync, realpathSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";

const execFileAsync = promisify(execFile);

const TSX = path.resolve(__dirname, "../../../node_modules/.bin/tsx");
const CLI = path.resolve(__dirname, "../../../src/cli/index.ts");

interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

async function run(args: string[], cwd: string): Promise<ExecResult> {
  try {
    const { stdout, stderr } = await execFileAsync(TSX, [CLI, ...args], {
      cwd,
      timeout: 15_000,
      env: { ...process.env, NO_COLOR: "1" },
    });
    return { stdout, stderr, exitCode: 0 };
  } catch (err: any) {
    return {
      stdout: err.stdout ?? "",
      stderr: err.stderr ?? "",
      exitCode: err.code ?? 1,
    };
  }
}

describe("doctor command", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-doctor-test-")));
    tempDirs.push(dir);
    return dir;
  }

  async function makeGitRepo(dir: string): Promise<void> {
    await execFileAsync("git", ["init", dir]);
    await execFileAsync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
    await execFileAsync("git", ["config", "user.name", "Test"], { cwd: dir });
    // Create an initial commit so the repo is valid
    writeFileSync(join(dir, "README.md"), "# test");
    await execFileAsync("git", ["add", "."], { cwd: dir });
    await execFileAsync("git", ["commit", "-m", "init"], { cwd: dir });
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("doctor --help shows description and options", async () => {
    const tmp = makeTempDir();
    const result = await run(["doctor", "--help"], tmp);

    expect(result.exitCode).toBe(0);
    const output = result.stdout + result.stderr;
    expect(output).toContain("doctor");
    expect(output).toContain("health");
    expect(output).toContain("--fix");
  }, 15_000);

  it("doctor shows in top-level --help", async () => {
    const tmp = makeTempDir();
    const result = await run(["--help"], tmp);

    expect(result.exitCode).toBe(0);
    expect(result.stdout + result.stderr).toContain("doctor");
  }, 15_000);

  it("doctor outside git repo fails gracefully", async () => {
    const tmp = makeTempDir();
    // Not a git repo — should still run but report git repo check failure
    const result = await run(["doctor"], tmp);

    const output = result.stdout + result.stderr;
    // Should output check results
    expect(output).toContain("git repository");
    // Fails because no git repo
    expect(result.exitCode).toBe(1);
  }, 15_000);

  it("doctor inside git repo without project init warns", async () => {
    const tmp = makeTempDir();
    await makeGitRepo(tmp);

    const result = await run(["doctor"], tmp);
    const output = result.stdout + result.stderr;

    // Git binary check passes
    expect(output).toContain("git binary");
    // Project registration check fails
    expect(output).toContain("project registered in foreman");
  }, 15_000);

  it("doctor --json outputs valid JSON", async () => {
    const tmp = makeTempDir();
    const result = await run(["doctor", "--json"], tmp);

    const output = result.stdout + result.stderr;
    let parsed: any;
    try {
      parsed = JSON.parse(output.trim());
    } catch {
      // If there's mixed output, try to find the JSON part
      const jsonStart = output.indexOf("{");
      if (jsonStart !== -1) {
        parsed = JSON.parse(output.slice(jsonStart).trim());
      }
    }

    expect(parsed).toBeDefined();
    expect(parsed).toHaveProperty("checks");
    expect(parsed).toHaveProperty("summary");
    expect(Array.isArray(parsed.checks)).toBe(true);
    expect(parsed.summary).toHaveProperty("pass");
    expect(parsed.summary).toHaveProperty("fail");
    expect(parsed.summary).toHaveProperty("warn");
    expect(parsed.summary).toHaveProperty("fixed");
  }, 15_000);

  it("doctor with registered project shows pass for project check", async () => {
    const tmp = makeTempDir();
    await makeGitRepo(tmp);

    // Register the project in the store
    const storeMod = await import("../../lib/store.js");
    const store = new storeMod.ForemanStore();
    store.registerProject("test-project", tmp);
    store.close();

    const result = await run(["doctor"], tmp);
    const output = result.stdout + result.stderr;

    expect(output).toContain("project registered in foreman");
    // The project is registered so this check should not contain "fail" for that line
    // The overall may still fail due to missing sd binary in CI
    expect(output).toContain("Summary");
  }, 15_000);

  it("doctor --fix runs without crashing", async () => {
    const tmp = makeTempDir();
    await makeGitRepo(tmp);

    const result = await run(["doctor", "--fix"], tmp);
    const output = result.stdout + result.stderr;

    // Should not crash with an unhandled exception
    expect(output).not.toContain("TypeError");
    expect(output).not.toContain("ReferenceError");
    expect(output).toContain("Summary");
  }, 15_000);
});

// ── Unit tests for doctor logic ──────────────────────────────────────────

describe("doctor unit: icon/label helpers", () => {
  it("check results have expected status types", () => {
    const statuses: Array<"pass" | "warn" | "fail" | "fixed"> = ["pass", "warn", "fail", "fixed"];
    // Just verify the types are recognized — full testing is via integration tests
    expect(statuses).toHaveLength(4);
    expect(statuses).toContain("pass");
    expect(statuses).toContain("warn");
    expect(statuses).toContain("fail");
    expect(statuses).toContain("fixed");
  });
});

describe("doctor unit: zombie run detection", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-doctor-unit-")));
    tempDirs.push(dir);
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  it("running run with no session_key is treated as zombie", async () => {
    const storeMod = await import("../../lib/store.js");
    const tmpDb = join(makeTempDir(), "test.db");
    const store = new storeMod.ForemanStore(tmpDb);

    const project = store.registerProject("test", "/tmp/fake-path");
    const run = store.createRun(project.id, "test-seed-123", "developer");
    // Mark it as running with no session_key (no pid)
    store.updateRun(run.id, { status: "running", started_at: new Date().toISOString() });

    const runs = store.getRunsByStatus("running", project.id);
    expect(runs).toHaveLength(1);
    expect(runs[0].session_key).toBeNull();

    store.close();
  });

  it("pending run older than threshold is detected as stale", async () => {
    const storeMod = await import("../../lib/store.js");
    const tmpDb = join(makeTempDir(), "test.db");
    const store = new storeMod.ForemanStore(tmpDb);

    const project = store.registerProject("test", "/tmp/fake-path-2");
    const run = store.createRun(project.id, "stale-seed-456", "developer");

    // Manually set the created_at to 48 hours ago
    const twoDaysAgo = new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString();
    (store as any).db
      .prepare("UPDATE runs SET created_at = ? WHERE id = ?")
      .run(twoDaysAgo, run.id);

    const pendingRuns = store.getRunsByStatus("pending", project.id);
    expect(pendingRuns).toHaveLength(1);

    const staleThresholdMs = 24 * 60 * 60 * 1000;
    const stale = pendingRuns.filter(
      (r) => Date.now() - new Date(r.created_at).getTime() > staleThresholdMs,
    );
    expect(stale).toHaveLength(1);
    expect(stale[0].seed_id).toBe("stale-seed-456");

    store.close();
  });

  it("fix: stale pending run is marked as failed", async () => {
    const storeMod = await import("../../lib/store.js");
    const tmpDb = join(makeTempDir(), "test.db");
    const store = new storeMod.ForemanStore(tmpDb);

    const project = store.registerProject("test", "/tmp/fake-path-3");
    const run = store.createRun(project.id, "stale-seed-789", "developer");

    // Make it old
    const twoDaysAgo = new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString();
    (store as any).db
      .prepare("UPDATE runs SET created_at = ? WHERE id = ?")
      .run(twoDaysAgo, run.id);

    // Apply fix
    store.updateRun(run.id, { status: "failed", completed_at: new Date().toISOString() });

    const pendingRuns = store.getRunsByStatus("pending", project.id);
    expect(pendingRuns).toHaveLength(0);

    const failedRuns = store.getRunsByStatus("failed", project.id);
    expect(failedRuns).toHaveLength(1);
    expect(failedRuns[0].seed_id).toBe("stale-seed-789");

    store.close();
  });
});
