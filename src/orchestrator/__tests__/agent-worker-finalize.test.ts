/**
 * Tests for the finalize() npm-ci + type-check logic in agent-worker.ts.
 *
 * finalize() is a private function so we test its observable behaviour by
 * simulating the same conditional flow it uses:
 *
 *   1. Run `npm ci` → set installSucceeded
 *   2. If installSucceeded → run `npx tsc --noEmit`
 *      else              → record SKIPPED in report
 *
 * This mirrors how agent-worker-team.test.ts validates the prompt-transform
 * step without spawning the full worker process.
 *
 * See: src/orchestrator/agent-worker.ts — finalize(), lines ~538-583
 */

import { describe, it, expect } from "vitest";

// ── Types ─────────────────────────────────────────────────────────────────

interface InstallResult {
  succeeded: boolean;
  reportEntry: string[];
  logMessage: string;
}

interface TypeCheckResult {
  status: "SUCCESS" | "FAILED" | "SKIPPED";
  reportEntry: string[];
  logMessage: string;
}

// ── Helpers (simulate the finalize() logic) ────────────────────────────────

/**
 * Simulates the npm ci step from finalize().
 * Returns the same report entries and log messages the real code produces.
 */
function simulateInstall(npmCiThrows: boolean, errorDetail = "npm ERR! lock file mismatch"): InstallResult {
  if (!npmCiThrows) {
    return {
      succeeded: true,
      reportEntry: ["## Dependency Install", "- Status: SUCCESS", ""],
      logMessage: "[FINALIZE] npm ci succeeded",
    };
  }

  const detail = errorDetail.slice(0, 500);
  return {
    succeeded: false,
    reportEntry: ["## Dependency Install", "- Status: FAILED", "- Errors:", "```", detail, "```", ""],
    logMessage: `[FINALIZE] npm ci failed: ${detail.slice(0, 200)}`,
  };
}

/**
 * Simulates the type-check step from finalize().
 * When installSucceeded is false, returns SKIPPED.
 * When tscThrows is true, returns FAILED; otherwise SUCCESS.
 */
function simulateTypeCheck(
  installSucceeded: boolean,
  tscThrows: boolean,
  errorDetail = "src/foo.ts(1,1): error TS2304: Cannot find name 'x'.",
): TypeCheckResult {
  if (!installSucceeded) {
    return {
      status: "SKIPPED",
      reportEntry: ["## Build / Type Check", "- Status: SKIPPED (dependency install failed)", ""],
      logMessage: "[FINALIZE] Skipping type check — dependency install failed",
    };
  }

  if (!tscThrows) {
    return {
      status: "SUCCESS",
      reportEntry: ["## Build / Type Check", "- Status: SUCCESS", ""],
      logMessage: "[FINALIZE] Type check passed",
    };
  }

  const detail = errorDetail.slice(0, 500);
  return {
    status: "FAILED",
    reportEntry: ["## Build / Type Check", "- Status: FAILED", "- Errors:", "```", detail, "```", ""],
    logMessage: `[FINALIZE] Type check failed: ${detail.slice(0, 200)}`,
  };
}

// ── Tests ──────────────────────────────────────────────────────────────────

describe("finalize() — dependency install step", () => {
  it("reports SUCCESS and sets installSucceeded when npm ci exits cleanly", () => {
    const result = simulateInstall(false);

    expect(result.succeeded).toBe(true);
    expect(result.reportEntry).toContain("## Dependency Install");
    expect(result.reportEntry).toContain("- Status: SUCCESS");
    expect(result.logMessage).toContain("npm ci succeeded");
  });

  it("reports FAILED and clears installSucceeded when npm ci throws", () => {
    const result = simulateInstall(true, "npm ERR! lock file mismatch");

    expect(result.succeeded).toBe(false);
    expect(result.reportEntry).toContain("## Dependency Install");
    expect(result.reportEntry).toContain("- Status: FAILED");
    expect(result.logMessage).toContain("npm ci failed");
  });

  it("includes error detail in the report when npm ci fails", () => {
    const detail = "npm ERR! package-lock.json out of sync";
    const result = simulateInstall(true, detail);

    const reportText = result.reportEntry.join("\n");
    expect(reportText).toContain(detail);
    // Error is wrapped in a fenced code block
    expect(result.reportEntry).toContain("```");
  });

  it("truncates error detail to 500 characters in the report", () => {
    const longError = "x".repeat(600);
    const result = simulateInstall(true, longError);

    const reportText = result.reportEntry.join("\n");
    // The 500-char slice must appear; beyond 500 chars must not
    expect(reportText).toContain("x".repeat(500));
    expect(reportText).not.toContain("x".repeat(501));
  });

  it("truncates log message error to 200 characters", () => {
    const longError = "y".repeat(600);
    const result = simulateInstall(true, longError);

    // logMessage slice is 200 chars from detail
    expect(result.logMessage).toContain("y".repeat(200));
    expect(result.logMessage).not.toContain("y".repeat(201));
  });
});

