import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const { mockRunWithPiSdk } = vi.hoisted(() => ({
  mockRunWithPiSdk: vi.fn(),
}));

vi.mock("../../orchestrator/pi-sdk-runner.js", () => ({
  runWithPiSdk: (...args: unknown[]) => mockRunWithPiSdk(...args),
}));

import { slingCommand, parsePrdReadinessScore } from "../commands/sling.js";

async function runCommand(args: string[], cwd: string): Promise<{ stdout: string; stderr: string }> {
  const stdoutLines: string[] = [];
  const stderrLines: string[] = [];
  const origLog = console.log;
  const origWarn = console.warn;
  const origError = console.error;
  const originalCwd = process.cwd();

  console.log = (...a: unknown[]) => stdoutLines.push(a.join(" "));
  console.warn = (...a: unknown[]) => stderrLines.push(a.join(" "));
  console.error = (...a: unknown[]) => stderrLines.push(a.join(" "));
  process.chdir(cwd);

  try {
    await slingCommand.parseAsync(args, { from: "user" });
  } finally {
    process.chdir(originalCwd);
    console.log = origLog;
    console.warn = origWarn;
    console.error = origError;
  }

  return { stdout: stdoutLines.join("\n"), stderr: stderrLines.join("\n") };
}

describe("sling prd", () => {
  let tmpDir: string;
  let prdPath: string;
  let trdDir: string;

  beforeEach(() => {
    vi.clearAllMocks();
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-sling-prd-"));
    mkdirSync(join(tmpDir, "docs", "PRD"), { recursive: true });
    mkdirSync(join(tmpDir, "docs", "TRD"), { recursive: true });
    prdPath = join(tmpDir, "docs", "PRD", "PRD-2026-999-demo.md");
    trdDir = join(tmpDir, "docs", "TRD");

    writeFileSync(
      prdPath,
      [
        "# Demo PRD",
        "",
        "- **Readiness Score:** 4.2",
        "",
        "## Requirements",
        "- REQ-001: Example",
      ].join("\n"),
      "utf-8",
    );

    mockRunWithPiSdk.mockImplementation(async () => {
      const trdPath = join(trdDir, "TRD-2026-999-demo.md");
      writeFileSync(
        trdPath,
        [
          "# TRD: Demo",
          "",
          "**Document ID:** TRD-2026-999",
          "**Version:** 1.0",
          "",
          "### 1.1 Sprint 1: Foundation",
          "",
          "#### Story 1.1: First story",
          "",
          "| ID | Task | Estimate | Dependencies | Files | Status |",
          "| --- | --- | --- | --- | --- | --- |",
          "| FSC-T001 | Implement validator | 2h | -- | `validator.ts` | [ ] |",
          "",
        ].join("\n"),
        "utf-8",
      );

      return {
        success: true,
        costUsd: 0,
        turns: 1,
        toolCalls: 0,
        toolBreakdown: {},
        tokensIn: 0,
        tokensOut: 0,
      };
    });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    vi.unstubAllEnvs();
  });

  it("parses readiness scores from generated PRDs", () => {
    expect(parsePrdReadinessScore("**Readiness Score:** 4.2")).toBe(4.2);
    expect(parsePrdReadinessScore("readiness_score: 3.5")).toBe(3.5);
    expect(parsePrdReadinessScore("no score here")).toBeNull();
  });

  it("runs create-trd-foreman and previews the parsed plan in dry-run json mode", async () => {
    const result = await runCommand(["prd", prdPath, "--project-path", tmpDir, "--auto", "--dry-run", "--json"], tmpDir);

    expect(mockRunWithPiSdk).toHaveBeenCalledOnce();
    const parsed = JSON.parse(result.stdout);
    expect(parsed.generatedTrdPath).toContain("TRD-2026-999-demo.md");
    expect(parsed.sprints).toHaveLength(1);
    expect(parsed.sprints[0].stories[0].tasks[0].trdId).toBe("FSC-T001");
  });

  it("halts when the PRD readiness score is below the execution threshold", async () => {
    writeFileSync(prdPath, "# Demo PRD\n\n**Readiness Score:** 3.2\n", "utf-8");

    const result = await runCommand(["prd", prdPath, "--project-path", tmpDir, "--auto"], tmpDir);

    expect(result.stderr).toContain("SLING-009");
    expect(mockRunWithPiSdk).not.toHaveBeenCalled();
  });
});
