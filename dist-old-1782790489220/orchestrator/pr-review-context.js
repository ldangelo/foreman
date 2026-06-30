import { execFile } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { resolveArtifactPath } from "../lib/report-paths.js";
import { promisify } from "node:util";
const execFileAsync = promisify(execFile);
function isCodeRabbitAuthor(login) {
    return /^coderabbit(ai)?(\[bot\])?$/i.test(login ?? "");
}
function getCheckName(check) {
    return check.name ?? check.context ?? "unknown check";
}
function normalizeCheckState(value) {
    return value?.toUpperCase();
}
function isTerminalCheckState(value) {
    const normalized = normalizeCheckState(value);
    if (!normalized)
        return false;
    return ["COMPLETED", "SUCCESS", "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "SKIPPED", "NEUTRAL"].includes(normalized);
}
function getCheckStatus(check) {
    const status = normalizeCheckState(check.status);
    if (status)
        return isTerminalCheckState(status) && status !== "COMPLETED" ? "COMPLETED" : status;
    const state = normalizeCheckState(check.state);
    if (!state)
        return undefined;
    return isTerminalCheckState(state) ? "COMPLETED" : "PENDING";
}
function getCheckConclusion(check) {
    const conclusion = normalizeCheckState(check.conclusion);
    if (conclusion)
        return conclusion;
    const state = normalizeCheckState(check.state ?? check.status);
    if (!state || !isTerminalCheckState(state) || state === "COMPLETED")
        return undefined;
    return state;
}
function isCodeRabbitCheck(check) {
    return /coderabbit/i.test(getCheckName(check));
}
export function summarizePrWaitStatus(snapshot) {
    const codeRabbitReviews = snapshot.codeRabbitReviews ?? 0;
    const codeRabbitSeen = snapshot.codeRabbitComments > 0 || codeRabbitReviews > 0;
    const codeRabbitComplete = codeRabbitReviews > 0 || snapshot.checks
        .filter(isCodeRabbitCheck)
        .some((check) => getCheckStatus(check) === "COMPLETED");
    const pendingChecks = snapshot.checks
        .filter((check) => getCheckStatus(check) !== "COMPLETED")
        // GitHub may leave CodeRabbit's rollup status unset after the review is
        // submitted. Only ignore that unset rollup once review completion is proven.
        .filter((check) => !(codeRabbitComplete && isCodeRabbitCheck(check)))
        .map((check) => getCheckName(check));
    const mergeable = snapshot.mergeable?.toUpperCase();
    const mergeStateStatus = snapshot.mergeStateStatus?.toUpperCase();
    const mergeConflict = mergeable === "CONFLICTING" || mergeStateStatus === "DIRTY";
    const mergeConflictReason = mergeConflict
        ? `mergeable=${snapshot.mergeable ?? "unknown"} mergeStateStatus=${snapshot.mergeStateStatus ?? "unknown"}`
        : undefined;
    return {
        checksTerminal: pendingChecks.length === 0,
        pendingChecks,
        failedChecks: parseFailedChecks(snapshot.checks),
        codeRabbitSeen,
        codeRabbitComplete,
        mergeConflict,
        mergeConflictReason,
    };
}
export function isPrWaitStatusReady(status) {
    return status.checksTerminal && status.codeRabbitComplete && !status.mergeConflict;
}
export function updatePrReadyStability(status, readySince, now, stabilityMs) {
    const ready = isPrWaitStatusReady(status);
    if (!ready)
        return { ready, readySince: undefined, stable: false };
    const nextReadySince = readySince ?? now;
    return {
        ready,
        readySince: nextReadySince,
        stable: now - nextReadySince >= stabilityMs,
    };
}
export function parseBlockingSeverity(text) {
    const signalLine = text
        .split("\n")
        .find((line) => {
        const trimmed = line.trim();
        return trimmed.length > 0 && !trimmed.startsWith("<!--");
    }) ?? "";
    const normalized = signalLine.toLowerCase();
    if (/\bcritical\b|🟣/.test(normalized))
        return "critical";
    if (/\bhigh\b|🔴/.test(normalized))
        return "high";
    // CodeRabbit's current inline format uses "🟠 Major" rather than
    // "medium"/"high". Treat Major as blocking so pr-review sees it.
    if (/\bmajor\b|🟠|\bmedium\b/.test(normalized))
        return "medium";
    return undefined;
}
function isAddressedCodeRabbitComment(body) {
    return /(?:✅\s*)?addressed\s+in\s+commit\b/i.test(body);
}
export function parseCodeRabbitFindings(comments, source) {
    const findings = [];
    for (const comment of comments) {
        if (!isCodeRabbitAuthor(comment.user?.login))
            continue;
        const body = comment.body ?? "";
        if (isAddressedCodeRabbitComment(body))
            continue;
        const severity = parseBlockingSeverity(body);
        if (!severity)
            continue;
        findings.push({
            severity,
            source,
            author: comment.user?.login ?? "coderabbit",
            path: comment.path,
            line: comment.line,
            body,
            url: comment.html_url,
        });
    }
    return findings;
}
export function parseFailedChecks(statusCheckRollup) {
    return statusCheckRollup
        .filter((check) => {
        const conclusion = getCheckConclusion(check);
        return conclusion === "FAILURE" || conclusion === "ERROR" || conclusion === "TIMED_OUT" || conclusion === "CANCELLED";
    })
        .map((check) => ({
        name: getCheckName(check),
        status: getCheckStatus(check),
        conclusion: getCheckConclusion(check),
        url: check.detailsUrl ?? check.details_url,
    }));
}
async function ghJson(projectPath, args) {
    const { stdout } = await execFileAsync("gh", args, {
        cwd: projectPath,
        maxBuffer: 10 * 1024 * 1024,
    });
    return JSON.parse(stdout);
}
async function collectPrComments(projectPath, prNumber) {
    const reviewComments = await ghJson(projectPath, ["api", "--paginate", `repos/:owner/:repo/pulls/${prNumber}/comments`]);
    const issueComments = await ghJson(projectPath, ["api", "--paginate", `repos/:owner/:repo/issues/${prNumber}/comments`]);
    return { reviewComments, issueComments };
}
export async function collectPrReviewContext(projectPath, prNumber) {
    const pr = await ghJson(projectPath, ["pr", "view", String(prNumber), "--json", "url,headRefOid,statusCheckRollup"]);
    const { reviewComments, issueComments } = await collectPrComments(projectPath, prNumber);
    return {
        prNumber,
        prUrl: pr.url,
        headSha: pr.headRefOid,
        blockingFindings: [
            ...parseCodeRabbitFindings(reviewComments, "review-comment"),
            ...parseCodeRabbitFindings(issueComments, "issue-comment"),
        ],
        failedChecks: parseFailedChecks(pr.statusCheckRollup ?? []),
    };
}
export async function collectPrWaitSnapshot(projectPath, prNumber) {
    const pr = await ghJson(projectPath, ["pr", "view", String(prNumber), "--json", "url,headRefOid,statusCheckRollup,mergeable,mergeStateStatus"]);
    const { reviewComments, issueComments } = await collectPrComments(projectPath, prNumber);
    const reviews = await ghJson(projectPath, ["api", "--paginate", `repos/:owner/:repo/pulls/${prNumber}/reviews`]);
    const codeRabbitComments = [...reviewComments, ...issueComments]
        .filter((comment) => isCodeRabbitAuthor(comment.user?.login)).length;
    const codeRabbitReviews = reviews
        .filter((review) => isCodeRabbitAuthor(review.user?.login ?? review.author?.login)).length;
    return {
        prNumber,
        prUrl: pr.url,
        headSha: pr.headRefOid,
        mergeable: pr.mergeable,
        mergeStateStatus: pr.mergeStateStatus,
        checks: pr.statusCheckRollup ?? [],
        codeRabbitComments,
        codeRabbitReviews,
    };
}
export async function writePrReviewFindings(worktreePath, context, reportDir) {
    const path = resolveArtifactPath(worktreePath, reportDir ? join(reportDir, "PR_REVIEW_FINDINGS.md") : "PR_REVIEW_FINDINGS.md");
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, renderPrReviewFindings(context), "utf8");
}
export async function writePrWaitReport(worktreePath, snapshot, timedOut, reportDir) {
    const path = resolveArtifactPath(worktreePath, reportDir ? join(reportDir, "PR_WAIT_REPORT.md") : "PR_WAIT_REPORT.md");
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, renderPrWaitReport(snapshot, timedOut), "utf8");
}
export function renderPrWaitReport(snapshot, timedOut) {
    const status = summarizePrWaitStatus(snapshot);
    const lines = [
        `# PR Wait Report`,
        ``,
        `## PR`,
        `- Number: ${snapshot.prNumber}`,
        `- URL: ${snapshot.prUrl ?? "unknown"}`,
        `- Head SHA: ${snapshot.headSha ?? "unknown"}`,
        `- Mergeable: ${snapshot.mergeable ?? "unknown"}`,
        `- Merge State: ${snapshot.mergeStateStatus ?? "unknown"}`,
        ``,
        `## Checks`,
        `- Status: ${status.checksTerminal ? "COMPLETE" : timedOut ? "TIMEOUT" : "PENDING"}`,
        `- Failed: ${status.failedChecks.length}`,
        `- Pending: ${status.pendingChecks.length}`,
        ``,
        `## CodeRabbit`,
        `- Status: ${status.codeRabbitComplete ? "COMPLETE" : status.codeRabbitSeen ? "SEEN" : timedOut ? "TIMEOUT" : "PENDING"}`,
        `- Comments: ${snapshot.codeRabbitComments}`,
        `- Reviews: ${snapshot.codeRabbitReviews ?? 0}`,
        ``,
        `## Mergeability`,
        `- Status: ${status.mergeConflict ? "CONFLICT" : "OK"}`,
        `- Reason: ${status.mergeConflictReason ?? "none"}`,
        ``,
        `## Verdict: ${status.checksTerminal && status.codeRabbitComplete && !status.mergeConflict ? "PASS" : "FAIL"}`,
    ];
    return lines.join("\n") + "\n";
}
export function renderPrReviewFindings(context) {
    const lines = [
        `# PR Review Findings`,
        ``,
        `- PR: #${context.prNumber}${context.prUrl ? ` (${context.prUrl})` : ""}`,
        `- Head SHA: ${context.headSha ?? "unknown"}`,
        ``,
        `## Blocking CodeRabbit Findings`,
    ];
    if (context.blockingFindings.length === 0) {
        lines.push("None.");
    }
    else {
        context.blockingFindings.forEach((finding, index) => {
            lines.push(``, `### ${index + 1}. ${finding.severity.toUpperCase()}${finding.path ? ` — ${finding.path}${finding.line ? `:${finding.line}` : ""}` : ""}`);
            if (finding.url)
                lines.push(`- URL: ${finding.url}`);
            lines.push(``, finding.body);
        });
    }
    lines.push(``, `## Failed Checks`);
    if (context.failedChecks.length === 0) {
        lines.push("None.");
    }
    else {
        context.failedChecks.forEach((check, index) => {
            lines.push(`${index + 1}. ${check.name} — ${check.conclusion ?? check.status ?? "failed"}${check.url ? ` (${check.url})` : ""}`);
        });
    }
    return lines.filter((line) => line !== undefined).join("\n") + "\n";
}
//# sourceMappingURL=pr-review-context.js.map