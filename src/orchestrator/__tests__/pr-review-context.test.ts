import { describe, expect, it } from "vitest";
import { parseCodeRabbitFindings, parseFailedChecks, renderPrReviewFindings, renderPrWaitReport, summarizePrWaitStatus } from "../pr-review-context.js";

describe("pr-review-context", () => {
  it("extracts only CodeRabbit critical/high/medium findings", () => {
    const findings = parseCodeRabbitFindings([
      { user: { login: "coderabbitai[bot]" }, body: "**High**: fix this", path: "src/a.ts", line: 12, html_url: "https://example/1" },
      { user: { login: "coderabbitai[bot]" }, body: "Low: optional nit", path: "src/b.ts" },
      { user: { login: "someone" }, body: "Critical: not from CodeRabbit" },
      { user: { login: "coderabbitai" }, body: "Medium severity issue" },
    ], "review-comment");

    expect(findings).toHaveLength(2);
    expect(findings.map((finding) => finding.severity)).toEqual(["high", "medium"]);
    expect(findings[0]).toMatchObject({ path: "src/a.ts", line: 12, source: "review-comment" });
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
  });

  it("does not block on CodeRabbit rollup once CodeRabbit comments are visible", () => {
    const status = summarizePrWaitStatus({
      prNumber: 193,
      checks: [
        { name: "Test (Node 20)", status: "COMPLETED", conclusion: "FAILURE" },
        { name: "CodeRabbit", status: undefined, conclusion: undefined },
      ],
      codeRabbitComments: 2,
    });

    expect(status.checksTerminal).toBe(true);
    expect(status.pendingChecks).toEqual([]);
    expect(status.failedChecks.map((check) => check.name)).toEqual(["Test (Node 20)"]);
    expect(status.codeRabbitSeen).toBe(true);
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
    }, false);

    expect(rendered).toContain("# PR Wait Report");
    expect(rendered).toContain("- Status: COMPLETE");
    expect(rendered).toContain("- Status: SEEN");
    expect(rendered).toContain("## Verdict: PASS");
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
