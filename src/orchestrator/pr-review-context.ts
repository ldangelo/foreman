import { execFile } from "node:child_process";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export type BlockingSeverity = "critical" | "high" | "medium";

export interface CodeRabbitFinding {
  severity: BlockingSeverity;
  source: "review-comment" | "issue-comment";
  author: string;
  path?: string;
  line?: number;
  body: string;
  url?: string;
}

export interface FailedCheckFinding {
  name: string;
  status?: string;
  conclusion?: string;
  url?: string;
}

export interface PrReviewContext {
  prNumber: number;
  prUrl?: string;
  headSha?: string;
  blockingFindings: CodeRabbitFinding[];
  failedChecks: FailedCheckFinding[];
}

export interface PrWaitSnapshot {
  prNumber: number;
  prUrl?: string;
  headSha?: string;
  mergeable?: string;
  mergeStateStatus?: string;
  checks: GhCheck[];
  codeRabbitComments: number;
}

export interface PrWaitStatus {
  checksTerminal: boolean;
  pendingChecks: string[];
  failedChecks: FailedCheckFinding[];
  codeRabbitSeen: boolean;
  mergeConflict: boolean;
  mergeConflictReason?: string;
}

export interface GhComment {
  user?: { login?: string };
  body?: string;
  path?: string;
  line?: number;
  html_url?: string;
}

export interface GhCheck {
  name?: string;
  context?: string;
  status?: string;
  state?: string;
  conclusion?: string;
  detailsUrl?: string;
  details_url?: string;
}

function isCodeRabbitAuthor(login: string | undefined): boolean {
  return /^coderabbit(ai)?(\[bot\])?$/i.test(login ?? "");
}

function getCheckName(check: GhCheck): string {
  return check.name ?? check.context ?? "unknown check";
}

function getCheckStatus(check: GhCheck): string | undefined {
  if (check.status) return check.status;
  const state = check.state?.toUpperCase();
  if (!state) return undefined;
  return state === "PENDING" || state === "EXPECTED" ? "PENDING" : "COMPLETED";
}

function getCheckConclusion(check: GhCheck): string | undefined {
  if (check.conclusion) return check.conclusion;
  const state = check.state?.toUpperCase();
  if (!state || state === "PENDING" || state === "EXPECTED") return undefined;
  return state;
}

function isCodeRabbitCheck(check: GhCheck): boolean {
  return /coderabbit/i.test(getCheckName(check));
}

export function summarizePrWaitStatus(snapshot: PrWaitSnapshot): PrWaitStatus {
  const codeRabbitSeen = snapshot.codeRabbitComments > 0;
  const pendingChecks = snapshot.checks
    .filter((check) => getCheckStatus(check) !== "COMPLETED")
    // GitHub may leave the CodeRabbit rollup check in a null/non-terminal state
    // even after CodeRabbit has posted its review. Once comments are visible,
    // let prepare-pr-review/pr-review consume the findings instead of timing out.
    .filter((check) => !(codeRabbitSeen && isCodeRabbitCheck(check)))
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
    mergeConflict,
    mergeConflictReason,
  };
}

export function parseBlockingSeverity(text: string): BlockingSeverity | undefined {
  const signalLine = text
    .split("\n")
    .find((line) => {
      const trimmed = line.trim();
      return trimmed.length > 0 && !trimmed.startsWith("<!--");
    }) ?? "";
  const normalized = signalLine.toLowerCase();
  if (/\bcritical\b|🟣/.test(normalized)) return "critical";
  if (/\bhigh\b|🔴/.test(normalized)) return "high";
  // CodeRabbit's current inline format uses "🟠 Major" rather than
  // "medium"/"high". Treat Major as blocking so pr-review sees it.
  if (/\bmajor\b|🟠|\bmedium\b/.test(normalized)) return "medium";
  return undefined;
}