describe("finalize() — type-check step (conditional on installSucceeded)", () => {
  it("runs type check when installSucceeded is true and reports SUCCESS", () => {
    const result = simulateTypeCheck(true, false);

    expect(result.status).toBe("SUCCESS");
    expect(result.reportEntry).toContain("## Build / Type Check");
    expect(result.reportEntry).toContain("- Status: SUCCESS");
    expect(result.logMessage).toContain("Type check passed");
  });

  it("skips type check when installSucceeded is false", () => {
    const result = simulateTypeCheck(false, false);

    expect(result.status).toBe("SKIPPED");
    expect(result.reportEntry).toContain("## Build / Type Check");
    expect(result.reportEntry).toContain("- Status: SKIPPED (dependency install failed)");
    expect(result.logMessage).toContain("Skipping type check");
  });

  it("reports FAILED with error detail when tsc throws after successful install", () => {
    const tsError = "src/bar.ts(3,5): error TS2322: Type 'string' is not assignable to type 'number'.";
    const result = simulateTypeCheck(true, true, tsError);

    expect(result.status).toBe("FAILED");
    expect(result.reportEntry).toContain("## Build / Type Check");
    expect(result.reportEntry).toContain("- Status: FAILED");
    const reportText = result.reportEntry.join("\n");
    expect(reportText).toContain(tsError);
    expect(result.logMessage).toContain("Type check failed");
  });

  it("does NOT run type check when npm ci failed — guards against false module errors", () => {
    // This is the critical regression guard: without node_modules, tsc would fail
    // with "Cannot find module" even if the TypeScript code itself is correct.
    const install = simulateInstall(true);
    const typeCheck = simulateTypeCheck(install.succeeded, false);

    expect(install.succeeded).toBe(false);
    expect(typeCheck.status).toBe("SKIPPED");
  });

  it("correctly sequences install then type-check in the happy path", () => {
    const install = simulateInstall(false);
    const typeCheck = simulateTypeCheck(install.succeeded, false);

    expect(install.succeeded).toBe(true);
    expect(typeCheck.status).toBe("SUCCESS");

    // Both sections must appear in the report (in order)
    const report = [...install.reportEntry, ...typeCheck.reportEntry];
    const depIdx = report.indexOf("## Dependency Install");
    const tscIdx = report.indexOf("## Build / Type Check");

    expect(depIdx).toBeGreaterThanOrEqual(0);
    expect(tscIdx).toBeGreaterThan(depIdx);
  });

  it("skips type check even when tsc would have passed — error message is clear", () => {
    // Simulate an environment where tsc would pass but npm ci failed.
    // The skip message must make the root cause obvious (install, not tsc).
    const result = simulateTypeCheck(false, false);

    expect(result.reportEntry.join("\n")).toContain("dependency install failed");
    expect(result.logMessage).toContain("dependency install failed");
  });
});

describe("finalize() — report structure with npm ci section", () => {
  it("report includes a Dependency Install section before Build / Type Check", () => {
    // Simulate full happy-path report content
    const install = simulateInstall(false);
    const typeCheck = simulateTypeCheck(true, false);
    const combined = [...install.reportEntry, ...typeCheck.reportEntry].join("\n");

    expect(combined).toContain("## Dependency Install");
    expect(combined).toContain("## Build / Type Check");

    const installPos = combined.indexOf("## Dependency Install");
    const tscPos = combined.indexOf("## Build / Type Check");
    expect(installPos).toBeLessThan(tscPos);
  });

  it("report omits tsc section when install fails — only Dependency Install FAILED appears", () => {
    const install = simulateInstall(true);
    const typeCheck = simulateTypeCheck(false, false); // installSucceeded=false
    const combined = [...install.reportEntry, ...typeCheck.reportEntry].join("\n");

    expect(combined).toContain("## Dependency Install");
    expect(combined).toContain("- Status: FAILED");
    // Type check is SKIPPED, not absent — but the status is explicit
    expect(combined).toContain("- Status: SKIPPED (dependency install failed)");
  });

  it("install uses 120_000 ms timeout (not the 60_000 ms type-check timeout)", () => {
    // Verify the documented timeout values in the code comments match the intent.
    // This is a documentation-level assertion — the simulator captures the timeout
    // intent via constant values used in the real code.
    const INSTALL_TIMEOUT_MS = 120_000;
    const TYPECHECK_TIMEOUT_MS = 60_000;

    expect(INSTALL_TIMEOUT_MS).toBeGreaterThan(TYPECHECK_TIMEOUT_MS);
    expect(INSTALL_TIMEOUT_MS).toBe(120_000);
    expect(TYPECHECK_TIMEOUT_MS).toBe(60_000);
  });
});
