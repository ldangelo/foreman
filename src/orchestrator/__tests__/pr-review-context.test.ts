import { describe, expect, it } from "vitest";
import { isPrWaitStatusReady, parseCodeRabbitFindings, parseFailedChecks, renderPrReviewFindings, renderPrWaitReport, summarizePrWaitStatus, updatePrReadyStability } from "../pr-review-context.js";

describe("pr-review-context", () => {
  it("extracts only CodeRabbit critical/high/medium/major findings", () => {
    const findings = parseCodeRabbitFindings([
      { user: { login: "coderabbitai[bot]" }, body: "**High**: fix this", path: "src/a.ts", line: 12, html_url: "https://example/1" },
      { user: { login: "coderabbitai[bot]" }, body: "Low: optional nit", path: "src/b.ts" },
      { user: { login: "someone" }, body: "Critical: not from CodeRabbit" },
      { user: { login: "coderabbitai" }, body: "Medium severity issue" },
      { user: { login: "coderabbitai[bot]" }, body: "_⚠️ Potential issue_ | _🟠 Major_ | _⚡ Quick win_" },
      { user: { login: "coderabbitai[bot]" }, body: "_⚠️ Potential issue_ | _🟡 Minor_ | _⚡ Quick win_" },
      { user: { login: "coderabbitai[bot]" }, body: "[![Review Change Stack](image)](url)\n\nHigh confidence summary text" },
      { user: { login: "coderabbitai[bot]" }, body: "_⚠️ Potential issue_ | _🟠 Major_\n\n✅ Addressed in commit abc123" },
    ], "review-comment");

    expect(findings).toHaveLength(3);
    expect(findings.map((finding) => finding.severity)).toEqual(["high", "medium", "major"]);
    expect(findings[0]).toMatchObject({ path: "src/a.ts", line: 12, source: "review-comment" });
  });

  it("ignores CodeRabbit findings that were addressed in later commits", () => {
    const majorBody = "_⚠️ Potential issue_ | _🟠 Major_ | _⚡ Quick win_\n\nUse the stable project path when collecting PR status.";
    const criticalBody = "Critical: merge gate reads stale review comments after the final CodeRabbit approval.";

    const findings = parseCodeRabbitFindings([
      { user: { login: "coderabbitai[bot]" }, body: `${majorBody}\n\n✅ Addressed in commits 7b2f3a1, 8c4d5e6`, path: "src/addressed-major.ts", line: 14 },
      { user: { login: "coderabbitai[bot]" }, body: `${criticalBody}\n\n✅ Addressed in commits 7b2f3a1`, path: "src/addressed-critical.ts", line: 19 },
      { user: { login: "coderabbitai[bot]" }, body: majorBody, path: "src/unaddressed-major.ts", line: 24, html_url: "https://example/major" },
      { user: { login: "coderabbitai[bot]" }, body: criticalBody, path: "src/unaddressed-critical.ts", line: 29, html_url: "https://example/critical" },
    ], "review-comment");

    expect(findings).toEqual([
      expect.objectContaining({ severity: "major", path: "src/unaddressed-major.ts", line: 24, url: "https://example/major" }),
      expect.objectContaining({ severity: "critical", path: "src/unaddressed-critical.ts", line: 29, url: "https://example/critical" }),
    ]);
  });

  it("extracts failed checks from status rollup", () => {
    const failed = parseFailedChecks([
      { name: "unit", status: "COMPLETED", conclusion: "SUCCESS" },
      { name: "integration", status: "COMPLETED", conclusion: "FAILURE", detailsUrl: "https://checks/1" },
      { name: "lint", status: "COMPLETED", conclusion: "TIMED_OUT" },
      { context: "legacy status", state: "FAILURE" },
    ]);

    expect(failed).toEqual([
      { name: "integration", status: "COMPLETED", conclusion: "FAILURE", url: "https://checks/1" },
      { name: "lint", status: "COMPLETED", conclusion: "TIMED_OUT", url: undefined },
      { name: "legacy status", status: "COMPLETED", conclusion: "FAILURE", url: undefined },
    ]);
  });

  it("summarizes PR wait state", () => {
    const status = summarizePrWaitStatus({
      prNumber: 192,
      checks: [
        { name: "unit", status: "COMPLETED", conclusion: "SUCCESS" },
        { name: "lint", status: "QUEUED", conclusion: undefined },
        { name: "integration", status: "COMPLETED", conclusion: "FAILURE" },
        { context: "deploy", state: "PENDING" },
      ],
      codeRabbitComments: 1,
    });

    expect(status.checksTerminal).toBe(false);
    expect(status.pendingChecks).toEqual(["lint", "deploy"]);
    expect(status.failedChecks.map((check) => check.name)).toEqual(["integration"]);
    expect(status.codeRabbitSeen).toBe(true);
    expect(status.codeRabbitComplete).toBe(false);
    expect(status.mergeConflict).toBe(false);
  });

  it("waits for CodeRabbit completion after early CodeRabbit comments", () => {
    const status = summarizePrWaitStatus({
      prNumber: 193,
      checks: [
        { name: "Test (Node 20)", status: "COMPLETED", conclusion: "FAILURE" },
        { name: "CodeRabbit", status: undefined, conclusion: undefined },
      ],
      codeRabbitComments: 2,
    });

    expect(status.checksTerminal).toBe(false);
    expect(status.pendingChecks).toEqual(["CodeRabbit"]);
    expect(status.failedChecks.map((check) => check.name)).toEqual(["Test (Node 20)"]);
    expect(status.codeRabbitSeen).toBe(true);
    expect(status.codeRabbitComplete).toBe(false);
  });

  it("treats a submitted CodeRabbit review as complete", () => {
    const status = summarizePrWaitStatus({
      prNumber: 193,
      checks: [
        { name: "Test (Node 20)", status: "COMPLETED", conclusion: "SUCCESS" },
        { name: "CodeRabbit", status: undefined, conclusion: undefined },
      ],
      codeRabbitComments: 2,
      codeRabbitReviews: 1,
    });

    expect(status.checksTerminal).toBe(true);
    expect(status.pendingChecks).toEqual([]);
    expect(status.codeRabbitSeen).toBe(true);
    expect(status.codeRabbitComplete).toBe(true);
  });

  it("treats a successful CodeRabbit status context as terminal", () => {
    const status = summarizePrWaitStatus({
      prNumber: 193,
      checks: [
        { name: "Test (Node 20)", status: "SUCCESS", conclusion: undefined },
        { name: "CodeRabbit", status: "SUCCESS", conclusion: undefined },
      ],
      codeRabbitComments: 1,
    });

    expect(status.checksTerminal).toBe(true);
    expect(status.pendingChecks).toEqual([]);
    expect(status.codeRabbitSeen).toBe(true);
    expect(status.codeRabbitComplete).toBe(true);
  });

  it("flags conflicting PRs as blocked during PR wait", () => {
    const status = summarizePrWaitStatus({
      prNumber: 196,
      mergeable: "CONFLICTING",
      mergeStateStatus: "DIRTY",
      checks: [{ name: "unit", status: "COMPLETED", conclusion: "SUCCESS" }],
      codeRabbitComments: 1,
    });

    expect(status.checksTerminal).toBe(true);
    expect(status.codeRabbitSeen).toBe(true);
    expect(status.codeRabbitComplete).toBe(false);
    expect(status.mergeConflict).toBe(true);
    expect(status.mergeConflictReason).toBe("mergeable=CONFLICTING mergeStateStatus=DIRTY");
  });

  it("requires a continuous ready window before PR wait is stable", () => {
    const pending = summarizePrWaitStatus({
      prNumber: 197,
      checks: [{ name: "Test (Node 20)", status: "QUEUED" }],
      codeRabbitComments: 1,
      codeRabbitReviews: 1,
    });
    const failed = summarizePrWaitStatus({
      prNumber: 197,
      checks: [{ name: "Test (Node 20)", status: "COMPLETED", conclusion: "FAILURE" }],
      codeRabbitComments: 1,
      codeRabbitReviews: 1,
    });
    const ready = summarizePrWaitStatus({
      prNumber: 197,
      checks: [{ name: "Test (Node 20)", status: "COMPLETED", conclusion: "SUCCESS" }],
      codeRabbitComments: 1,
      codeRabbitReviews: 1,
    });

    const firstReady = updatePrReadyStability(ready, undefined, 1_000, 60_000);
    expect(isPrWaitStatusReady(failed)).toBe(false);
    expect(firstReady).toEqual({ ready: true, readySince: 1_000, stable: false });
    expect(updatePrReadyStability(ready, firstReady.readySince, 61_000, 60_000)).toEqual({ ready: true, readySince: 1_000, stable: true });
    expect(updatePrReadyStability(pending, firstReady.readySince, 62_000, 60_000)).toEqual({ ready: false, readySince: undefined, stable: false });
    expect(updatePrReadyStability(failed, firstReady.readySince, 63_000, 60_000)).toEqual({ ready: false, readySince: undefined, stable: false });
  });

  it("renders PR wait report", () => {
    const rendered = renderPrWaitReport({
      prNumber: 192,
      prUrl: "https://github.com/ldangelo/foreman/pull/192",
      headSha: "abc123",
      mergeable: "MERGEABLE",
      mergeStateStatus: "CLEAN",
      checks: [{ name: "unit", status: "COMPLETED", conclusion: "SUCCESS" }],
      codeRabbitComments: 2,
      codeRabbitReviews: 1,
    }, false);

    expect(rendered).toContain("# PR Wait Report");
    expect(rendered).toContain("- Status: COMPLETE");
    expect(rendered).toContain("- Reviews: 1");
    expect(rendered).toContain("- Status: OK");
    expect(rendered).toContain("## Verdict: PASS");
  });

  it("renders blocking CodeRabbit finding details in the PR wait report", () => {
    const rendered = renderPrWaitReport({
      prNumber: 325,
      prUrl: "https://github.com/ldangelo/foreman/pull/325",
      checks: [{ name: "unit", status: "COMPLETED", conclusion: "SUCCESS" }],
      codeRabbitComments: 1,
      codeRabbitReviews: 1,
      blockingFindings: [{
        severity: "major",
        source: "review-comment",
        author: "coderabbitai[bot]",
        path: "packages/foreman_server/lib/foreman_server/overwatch.ex",
        line: 271,
        body: "Restore a durable source for run_phase_orders.",
        url: "https://example.invalid/review/1",
      }],
    }, false);

    expect(rendered).toContain("### 1. MAJOR — packages/foreman_server/lib/foreman_server/overwatch.ex:271");
    expect(rendered).toContain("- URL: https://example.invalid/review/1");
    expect(rendered).toContain("Restore a durable source for run_phase_orders.");
    expect(rendered).toContain("## Verdict: FAIL");
  });


  it("renders PR wait failed when terminal checks include failures", () => {
    const rendered = renderPrWaitReport({
      prNumber: 311,
      prUrl: "https://github.com/ldangelo/foreman/pull/311",
      headSha: "abc123",
      mergeable: "MERGEABLE",
      mergeStateStatus: "UNSTABLE",
      checks: [{ name: "Test (Node 20)", status: "COMPLETED", conclusion: "FAILURE" }],
      codeRabbitComments: 1,
      codeRabbitReviews: 1,
    }, false);

    expect(rendered).toContain("- Status: COMPLETE");
    expect(rendered).toContain("- Failed: 1");
    expect(rendered).toContain("## Verdict: FAIL");
  });

  it("renders findings for the pr-review prompt", () => {
    const rendered = renderPrReviewFindings({
      prNumber: 192,
      prUrl: "https://github.com/ldangelo/foreman/pull/192",
      headSha: "abc123",
      blockingFindings: [{ severity: "critical", source: "issue-comment", author: "coderabbitai[bot]", body: "Critical: bad", path: "src/a.ts" }],
      failedChecks: [{ name: "unit", conclusion: "FAILURE" }],
    });

    expect(rendered).toContain("CRITICAL — src/a.ts");
    expect(rendered).toContain("unit — FAILURE");
  });
});
