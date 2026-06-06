import { execFile } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { resolveArtifactPath } from "../lib/report-paths.js";
type ExecFileOptions = {
  cwd?: string;
  encoding?: BufferEncoding;
  maxBuffer?: number;
};

function execFileText(file: string, args: string[], options: ExecFileOptions): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    execFile(file, args, options, (error, stdout, stderr) => {
      const stdoutText = typeof stdout === "string" ? stdout : String(stdout ?? "");
      const stderrText = typeof stderr === "string" ? stderr : String(stderr ?? "");
      if (error) {
        const enriched = error as Error & { stdout?: string; stderr?: string };
        enriched.stdout = stdoutText;
        enriched.stderr = stderrText;
        reject(enriched);
        return;
      }
      resolve({ stdout: stdoutText, stderr: stderrText });
    });
  });
}

const MAX_BUFFER = 10 * 1024 * 1024;
const BLOCKING_SEVERITIES = new Set(["critical", "major"]);

export type CodeRabbitCliSeverity = "critical" | "major" | "minor" | "trivial" | "info";
export type CodeRabbitCliStatus = "passed" | "failed" | "skipped";

export interface CodeRabbitCliFinding {
  severity: CodeRabbitCliSeverity;
  fileName: string;
  comment?: string;
  codegenInstructions?: string;
  suggestions: string[];
}

export interface CodeRabbitCliResult {
  status: CodeRabbitCliStatus;
  baseBranch: string;
  command: string;
  blockingFindings: CodeRabbitCliFinding[];
  nonBlockingFindings: CodeRabbitCliFinding[];
  details: string;
  rawEventsPath: string;
  findingsPath: string;
  reportPath: string;
  stderr?: string;
  malformedLines: string[];
}

interface CodeRabbitCliEvent {
  type?: string;
  severity?: string;
  fileName?: string;
  comment?: string;
  codegenInstructions?: string;
  suggestions?: unknown;
  status?: string;
  message?: string;
  error?: string;
}

function normalizeSeverity(value: string | undefined): CodeRabbitCliSeverity {
  const normalized = value?.trim().toLowerCase();
  switch (normalized) {
    case "critical":
    case "major":
    case "minor":
    case "trivial":
      return normalized;
    default:
      return "info";
  }
}

function parseEvents(rawOutput: string): { events: CodeRabbitCliEvent[]; malformedLines: string[] } {
  const events: CodeRabbitCliEvent[] = [];
  const malformedLines: string[] = [];
  for (const line of rawOutput.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      events.push(JSON.parse(trimmed) as CodeRabbitCliEvent);
    } catch {
      malformedLines.push(trimmed);
    }
  }
  return { events, malformedLines };
}

function findLastEvent(events: CodeRabbitCliEvent[], type: string): CodeRabbitCliEvent | undefined {
  for (let idx = events.length - 1; idx >= 0; idx -= 1) {
    if (events[idx]?.type === type) return events[idx];
  }
  return undefined;
}


function classifyFindings(events: CodeRabbitCliEvent[]): { blocking: CodeRabbitCliFinding[]; nonBlocking: CodeRabbitCliFinding[] } {
  const blocking: CodeRabbitCliFinding[] = [];
  const nonBlocking: CodeRabbitCliFinding[] = [];


  for (const event of events) {
    if (event.type !== "finding") continue;
    const finding: CodeRabbitCliFinding = {
      severity: normalizeSeverity(event.severity),
      fileName: event.fileName || "unknown",
      comment: typeof event.comment === "string" ? event.comment : undefined,
      codegenInstructions: typeof event.codegenInstructions === "string" ? event.codegenInstructions : undefined,
      suggestions: Array.isArray(event.suggestions)
        ? event.suggestions.filter((item): item is string => typeof item === "string")
        : [],
    };
    if (BLOCKING_SEVERITIES.has(finding.severity)) {
      blocking.push(finding);
    } else {
      nonBlocking.push(finding);
    }
  }

  return { blocking, nonBlocking };
}

function summarizeDetails(args: {
  status: CodeRabbitCliStatus;
  blockingCount: number;
  nonBlockingCount: number;
  completionStatus?: string;
  eventError?: string;
  stderr?: string;
}): string {
  if (args.status === "skipped") {
    return args.eventError || args.stderr || args.completionStatus || "CodeRabbit CLI unavailable";
  }
  if (args.status === "failed") {
    if (args.blockingCount > 0) {
      return `Blocking findings: ${args.blockingCount}`;
    }
    return args.eventError || args.stderr || args.completionStatus || "CodeRabbit CLI review failed";
  }
  return args.completionStatus === "review_skipped"
    ? "No changes detected"
    : `No blocking findings (${args.nonBlockingCount} non-blocking)`;
}

