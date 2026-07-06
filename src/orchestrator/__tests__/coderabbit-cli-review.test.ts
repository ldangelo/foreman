import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const { mockExecFile } = vi.hoisted(() => ({
  mockExecFile: vi.fn(),
}));

vi.mock("node:child_process", () => ({
  execFile: mockExecFile,
}));

import { runCodeRabbitCliReview } from "../coderabbit-cli-review.js";

function setExecFileHandler(handler: (file: string, args: string[]) => { stdout?: string; stderr?: string; error?: Error & { code?: string; stdout?: string; stderr?: string } }): void {
  mockExecFile.mockImplementation((file: string, args: string[], options: unknown, callback: unknown) => {
    const cb = typeof options === "function" ? options : callback;
    const result = handler(file, args);
    if (typeof cb !== "function") throw new Error("missing execFile callback");
    if (result.error) {
      result.error.stdout = result.stdout ?? "";
      result.error.stderr = result.stderr ?? "";
      cb(result.error, result.stdout ?? "", result.stderr ?? "");
      return;
    }
    cb(null, result.stdout ?? "", result.stderr ?? "");
  });
}

describe("runCodeRabbitCliReview", () => {
  let worktreePath: string;

  beforeEach(() => {
    vi.clearAllMocks();
    worktreePath = mkdtempSync(join(tmpdir(), "foreman-coderabbit-cli-review-"));
  });

  afterEach(() => {
    rmSync(worktreePath, { recursive: true, force: true });
  });

  it("passes when review completes without blocking findings", async () => {
    setExecFileHandler((_file, args) => {
      if (args[0] === "--version") return { stdout: "1.2.3\n" };
      return {
        stdout: [
          JSON.stringify({ type: "status", status: "review_running" }),
          JSON.stringify({ type: "finding", severity: "minor", fileName: "src/foo.ts", comment: "nit" }),
          JSON.stringify({ type: "complete", status: "review_complete" }),
          "",
        ].join("\n"),
      };
    });

    const result = await runCodeRabbitCliReview({
      worktreePath,
      baseBranch: "main",
      reportDir: "reports/task-1",
      log: vi.fn(),
    });

    expect(result.status).toBe("passed");
    expect(result.blockingFindings).toHaveLength(0);
    expect(result.nonBlockingFindings).toHaveLength(1);
    expect(readFileSync(result.reportPath, "utf8")).toContain("## Verdict: PASS");
    expect(readFileSync(result.findingsPath, "utf8")).toContain('"status": "passed"');
  });

  it("fails when CodeRabbit reports a blocking finding", async () => {
    setExecFileHandler((_file, args) => {
      if (args[0] === "--version") return { stdout: "1.2.3\n" };
      return {
        stdout: [
          JSON.stringify({ type: "finding", severity: "major", fileName: "src/bar.ts", codegenInstructions: "Add null check" }),
          JSON.stringify({ type: "complete", status: "review_complete" }),
          "",
        ].join("\n"),
      };
    });

    const result = await runCodeRabbitCliReview({
      worktreePath,
      baseBranch: "main",
      reportDir: "reports/task-2",
      log: vi.fn(),
    });

    expect(result.status).toBe("failed");
    expect(result.blockingFindings).toHaveLength(1);
    expect(result.details).toContain("Blocking findings: 1");
    expect(readFileSync(result.reportPath, "utf8")).toContain("src/bar.ts [major]");
  });

  it("ignores generated/runtime artifact findings", async () => {
    setExecFileHandler((_file, args) => {
      if (args[0] === "--version") return { stdout: "1.2.3\n" };
      return {
        stdout: [
          JSON.stringify({ type: "finding", severity: "major", fileName: "dist-old-123/orchestrator/pi-sdk-runner.js", codegenInstructions: "stale generated copy" }),
          JSON.stringify({ type: "complete", status: "review_complete" }),
          "",
        ].join("\n"),
      };
    });

    const result = await runCodeRabbitCliReview({
      worktreePath,
      baseBranch: "main",
      reportDir: "reports/task-ignored",
      log: vi.fn(),
    });

    expect(result.status).toBe("passed");
    expect(result.blockingFindings).toHaveLength(0);
    expect(result.ignoredFindings).toHaveLength(1);
    expect(readFileSync(result.reportPath, "utf8")).toContain("## Ignored Findings");
  });

  it("retries CodeRabbit CLI rate limits before passing", async () => {
    let reviewAttempts = 0;
    const log = vi.fn();
    setExecFileHandler((_file, args) => {
      if (args[0] === "--version") return { stdout: "1.2.3\n" };
      reviewAttempts += 1;
      if (reviewAttempts === 1) {
        const error = new Error("Rate limit exceeded");
        return {
          error,
          stdout: JSON.stringify({ type: "error", message: "Rate limit exceeded" }) + "\n",
        };
      }
      return {
        stdout: [
          JSON.stringify({ type: "complete", status: "review_complete" }),
          "",
        ].join("\n"),
      };
    });

    const result = await runCodeRabbitCliReview({
      worktreePath,
      baseBranch: "main",
      reportDir: "reports/task-rate-limit",
      log,
      rateLimitRetries: 1,
      rateLimitRetryDelaysMs: [0],
    });

    expect(result.status).toBe("passed");
    expect(reviewAttempts).toBe(2);
    expect(log).toHaveBeenCalledWith(expect.stringContaining("CodeRabbit rate limited"));
  });

  it("skips cleanly when the binary is unavailable", async () => {
    setExecFileHandler((_file, args) => {
      if (args[0] === "--version") {
        const error = Object.assign(new Error("spawn coderabbit ENOENT"), { code: "ENOENT" as const });
        return { error };
      }
      throw new Error("review command should not run when version probe fails");
    });

    const result = await runCodeRabbitCliReview({
      worktreePath,
      baseBranch: "main",
      reportDir: "reports/task-3",
      log: vi.fn(),
    });

    expect(result.status).toBe("skipped");
    expect(result.details).toContain("not installed");
    expect(readFileSync(result.reportPath, "utf8")).toContain("## Verdict: SKIPPED");
  });
});
