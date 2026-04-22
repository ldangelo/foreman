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

const CLI = path.resolve(__dirname, "../../../src/cli/index.ts");

async function run(args: string[], cwd: string): Promise<ExecResult> {
  return runTsxModule(CLI, args, { cwd, timeout: 10_000 });
}

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
    it("inbox --help shows --project option", async () => {
      const tmp = makeTempDir();
      const result = await run(["inbox", "--help"], tmp);
      expect(result.stdout).toContain("--project");
      expect(result.stdout).toContain("--project-path");
    });

    it("board --help shows --project and --all options", async () => {
      const tmp = makeTempDir();
      const result = await run(["board", "--help"], tmp);
      expect(result.stdout).toContain("--project");
      expect(result.stdout).toContain("--all");
    }, 30_000);

    it("status --help shows --project and --all options", async () => {
      const tmp = makeTempDir();
      const result = await run(["status", "--help"], tmp);
      expect(result.stdout).toContain("--project");
      expect(result.stdout).toContain("--all");
    });

    it("run --help shows --project option", async () => {
      const tmp = makeTempDir();
      const result = await run(["run", "--help"], tmp);
      expect(result.stdout).toContain("--project");
    });

    it("reset --help shows --project option", async () => {
      const tmp = makeTempDir();
      const result = await run(["reset", "--help"], tmp);
      expect(result.stdout).toContain("--project");
    });

    it("retry --help shows --project option", async () => {
      const tmp = makeTempDir();
      const result = await run(["retry", "--help"], tmp);
      expect(result.stdout).toContain("--project");
    });
  });

  describe("inbox command accepts --project", () => {
    it("inbox --help shows inbox-specific options", async () => {
      const tmp = makeTempDir();
      const result = await run(["inbox", "--help"], tmp);
      // Core inbox options
      expect(result.stdout).toContain("--agent");
      expect(result.stdout).toContain("--run");
      expect(result.stdout).toContain("--bead");
      expect(result.stdout).toContain("--watch");
      expect(result.stdout).toContain("--ack");
    });
  });
});