function renderReport(args: {
  result: CodeRabbitCliResult;
  completionStatus?: string;
  eventError?: string;
}): string {
  const { result } = args;
  const verdict = result.status === "failed" ? "FAIL" : result.status === "skipped" ? "SKIPPED" : "PASS";
  const lines = [
    "# CodeRabbit CLI Report",
    "",
    `## Verdict: ${verdict}`,
    `- Base Branch: ${result.baseBranch}`,
    `- Command: \`${result.command}\``,
    `- Blocking Findings: ${result.blockingFindings.length}`,
    `- Non-blocking Findings: ${result.nonBlockingFindings.length}`,
    `- Completion Status: ${args.completionStatus ?? "unknown"}`,
    `- Details: ${result.details}`,
  ];

  if (args.eventError) {
    lines.push(`- Error Event: ${args.eventError}`);
  }
  if (result.stderr?.trim()) {
    lines.push(`- Stderr: ${result.stderr.trim()}`);
  }
  if (result.malformedLines.length > 0) {
    lines.push(`- Malformed Output Lines: ${result.malformedLines.length}`);
  }

  lines.push("", "## Blocking Findings");
  if (result.blockingFindings.length === 0) {
    lines.push("- None");
  } else {
    for (const finding of result.blockingFindings) {
      lines.push(`- ${finding.fileName} [${finding.severity}]`);
      if (finding.codegenInstructions) lines.push(`  - Fix: ${finding.codegenInstructions}`);
      if (finding.comment) lines.push(`  - Note: ${finding.comment}`);
      for (const suggestion of finding.suggestions) lines.push(`  - Suggestion: ${suggestion}`);
    }
  }

  lines.push("", "## Non-blocking Findings");
  if (result.nonBlockingFindings.length === 0) {
    lines.push("- None");
  } else {
    for (const finding of result.nonBlockingFindings) {
      lines.push(`- ${finding.fileName} [${finding.severity}]`);
      if (finding.comment) lines.push(`  - Note: ${finding.comment}`);
    }
  }

  return lines.join("\n") + "\n";
}

function isMissingBinary(error: unknown): boolean {
  return error instanceof Error && (error as { code?: string }).code === "ENOENT";
}

function isAuthenticationIssue(text: string): boolean {
  return /(not\s+logged\s+in|auth|login|api\s*key|unauthorized|forbidden)/i.test(text);
}

export async function runCodeRabbitCliReview(args: {
  worktreePath: string;
  baseBranch: string;
  reportDir: string;
  log: (msg: string) => void;
}): Promise<CodeRabbitCliResult> {
  const reviewArgs = ["review", "--agent", "--type", "uncommitted", "--base", args.baseBranch, "--dir", args.worktreePath];
  const command = `coderabbit ${reviewArgs.join(" ")}`;
  const rawEventsPath = resolveArtifactPath(args.worktreePath, join(args.reportDir, "CR_CLI_RAW.jsonl"));
  const findingsPath = resolveArtifactPath(args.worktreePath, join(args.reportDir, "CR_CLI_FINDINGS.json"));
  const reportPath = resolveArtifactPath(args.worktreePath, join(args.reportDir, "CR_CLI_REPORT.md"));
  await mkdir(dirname(rawEventsPath), { recursive: true });

  let rawOutput = "";
  let stderr = "";
  let eventError: string | undefined;
  let status: CodeRabbitCliStatus = "passed";

  try {
    await execFileText("coderabbit", ["--version"], { cwd: args.worktreePath, maxBuffer: MAX_BUFFER });
  } catch (error) {
    status = "skipped";
    eventError = isMissingBinary(error)
      ? "CodeRabbit CLI binary not installed"
      : error instanceof Error
        ? error.message
        : String(error);
  }

  if (!eventError) {
    try {
      const result = await execFileText("coderabbit", reviewArgs, {
        cwd: args.worktreePath,
        encoding: "utf8",
        maxBuffer: MAX_BUFFER,
      });
      rawOutput = result.stdout;
      stderr = result.stderr;
    } catch (error: unknown) {
      rawOutput = typeof (error as { stdout?: unknown }).stdout === "string" ? (error as { stdout: string }).stdout : "";
      stderr = typeof (error as { stderr?: unknown }).stderr === "string" ? (error as { stderr: string }).stderr : "";
      const text = [rawOutput, stderr, error instanceof Error ? error.message : String(error)].filter(Boolean).join("\n");
      eventError = error instanceof Error ? error.message : String(error);
      status = isAuthenticationIssue(text) ? "skipped" : "failed";
    }
  }

  const { events, malformedLines } = parseEvents(rawOutput);
  const { blocking, nonBlocking } = classifyFindings(events);
  const completionStatus = findLastEvent(events, "complete")?.status
    || findLastEvent(events, "status")?.status;
  const explicitError = events.find((event) => event.type === "error");
  if (explicitError) {
    eventError = explicitError.message || explicitError.error || eventError || "CodeRabbit CLI emitted an error event";
    status = status === "skipped" ? status : "failed";
  }

  if (status !== "skipped") {
    if (completionStatus === "review_skipped") {
      status = "passed";
    } else if (blocking.length > 0) {
      status = "failed";
    } else if (status !== "failed") {
      status = "passed";
    }
  }

  const details = summarizeDetails({
    status,
    blockingCount: blocking.length,
    nonBlockingCount: nonBlocking.length,
    completionStatus,
    eventError,
    stderr,
  });

  const result: CodeRabbitCliResult = {
    status,
    baseBranch: args.baseBranch,
    command,
    blockingFindings: blocking,
    nonBlockingFindings: nonBlocking,
    details,
    rawEventsPath,
    findingsPath,
    reportPath,
    stderr: stderr || undefined,
    malformedLines,
  };

  await writeFile(rawEventsPath, rawOutput, "utf8");
  await writeFile(findingsPath, JSON.stringify({
    status,
    baseBranch: args.baseBranch,
    command,
    blockingFindings: blocking,
    nonBlockingFindings: nonBlocking,
    completionStatus,
    eventError,
    malformedLines,
  }, null, 2) + "\n", "utf8");
  await writeFile(reportPath, renderReport({ result, completionStatus, eventError }), "utf8");

  args.log(`[CLI-REVIEW] ${status.toUpperCase()} — blocking=${blocking.length} nonBlocking=${nonBlocking.length} details=${details}`);
  return result;
}