export function parseCodeRabbitFindings(comments: GhComment[], source: CodeRabbitFinding["source"]): CodeRabbitFinding[] {
  const findings: CodeRabbitFinding[] = [];
  for (const comment of comments) {
    if (!isCodeRabbitAuthor(comment.user?.login)) continue;
    const body = comment.body ?? "";
    const severity = parseBlockingSeverity(body);
    if (!severity) continue;
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

export function parseFailedChecks(statusCheckRollup: GhCheck[]): FailedCheckFinding[] {
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

async function ghJson<T>(projectPath: string, args: string[]): Promise<T> {
  const { stdout } = await execFileAsync("gh", args, {
    cwd: projectPath,
    maxBuffer: 10 * 1024 * 1024,
  });
  return JSON.parse(stdout) as T;
}

async function collectPrComments(projectPath: string, prNumber: number): Promise<{ reviewComments: GhComment[]; issueComments: GhComment[] }> {
  const reviewComments = await ghJson<GhComment[]>(
    projectPath,
    ["api", "--paginate", `repos/:owner/:repo/pulls/${prNumber}/comments`],
  );
  const issueComments = await ghJson<GhComment[]>(
    projectPath,
    ["api", "--paginate", `repos/:owner/:repo/issues/${prNumber}/comments`],
  );
  return { reviewComments, issueComments };
}

export async function collectPrReviewContext(projectPath: string, prNumber: number): Promise<PrReviewContext> {
  const pr = await ghJson<{ url?: string; headRefOid?: string; statusCheckRollup?: GhCheck[] }>(
    projectPath,
    ["pr", "view", String(prNumber), "--json", "url,headRefOid,statusCheckRollup"],
  );
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

export async function collectPrWaitSnapshot(projectPath: string, prNumber: number): Promise<PrWaitSnapshot> {
  const pr = await ghJson<{ url?: string; headRefOid?: string; statusCheckRollup?: GhCheck[]; mergeable?: string; mergeStateStatus?: string }>(
    projectPath,
    ["pr", "view", String(prNumber), "--json", "url,headRefOid,statusCheckRollup,mergeable,mergeStateStatus"],
  );
  const { reviewComments, issueComments } = await collectPrComments(projectPath, prNumber);
  const codeRabbitComments = [...reviewComments, ...issueComments]
    .filter((comment) => isCodeRabbitAuthor(comment.user?.login)).length;
  return {
    prNumber,
    prUrl: pr.url,
    headSha: pr.headRefOid,
    mergeable: pr.mergeable,
    mergeStateStatus: pr.mergeStateStatus,
    checks: pr.statusCheckRollup ?? [],
    codeRabbitComments,
  };
}

export async function writePrReviewFindings(worktreePath: string, context: PrReviewContext): Promise<void> {
  await writeFile(join(worktreePath, "PR_REVIEW_FINDINGS.md"), renderPrReviewFindings(context), "utf8");
}

export async function writePrWaitReport(worktreePath: string, snapshot: PrWaitSnapshot, timedOut: boolean): Promise<void> {
  await writeFile(join(worktreePath, "PR_WAIT_REPORT.md"), renderPrWaitReport(snapshot, timedOut), "utf8");
}

export function renderPrWaitReport(snapshot: PrWaitSnapshot, timedOut: boolean): string {
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
    `- Status: ${status.codeRabbitSeen ? "SEEN" : timedOut ? "TIMEOUT" : "PENDING"}`,
    `- Comments: ${snapshot.codeRabbitComments}`,
    ``,
    `## Mergeability`,
    `- Status: ${status.mergeConflict ? "CONFLICT" : "OK"}`,
    `- Reason: ${status.mergeConflictReason ?? "none"}`,
    ``,
    `## Verdict: ${status.checksTerminal && status.codeRabbitSeen && !status.mergeConflict ? "PASS" : "FAIL"}`,
  ];
  return lines.join("\n") + "\n";
}

export function renderPrReviewFindings(context: PrReviewContext): string {
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
  } else {
    context.blockingFindings.forEach((finding, index) => {
      lines.push(
        ``,
        `### ${index + 1}. ${finding.severity.toUpperCase()}${finding.path ? ` — ${finding.path}${finding.line ? `:${finding.line}` : ""}` : ""}`,
      );
      if (finding.url) lines.push(`- URL: ${finding.url}`);
      lines.push(``, finding.body);
    });
  }

  lines.push(``, `## Failed Checks`);
  if (context.failedChecks.length === 0) {
    lines.push("None.");
  } else {
    context.failedChecks.forEach((check, index) => {
      lines.push(`${index + 1}. ${check.name} — ${check.conclusion ?? check.status ?? "failed"}${check.url ? ` (${check.url})` : ""}`);
    });
  }

  return lines.filter((line): line is string => line !== undefined).join("\n") + "\n";
}
