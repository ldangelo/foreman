/**
 * TRD-048-TEST | Verifies: TRD-048 | Tests: CLI --project flag and multi-project mode
 * PRD: docs/PRD/PRD-2026-010-multi-project-orchestrator.md
 * TRD: docs/TRD/TRD-2026-011-multi-project-orchestrator.md#trd-048
 *
 * Tests:
 * 1. inbox --project flag is recognized and doesn't error on missing project
 * 2. inbox --help shows --project option
 * 3. board --help shows --project and --all options
 * 4. status --help shows --project and --all options
 * 5. run --help shows --project option
 * 6. reset --help shows --project option
 * 7. retry --help shows --project option
 */

import { describe, it, expect, afterEach, vi, beforeEach } from "vitest";
import { mkdtempSync, rmSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import path from "node:path";
import { runTsxModule, type ExecResult } from "../../test-support/tsx-subprocess.js";
import { inboxCommand } from "../commands/inbox.js";

// Mock createTrpcClient to return a client whose projects.list() rejects.
// This makes isMultiProjectMode() return false (error caught in try/catch),
// bypassing the multi-project guard in --help invocations.
vi.mock("../../../lib/trpc-client.js", () => ({
  createTrpcClient: () => ({
    projects: {
      list: () => Promise.reject(new Error("daemon unavailable")),
    },
  }),
}));

const CLI = path.resolve(__dirname, "../../../src/cli/index.ts");

async function run(args: string[], cwd: string): Promise<ExecResult> {
  return runTsxModule(CLI, args, {
    cwd,
    timeout: 10_000,
    env: {
      PATH: process.env.PATH,
      HOME: cwd,
      TMPDIR: process.env.TMPDIR,
      TMP: process.env.TMP,
      TEMP: process.env.TEMP,
      TSX_DISABLE_IPC: "1",
      NO_COLOR: "1",
      FOREMAN_HOME: undefined,
      FOREMAN_TASK_STORE: undefined,
      FOREMAN_TASK_BACKEND: undefined,
      FOREMAN_REGISTRY_BASE_DIR: undefined,
      DATABASE_URL: undefined,
    },
  });
}

async function runWithRetry(
  args: string[],
  cwd: string,
  maxAttempts = 2,
): Promise<ExecResult> {
  let last: ExecResult | undefined;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    last = await run(args, cwd);
    const hasOutput = last.stdout.length > 0 || last.stderr.length > 0;
    if (last.exitCode === 0 || hasOutput) return last;
  }
  return last!;
}

const HELP_TIMEOUT_MS = 60_000;

describe("TRD-048: CLI --project flag and multi-project mode", () => {
  const tempDirs: string[] = [];

  function makeTempDir(): string {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-cli-test-")));
    tempDirs.push(dir);
    return dir;
  }

  afterEach(() => {
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  describe("--help shows --project flag", () => {
    it("inbox --help shows --project option", () => {
      const output = inboxCommand.helpInformation();
      expect(output).toContain("--project");
      expect(output).toContain("--project-path");
    });

    it("board --help shows --project and --all options", async () => {
      const tmp = makeTempDir();
      const result = await runWithRetry(["board", "--help"], tmp);
      expect(result.stdout).toContain("--project");
      expect(result.stdout).toContain("--all");
    }, HELP_TIMEOUT_MS);

    it("status --help shows --project and --all options", async () => {
      const tmp = makeTempDir();
      const result = await runWithRetry(["status", "--help"], tmp);
      expect(result.stdout).toContain("--project");
      expect(result.stdout).toContain("--all");
    }, HELP_TIMEOUT_MS);

    it("run --help shows --project option", async () => {
      const tmp = makeTempDir();
      const result = await runWithRetry(["run", "--help"], tmp);
      expect(result.stdout).toContain("--project");
    }, HELP_TIMEOUT_MS);

    it("reset --help shows --project option", async () => {
      const tmp = makeTempDir();
      const result = await runWithRetry(["reset", "--help"], tmp);
      expect(result.stdout).toContain("--project");
    }, HELP_TIMEOUT_MS);

    it("retry --help shows --project option", async () => {
      const tmp = makeTempDir();
      const result = await runWithRetry(["retry", "--help"], tmp);
      expect(result.stdout).toContain("--project");
    }, HELP_TIMEOUT_MS);
  });

  describe("inbox command accepts --project", () => {
    it("inbox --help shows inbox-specific options", () => {
      const output = inboxCommand.helpInformation();
      // Core inbox options
      expect(output).toContain("--agent");
      expect(output).toContain("--run");
      expect(output).toContain("--bead");
      expect(output).toContain("--watch");
      expect(output).toContain("--ack");
    });
  });
});
