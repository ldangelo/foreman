/**
 * pi-sdk-tools.ts — Custom Pi SDK tool definitions for Foreman agents.
 *
 * Registers tools that agents can call natively (as structured tool calls)
 * instead of relying on prompt-based skills like `/send-mail`.
 */

import { Type, type Static } from "@mariozechner/pi-ai";
import type { ToolDefinition } from "@mariozechner/pi-coding-agent";
import { execFile } from "node:child_process";
import { mkdir, appendFile, writeFile } from "node:fs/promises";
import { isAbsolute, normalize, resolve } from "node:path";
import { promisify } from "node:util";
import type { AgentMailClient } from "../lib/agent-mail-client.js";
import { ElixirServerClient, type ElixirTask } from "../lib/elixir-server-client.js";
import type { ForemanStore } from "../lib/store.js";
import type { VcsBackend } from "../lib/vcs/interface.js";
import type { PrReviewContext, PrWaitSnapshot, PrWaitStatus } from "./pr-review-context.js";
import { collectPrReviewContext, collectPrWaitSnapshot, isPrWaitStatusReady, summarizePrWaitStatus } from "./pr-review-context.js";

// Narrow interface for run status queries (getRun + getRunProgress)
export type RunStatusReader = Pick<ForemanStore, "getRun" | "getRunProgress">;

export interface ForemanToolContext {
  phase: string;
  runId: string;
  taskId: string;
  taskTitle: string;
  taskType?: string;
  taskDescription?: string;
  worktreePath: string;
  reportDir: string;
  logFile?: string;
  /** Callback to report file changes. Adds files to progress.filesChanged. */
  onFileChanges?: (files: string[]) => void;
  /** Callback to reserve files for ownership. */
  onFileReserve?: (files: string[], owner: string, leaseSecs?: number) => void;
  /** Callback to release file reservations. */
  onFileRelease?: (files: string[], owner: string) => void;
}

const execFileAsync = promisify(execFile);

function nowIso(): string {
  return new Date().toISOString();
}

function truncate(text: string, max = 12_000): string {
  return text.length <= max ? text : `${text.slice(0, max)}\n… truncated ${text.length - max} bytes`;
}

function safeJson(value: unknown): string {
  return JSON.stringify(value, null, 2);
}

function safeArtifactPath(context: ForemanToolContext, fileName: string): string {
  const normalized = normalize(fileName);
  if (isAbsolute(normalized) || normalized.startsWith("..") || normalized.includes("/../")) {
    throw new Error("artifact fileName must be relative and stay inside the report directory");
  }
  return resolve(context.reportDir, normalized);
}

async function ensureReportDir(context: ForemanToolContext): Promise<void> {
  await mkdir(context.reportDir, { recursive: true });
}

async function appendToolLog(context: ForemanToolContext, message: string): Promise<void> {
  if (!context.logFile) return;
  await appendFile(context.logFile, `[foreman-tool:${context.phase}] ${message}\n`).catch(() => undefined);
}

function isDangerousCommand(command: string): boolean {
  const normalized = command.toLowerCase().replace(/\s+/g, " ");
  return /\b(kill|pkill|killall)\b/.test(normalized)
    || /\bxargs\s+kill\b/.test(normalized)
    || /\bfuser\b.*\s-k\b/.test(normalized)
    || /\blsof\s+[^;&|]*-ti:?4766\b/.test(normalized)
    || /\bforeman\s+server\s+(stop|restart)\b/.test(normalized);
}

// ── send-mail tool ──────────────────────────────────────────────────────

const SendMailParams = Type.Object({
  to: Type.String({ description: "Recipient name (e.g. 'foreman')" }),
  subject: Type.String({ description: "Mail subject (e.g. 'agent-error')" }),
  body: Type.String({ description: "Mail body — JSON string or plain text" }),
});

/**
 * Create a send-mail ToolDefinition that uses the given NullAgentMailClient.
 *
 * The agent calls this tool with { to, subject, body } and the mail is
 * sent directly via the configured mail client — no bash command, no skill
 * expansion, no prompt interpretation required.
 */
export function createSendMailTool(
  mailClient: AgentMailClient,
  _agentRole: string,
): ToolDefinition {
  return {
    name: "send_mail",
    label: "Send Mail",
    description: "Send an Agent Mail message to another agent or to foreman. Use this to report errors only. Do NOT send phase-started or phase-complete — the executor handles those automatically.",
    promptSnippet: "Send error reports to foreman",
    promptGuidelines: [
      "Send an 'agent-error' mail if you encounter a fatal error",
    ],
    parameters: SendMailParams,
    async execute(
      _toolCallId: string,
      params: Static<typeof SendMailParams>,
    ) {
      try {
        await mailClient.sendMessage(params.to, params.subject, params.body);
        return {
          content: [{ type: "text" as const, text: `Mail sent to ${params.to}: ${params.subject}` }],
          details: undefined,
        };
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text" as const, text: `Failed to send mail: ${msg}` }],
          details: undefined,
        };
      }
    },
  } as ToolDefinition;
}

// ── first-class Foreman workflow tools ──────────────────────────────────

const MailSendParams = Type.Object({
  to: Type.String({ description: "Recipient phase/agent, e.g. foreman, explorer, fix, developer, qa" }),
  subject: Type.String({ description: "Structured subject, e.g. agent-error, handoff, progress-update" }),
  body: Type.String({ description: "Message body as concise text or JSON string" }),
});

export function createMailSendTool(mailClient: AgentMailClient, context: ForemanToolContext): ToolDefinition {
  return {
    name: "mail_send",
    label: "Mail Send",
    description: "Send typed Foreman Agent Mail. Prefer this over slash commands for phase handoffs, errors, blockers, and progress notes.",
    promptSnippet: "Use mail_send for Foreman mail; do not use shell or slash commands for mail.",
    promptGuidelines: ["Use mail_send for handoffs/errors/progress; keep bodies concise and structured."],
    parameters: MailSendParams,
    async execute(_toolCallId: string, params: Static<typeof MailSendParams>) {
      const envelope = {
        runId: context.runId,
        taskId: context.taskId,
        phase: context.phase,
        sentAt: nowIso(),
        body: params.body,
      };
      await mailClient.sendMessage(params.to, params.subject, safeJson(envelope));
      await appendToolLog(context, `mail_send to=${params.to} subject=${params.subject}`);
      return { content: [{ type: "text" as const, text: `Mail sent to ${params.to}: ${params.subject}` }], details: envelope };
    },
  } as ToolDefinition;
}

const MailReadParams = Type.Object({
  agent: Type.Optional(Type.String({ description: "Inbox owner to read; defaults to this phase agent" })),
  subject: Type.Optional(Type.String({ description: "Optional exact subject filter" })),
  from: Type.Optional(Type.String({ description: "Optional sender filter" })),
  limit: Type.Optional(Type.Number({ description: "Maximum messages to read, default 10, max 25" })),
});

export function createMailReadTool(mailClient: AgentMailClient, agentName: string, context: ForemanToolContext): ToolDefinition {
  return {
    name: "mail_read",
    label: "Mail Read",
    description: "Read this phase's Foreman Agent Mail inbox with optional filters. Use before reading raw report files when consuming handoffs or retry feedback.",
    promptSnippet: "Use mail_read to consume Foreman handoffs and feedback.",
    promptGuidelines: ["Read relevant mail before broad rediscovery; prefer filtered reads."],
    parameters: MailReadParams,
    async execute(_toolCallId: string, params: Static<typeof MailReadParams>) {
      const inboxOwner = params.agent || mailClient.agentName || agentName;
      const limit = Math.min(Math.max(params.limit ?? 10, 1), 25);
      const messages = (await mailClient.fetchInbox(inboxOwner, { limit }))
        .filter((message) => !params.subject || message.subject === params.subject)
        .filter((message) => !params.from || message.from === params.from)
        .map((message) => ({
          id: message.id,
          from: message.from,
          to: message.to,
          subject: message.subject,
          receivedAt: message.receivedAt,
          acknowledged: message.acknowledged,
          body: truncate(message.body, 4_000),
        }));
      await appendToolLog(context, `mail_read agent=${inboxOwner} count=${messages.length}`);
      return { content: [{ type: "text" as const, text: safeJson(messages) }], details: messages };
    },
  } as ToolDefinition;
}

const PhaseHandoffParams = Type.Object({
  summary: Type.String({ description: "Concise handoff summary" }),
  rootCause: Type.Optional(Type.String({ description: "Root cause if known" })),
  changedFiles: Type.Optional(Type.Array(Type.String({ description: "Changed or likely changed file path" }))),
  risks: Type.Optional(Type.Array(Type.String({ description: "Risk, assumption, or open question" }))),
  verification: Type.Optional(Type.Array(Type.String({ description: "Suggested or completed verification" }))),
  blockers: Type.Optional(Type.Array(Type.String({ description: "Blocking issue requiring operator or later phase action" }))),
});

export function createPhaseHandoffTool(mailClient: AgentMailClient | null, context: ForemanToolContext): ToolDefinition {
  return {
    name: "phase_handoff",
    label: "Phase Handoff",
    description: "Write and send a structured phase handoff. Use at phase end instead of relying only on free-form markdown.",
    promptSnippet: "Call phase_handoff near phase end with summary, files, risks, and verification.",
    promptGuidelines: ["Use phase_handoff to pass durable structured context to later phases."],
    parameters: PhaseHandoffParams,
    async execute(_toolCallId: string, params: Static<typeof PhaseHandoffParams>) {
      await ensureReportDir(context);
      const handoff = { ...params, runId: context.runId, taskId: context.taskId, phase: context.phase, createdAt: nowIso() };
      const fileName = `${context.phase.toUpperCase()}_HANDOFF.json`;
      await writeFile(safeArtifactPath(context, fileName), safeJson(handoff));
      if (mailClient) await mailClient.sendMessage("foreman", "phase-handoff", safeJson(handoff));
      await appendToolLog(context, `phase_handoff file=${fileName}`);
      return { content: [{ type: "text" as const, text: `Phase handoff written: ${fileName}` }], details: handoff };
    },
  } as ToolDefinition;
}

const ArtifactWriteParams = Type.Object({
  fileName: Type.String({ description: "Relative artifact file name inside this task's report directory" }),
  content: Type.String({ description: "Artifact content" }),
  append: Type.Optional(Type.Boolean({ description: "Append instead of overwrite" })),
});

export function createArtifactWriteTool(context: ForemanToolContext): ToolDefinition {
  return {
    name: "artifact_write",
    label: "Artifact Write",
    description: "Write a Foreman phase artifact into the task report directory. Path is constrained to the report directory.",
    promptSnippet: "Use artifact_write for Foreman reports/artifacts instead of ad hoc paths.",
    promptGuidelines: ["Write required phase reports with artifact_write; fileName must be relative."],
    parameters: ArtifactWriteParams,
    async execute(_toolCallId: string, params: Static<typeof ArtifactWriteParams>) {
      await ensureReportDir(context);
      const artifactPath = safeArtifactPath(context, params.fileName);
      await mkdir(resolve(artifactPath, ".."), { recursive: true });
      if (params.append) await appendFile(artifactPath, params.content);
      else await writeFile(artifactPath, params.content);
      await appendToolLog(context, `artifact_write file=${params.fileName} append=${Boolean(params.append)}`);
      return { content: [{ type: "text" as const, text: `Artifact ${params.append ? "appended" : "written"}: ${params.fileName}` }], details: { fileName: params.fileName } };
    },
  } as ToolDefinition;
}

const ValidationResultParams = Type.Object({
  command: Type.String({ description: "Validation command or check name" }),
  passed: Type.Boolean({ description: "Whether validation passed" }),
  evidence: Type.String({ description: "Concise evidence/output summary" }),
  exitCode: Type.Optional(Type.Number({ description: "Process exit code if command-backed" })),
});

export function createValidationResultTool(context: ForemanToolContext): ToolDefinition {
  return {
    name: "validation_result",
    label: "Validation Result",
    description: "Record a structured validation result for QA/finalize consumption.",
    promptSnippet: "Use validation_result to record test/check evidence.",
    promptGuidelines: ["Record every important validation command with pass/fail and evidence."],
    parameters: ValidationResultParams,
    async execute(_toolCallId: string, params: Static<typeof ValidationResultParams>) {
      await ensureReportDir(context);
      const result = { ...params, runId: context.runId, taskId: context.taskId, phase: context.phase, recordedAt: nowIso() };
      await appendFile(safeArtifactPath(context, `${context.phase.toUpperCase()}_VALIDATION_RESULTS.jsonl`), `${JSON.stringify(result)}\n`);
      await appendToolLog(context, `validation_result passed=${params.passed} command=${params.command}`);
      return { content: [{ type: "text" as const, text: `Validation recorded: ${params.passed ? "passed" : "failed"} — ${params.command}` }], details: result };
    },
  } as ToolDefinition;
}

const TaskBlockParams = Type.Object({
  reason: Type.String({ description: "Why the task/phase is blocked" }),
  neededAction: Type.String({ description: "Specific operator or upstream action needed" }),
});

export function createTaskBlockTool(mailClient: AgentMailClient | null, context: ForemanToolContext): ToolDefinition {
  return {
    name: "task_block",
    label: "Task Block",
    description: "Declare a task blocker and notify Foreman. Use instead of silently spinning or retrying broad exploration.",
    promptSnippet: "Use task_block when progress requires operator/upstream action.",
    promptGuidelines: ["If blocked, call task_block and then write the required report."],
    parameters: TaskBlockParams,
    async execute(_toolCallId: string, params: Static<typeof TaskBlockParams>) {
      await ensureReportDir(context);
      const block = { ...params, runId: context.runId, taskId: context.taskId, phase: context.phase, blockedAt: nowIso() };
      await writeFile(safeArtifactPath(context, "BLOCKED.md"), `# Blocked: ${context.taskTitle}\n\n- Phase: ${context.phase}\n- Reason: ${params.reason}\n- Needed action: ${params.neededAction}\n`);
      if (mailClient) await mailClient.sendMessage("foreman", "task-blocked", safeJson(block));
      await appendToolLog(context, `task_block reason=${params.reason}`);
      return { content: [{ type: "text" as const, text: `Task block recorded: ${params.reason}` }], details: block };
    },
  } as ToolDefinition;
}

const ProgressUpdateParams = Type.Object({
  status: Type.String({ description: "Short current status" }),
  nextStep: Type.Optional(Type.String({ description: "Next intended step" })),
});

export function createProgressUpdateTool(mailClient: AgentMailClient | null, context: ForemanToolContext): ToolDefinition {
  return {
    name: "progress_update",
    label: "Progress Update",
    description: "Send a concise progress update to Foreman/watch surfaces.",
    promptSnippet: "Use progress_update for meaningful phase progress, not every small action.",
    promptGuidelines: ["Send progress updates at meaningful milestones or before long validation."],
    parameters: ProgressUpdateParams,
    async execute(_toolCallId: string, params: Static<typeof ProgressUpdateParams>) {
      const update = { ...params, runId: context.runId, taskId: context.taskId, phase: context.phase, updatedAt: nowIso() };
      if (mailClient) await mailClient.sendMessage("foreman", "progress-update", safeJson(update));
      await appendToolLog(context, `progress_update status=${params.status}`);
      return { content: [{ type: "text" as const, text: `Progress update recorded: ${params.status}` }], details: update };
    },
  } as ToolDefinition;
}

const SafeCommandRunParams = Type.Object({
  command: Type.String({ description: "Non-interactive validation command to run in the worktree" }),
  timeoutMs: Type.Optional(Type.Number({ description: "Timeout in milliseconds, default 120000, max 600000" })),
});


export function createSafeCommandRunTool(context: ForemanToolContext): ToolDefinition {
  return {
    name: "safe_command_run",
    label: "Safe Command Run",
    description: "Run a non-interactive validation command with Foreman safety guards. Destructive process-control commands are blocked.",
    promptSnippet: "Use safe_command_run for tests/builds before Bash when possible.",
    promptGuidelines: ["Prefer safe_command_run for validation. Never attempt to kill Foreman or unrelated processes."],
    parameters: SafeCommandRunParams,
    async execute(_toolCallId: string, params: Static<typeof SafeCommandRunParams>) {
      if (isDangerousCommand(params.command)) {
        const text = "Blocked destructive process-control command. Do not kill Foreman server or unrelated processes.";
        await appendToolLog(context, `safe_command_run blocked command=${params.command}`);
        return { content: [{ type: "text" as const, text }], details: { blocked: true } };
      }
      const timeout = Math.min(Math.max(params.timeoutMs ?? 120_000, 1_000), 600_000);
      try {
        const { stdout, stderr } = await execFileAsync("/bin/sh", ["-lc", params.command], {
          cwd: context.worktreePath,
          timeout,
          env: { ...process.env, FOREMAN_SERVER_HTTP_ENABLED: "false", FOREMAN_SERVER_HTTP_PORT: "0" },
          maxBuffer: 2 * 1024 * 1024,
        });
        const output = truncate([stdout, stderr].filter(Boolean).join("\n"));
        await appendToolLog(context, `safe_command_run ok command=${params.command}`);
        return { content: [{ type: "text" as const, text: output || "Command passed with no output" }], details: { exitCode: 0, command: params.command } };
      } catch (err: unknown) {
        const failure = err as { stdout?: string; stderr?: string; code?: number; signal?: string; message?: string };
        const output = truncate([failure.stdout, failure.stderr, failure.message].filter(Boolean).join("\n"));
        await appendToolLog(context, `safe_command_run failed command=${params.command}`);
        return { content: [{ type: "text" as const, text: output || "Command failed" }], details: { exitCode: failure.code ?? 1, signal: failure.signal, command: params.command } };
      }
    },
  } as ToolDefinition;
}

// ── get-run-status tool ─────────────────────────────────────────────────

const GetRunStatusParams = Type.Object({
  runId: Type.String({ description: "The run ID to look up" }),
});

/**
 * Create a get_run_status ToolDefinition that reads run state from the store.
 *
 * Used by the troubleshooter agent to understand why a run failed and what
 * phase it was in when it stopped making progress.
 */
export function createGetRunStatusTool(store: RunStatusReader): ToolDefinition {
  return {
    name: "get_run_status",
    label: "Get Run Status",
    description: "Read the current status and progress of a pipeline run. Returns phase, cost, turns, and the reason it failed (if applicable).",
    promptSnippet: "Read run status from the database",
    promptGuidelines: [
      "Call get_run_status at the start of a troubleshooter session to understand the run's current state",
    ],
    parameters: GetRunStatusParams,
    async execute(
      _toolCallId: string,
      params: Static<typeof GetRunStatusParams>,
    ) {
      try {
        const run = store.getRun(params.runId);
        if (!run) {
          return {
            content: [{ type: "text" as const, text: `Run ${params.runId} not found` }],
            details: undefined,
          };
        }
        const progress = store.getRunProgress(params.runId);
        const info = {
          runId: run.id,
          taskId: run.task_id,
          status: run.status,
          startedAt: run.started_at,
          completedAt: run.completed_at,
          worktreePath: run.worktree_path,
          currentPhase: progress?.currentPhase ?? null,
          lastActivity: progress?.lastActivity ?? null,
          costUsd: progress?.costUsd ?? 0,
          turns: progress?.turns ?? 0,
          toolCalls: progress?.toolCalls ?? 0,
        };
        return {
          content: [{ type: "text" as const, text: JSON.stringify(info, null, 2) }],
          details: undefined,
        };
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text" as const, text: `Failed to get run status: ${msg}` }],
          details: undefined,
        };
      }
    },
  } as ToolDefinition;
}

// ── VCS and PR review tools ──────────────────────────────────────────────

const DiffReadParams = Type.Object({
  fromRef: Type.String({ description: "Starting ref (branch name, commit hash, or tag)" }),
  toRef: Type.String({ description: "Ending ref (branch name, commit hash, or tag)" }),
});

/**
 * Create a diff_read ToolDefinition that wraps VcsBackend.diff().
 *
 * Returns a unified diff between two refs. Path safety is enforced by the
 * VcsBackend — it operates within the worktree context.
 */
export function createDiffReadTool(vcsBackend: VcsBackend, context: ForemanToolContext): ToolDefinition {
  return {
    name: "diff_read",
    label: "Diff Read",
    description: "Get a unified diff between two refs (branches, commits, or tags). Path safety is enforced by the VCS backend operating within the worktree.",
    promptSnippet: "Read VCS diff between two refs",
    promptGuidelines: [
      "Use diff_read to inspect changes before committing or reviewing",
      "Pass meaningful ref pairs like fromRef=main toRef=HEAD",
    ],
    parameters: DiffReadParams,
    async execute(_toolCallId: string, params: Static<typeof DiffReadParams>) {
      try {
        const diff = await vcsBackend.diff(context.worktreePath, params.fromRef, params.toRef);
        await appendToolLog(context, `diff_read from=${params.fromRef} to=${params.toRef}`);
        return {
          content: [{ type: "text" as const, text: diff || "(no changes)" }],
          details: { fromRef: params.fromRef, toRef: params.toRef, worktreePath: context.worktreePath },
        };
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        await appendToolLog(context, `diff_read failed from=${params.fromRef} to=${params.toRef}`);
        return {
          content: [{ type: "text" as const, text: `Failed to get diff: ${msg}` }],
          details: { fromRef: params.fromRef, toRef: params.toRef, error: msg },
        };
      }
    },
  } as ToolDefinition;
}

const GitStatusParams = Type.Object({});

/**
 * Create a git_status ToolDefinition that wraps VcsBackend.status().
 *
 * Returns the working tree status as a string (equivalent to git status --porcelain).
 * Path safety is enforced by the VcsBackend operating within the worktree.
 */
export function createGitStatusTool(vcsBackend: VcsBackend, context: ForemanToolContext): ToolDefinition {
  return {
    name: "git_status",
    label: "Git Status",
    description: "Get the working tree status as a string (equivalent to git status --porcelain). Path safety is enforced by the VCS backend operating within the worktree.",
    promptSnippet: "Read VCS working tree status",
    promptGuidelines: [
      "Use git_status to check for uncommitted changes before major operations",
    ],
    parameters: GitStatusParams,
    async execute(_toolCallId: string, _params: Static<typeof GitStatusParams>) {
      try {
        const status = await vcsBackend.status(context.worktreePath);
        await appendToolLog(context, "git_status");
        return {
          content: [{ type: "text" as const, text: status || "(clean)" }],
          details: { worktreePath: context.worktreePath },
        };
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        await appendToolLog(context, "git_status failed");
        return {
          content: [{ type: "text" as const, text: `Failed to get status: ${msg}` }],
          details: { error: msg },
        };
      }
    },
  } as ToolDefinition;
}

const PrReviewFindingParams = Type.Object({
  prNumber: Type.Number({ description: "Pull request number" }),
  projectPath: Type.Optional(Type.String({ description: "Project root directory (defaults to the current worktree path)" })),
});

/**
 * Create a pr_review_finding ToolDefinition that collects CodeRabbit findings
 * and failed checks for a PR.
 *
 * Returns structured PrReviewContext with blockingFindings and failedChecks.
 */
export function createPrReviewFindingTool(
  vcsBackend: VcsBackend,
  context: ForemanToolContext,
): ToolDefinition {
  return {
    name: "pr_review_finding",
    label: "PR Review Finding",
    description: "Collect CodeRabbit blocking findings and failed checks for a pull request. Returns structured PrReviewContext with severity, path, line, body, and URLs.",
    promptSnippet: "Collect PR review findings from CodeRabbit and CI checks",
    promptGuidelines: [
      "Use pr_review_finding to get structured review feedback before addressing comments",
      "Pass the PR number from the current PR being reviewed",
    ],
    parameters: PrReviewFindingParams,
    async execute(_toolCallId: string, params: Static<typeof PrReviewFindingParams>) {
      try {
        const projectPath = params.projectPath ?? context.worktreePath;
        const prContext = await collectPrReviewContext(projectPath, params.prNumber);
        await appendToolLog(context, `pr_review_finding pr=${params.prNumber}`);
        return {
          content: [{ type: "text" as const, text: safeJson(prContext) }],
          details: prContext,
        };
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        await appendToolLog(context, `pr_review_finding failed pr=${params.prNumber}`);
        return {
          content: [{ type: "text" as const, text: `Failed to collect PR review findings: ${msg}` }],
          details: { prNumber: params.prNumber, error: msg },
        };
      }
    },
  } as ToolDefinition;
}

const MergeGateStatusParams = Type.Object({
  prNumber: Type.Number({ description: "Pull request number" }),
  projectPath: Type.Optional(Type.String({ description: "Project root directory (defaults to the current worktree path)" })),
});

/**
 * Create a merge_gate_status ToolDefinition that summarizes PR merge readiness
 * including checks, CodeRabbit completion, and merge conflicts.
 *
 * Returns PrWaitStatus with checksTerminal, pendingChecks, failedChecks,
 * codeRabbitComplete, blockingFindings, mergeConflict, and a ready boolean.
 */
export function createMergeGateStatusTool(
  vcsBackend: VcsBackend,
  context: ForemanToolContext,
): ToolDefinition {
  return {
    name: "merge_gate_status",
    label: "Merge Gate Status",
    description: "Summarize PR merge readiness including checks, CodeRabbit completion, and merge conflicts. Returns PrWaitStatus with ready boolean.",
    promptSnippet: "Check if PR is ready to merge",
    promptGuidelines: [
      "Use merge_gate_status to verify PR readiness before merging or finalizing",
      "The ready flag is true only when all checks pass, CodeRabbit is complete, and there are no blocking findings",
    ],
    parameters: MergeGateStatusParams,
    async execute(_toolCallId: string, params: Static<typeof MergeGateStatusParams>) {
      try {
        const projectPath = params.projectPath ?? context.worktreePath;
        const snapshot = await collectPrWaitSnapshot(projectPath, params.prNumber);
        const status = summarizePrWaitStatus(snapshot);
        const ready = isPrWaitStatusReady(status);
        const result = { ...status, ready };
        await appendToolLog(context, `merge_gate_status pr=${params.prNumber} ready=${ready}`);
        return {
          content: [{ type: "text" as const, text: safeJson(result) }],
          details: result,
        };
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        await appendToolLog(context, `merge_gate_status failed pr=${params.prNumber}`);
        return {
          content: [{ type: "text" as const, text: `Failed to check merge gate status: ${msg}` }],
          details: { prNumber: params.prNumber, error: msg },
        };
      }
    },
  } as ToolDefinition;
}

// Re-export PrWaitStatus for consumers of this module
export type { PrWaitStatus };

// ── Task context tools ─────────────────────────────────────────────────────

const TaskGetParams = Type.Object({
  taskId: Type.String({ description: "The task ID to retrieve" }),
});

/**
 * Create a task_get ToolDefinition that reads full task context from the Elixir backend.
 *
 * Returns task metadata including title, description, status, annotations, and dependencies.
 * Enforces per-run/task scoping via context.runId and context.taskId for audit trail.
 */
export function createTaskGetTool(client: ElixirServerClient, context: ForemanToolContext): ToolDefinition {
  return {
    name: "task_get",
    label: "Task Get",
    description: "Read full task context including title, description, status, annotations, and dependencies from the task store.",
    promptSnippet: "Read full task context via ElixirServerClient.getTask()",
    promptGuidelines: [
      "Use task_get to understand the task's current state and context",
      "Returns task metadata including title, description, status, annotations, and dependencies",
    ],
    parameters: TaskGetParams,
    async execute(_toolCallId: string, params: Static<typeof TaskGetParams>) {
      try {
        const task = await client.getTask(params.taskId);
        if (!task) {
          await appendToolLog(context, `task_get not_found taskId=${params.taskId}`);
          return {
            content: [{ type: "text" as const, text: `Task ${params.taskId} not found` }],
            details: { taskId: params.taskId, found: false },
          };
        }
        const enriched = {
          ...task,
          _meta: {
            runId: context.runId,
            taskId: context.taskId,
            phase: context.phase,
            retrievedAt: nowIso(),
          },
        };
        await appendToolLog(context, `task_get ok taskId=${params.taskId}`);
        return {
          content: [{ type: "text" as const, text: safeJson(enriched) }],
          details: enriched,
        };
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        await appendToolLog(context, `task_get failed taskId=${params.taskId} error=${msg}`);
        return {
          content: [{ type: "text" as const, text: `Failed to get task: ${msg}` }],
          details: { taskId: params.taskId, error: msg },
        };
      }
    },
  } as ToolDefinition;
}

const TaskStatusParams = Type.Object({
  taskId: Type.String({ description: "The task ID to check" }),
});

/**
 * Create a task_status ToolDefinition that reads only the task status field.
 *
 * Lightweight query for polling task completion or status changes without
 * fetching the full task context.
 */
export function createTaskStatusTool(client: ElixirServerClient, context: ForemanToolContext): ToolDefinition {
  return {
    name: "task_status",
    label: "Task Status",
    description: "Read only the current status of a task (e.g., pending, in-progress, completed, blocked). Lightweight polling without full context.",
    promptSnippet: "Read task status via ElixirServerClient.getTask()",
    promptGuidelines: [
      "Use task_status for lightweight status polling without fetching full task context",
      "Returns only the status field; use task_get for full context",
    ],
    parameters: TaskStatusParams,
    async execute(_toolCallId: string, params: Static<typeof TaskStatusParams>) {
      try {
        const task = await client.getTask(params.taskId);
        if (!task) {
          await appendToolLog(context, `task_status not_found taskId=${params.taskId}`);
          return {
            content: [{ type: "text" as const, text: `Task ${params.taskId} not found` }],
            details: { taskId: params.taskId, found: false, status: null },
          };
        }
        const result = {
          taskId: params.taskId,
          status: task.status ?? null,
          updatedAt: task.updated_at ?? null,
        };
        await appendToolLog(context, `task_status ok taskId=${params.taskId} status=${result.status}`);
        return {
          content: [{ type: "text" as const, text: safeJson(result) }],
          details: result,
        };
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        await appendToolLog(context, `task_status failed taskId=${params.taskId} error=${msg}`);
        return {
          content: [{ type: "text" as const, text: `Failed to get task status: ${msg}` }],
          details: { taskId: params.taskId, error: msg },
        };
      }
    },
  } as ToolDefinition;
}

const TaskAnnotateParams = Type.Object({
  taskId: Type.String({ description: "The task ID to annotate" }),
  body: Type.String({ description: "Annotation content — note text or risk description" }),
});

/**
 * Create a task_note_add ToolDefinition that writes operator-visible notes to the task.
 *
 * Annotations are stored via the Elixir backend's task.annotate command and are
 * visible in the operator UI. Includes run_id scoping for audit trail.
 */
export function createTaskNoteAddTool(client: ElixirServerClient, context: ForemanToolContext): ToolDefinition {
  return {
    name: "task_note_add",
    label: "Task Note Add",
    description: "Add an operator-visible note to a task. Notes are stored in the task store and visible in the operator UI.",
    promptSnippet: "Write operator-visible notes via sendCommand('task.annotate', {...})",
    promptGuidelines: [
      "Use task_note_add to record findings, decisions, or context for operators",
      "Annotations are visible in the operator UI and audit trail",
    ],
    parameters: TaskAnnotateParams,
    async execute(_toolCallId: string, params: Static<typeof TaskAnnotateParams>) {
      try {
        const response = await client.sendCommand({
          command_id: `note-add-${params.taskId}-${Date.now()}`,
          command_type: "task.annotate",
          payload: {
            project_id: context.taskId.split("-")[0],
            task_id: params.taskId,
            author: "agent",
            kind: "note",
            body: params.body,
            run_id: context.runId,
          },
        });
        if (!response.ok) {
          await appendToolLog(context, `task_note_add failed taskId=${params.taskId} error=${response.error.message}`);
          return {
            content: [{ type: "text" as const, text: `Failed to add note: ${response.error.message}` }],
            details: { taskId: params.taskId, error: response.error.message },
          };
        }
        const result = {
          taskId: params.taskId,
          kind: "note",
          body: params.body,
          runId: context.runId,
          addedAt: nowIso(),
        };
        await appendToolLog(context, `task_note_add ok taskId=${params.taskId}`);
        return {
          content: [{ type: "text" as const, text: `Note added to task ${params.taskId}` }],
          details: result,
        };
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        await appendToolLog(context, `task_note_add failed taskId=${params.taskId} error=${msg}`);
        return {
          content: [{ type: "text" as const, text: `Failed to add note: ${msg}` }],
          details: { taskId: params.taskId, error: msg },
        };
      }
    },
  } as ToolDefinition;
}

/**
 * Create a task_risk_add ToolDefinition that writes operator-visible risks to the task.
 *
 * Risks are stored via the Elixir backend's task.annotate command with kind="risk"
 * and are visible in the operator UI for risk tracking.
 */
export function createTaskRiskAddTool(client: ElixirServerClient, context: ForemanToolContext): ToolDefinition {
  return {
    name: "task_risk_add",
    label: "Task Risk Add",
    description: "Add an operator-visible risk to a task. Risks are stored in the task store and visible in the operator UI for risk tracking.",
    promptSnippet: "Write operator-visible risks via sendCommand('task.annotate', {kind: 'risk', ...})",
    promptGuidelines: [
      "Use task_risk_add to document potential blockers, uncertainties, or concerns",
      "Risks are visible in the operator UI for tracking and mitigation",
    ],
    parameters: TaskAnnotateParams,
    async execute(_toolCallId: string, params: Static<typeof TaskAnnotateParams>) {
      try {
        const response = await client.sendCommand({
          command_id: `risk-add-${params.taskId}-${Date.now()}`,
          command_type: "task.annotate",
          payload: {
            project_id: context.taskId.split("-")[0],
            task_id: params.taskId,
            author: "agent",
            kind: "risk",
            body: params.body,
            run_id: context.runId,
          },
        });
        if (!response.ok) {
          await appendToolLog(context, `task_risk_add failed taskId=${params.taskId} error=${response.error.message}`);
          return {
            content: [{ type: "text" as const, text: `Failed to add risk: ${response.error.message}` }],
            details: { taskId: params.taskId, error: response.error.message },
          };
        }
        const result = {
          taskId: params.taskId,
          kind: "risk",
          body: params.body,
          runId: context.runId,
          addedAt: nowIso(),
        };
        await appendToolLog(context, `task_risk_add ok taskId=${params.taskId}`);
        return {
          content: [{ type: "text" as const, text: `Risk added to task ${params.taskId}` }],
          details: result,
        };
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        await appendToolLog(context, `task_risk_add failed taskId=${params.taskId} error=${msg}`);
        return {
          content: [{ type: "text" as const, text: `Failed to add risk: ${msg}` }],
          details: { taskId: params.taskId, error: msg },
        };
      }
    },
  } as ToolDefinition;
}

// ── File ownership tools ───────────────────────────────────────────────────────

const FileReserveParams = Type.Object({
  files: Type.Array(Type.String({ description: "List of file paths to reserve for exclusive editing" })),
  leaseSecs: Type.Optional(Type.Number({ description: "Lease duration in seconds (default: 300)" })),
});

/**
 * Create a file_reserve ToolDefinition that claims exclusive edit ownership of files.
 *
 * Agents call this tool before editing files to coordinate ownership and prevent
 * conflicting edits. The lease expires automatically if not released.
 */
export function createFileReserveTool(context: ForemanToolContext): ToolDefinition {
  return {
    name: "file_reserve",
    label: "File Reserve",
    description: "Reserve files for exclusive editing ownership. Call before editing files to coordinate with other agents and prevent conflicting changes.",
    promptSnippet: "Reserve files for edit ownership before making changes",
    promptGuidelines: [
      "Call file_reserve before editing files that other agents may be working on",
      "Use file_release when done editing to allow other agents to edit the files",
      "Optional leaseSecs parameter sets automatic expiration (default: 300 seconds)",
    ],
    parameters: FileReserveParams,
    async execute(_toolCallId: string, params: Static<typeof FileReserveParams>) {
      const owner = `${context.phase}-${context.taskId}`;
      const leaseSecs = params.leaseSecs ?? 300;
      if (context.onFileReserve) {
        context.onFileReserve(params.files, owner, leaseSecs);
      }
      await appendToolLog(context, `file_reserve files=${params.files.length} owner=${owner} leaseSecs=${leaseSecs}`);
      return {
        content: [{ type: "text" as const, text: `Reserved ${params.files.length} file(s) for ${owner} (lease: ${leaseSecs}s)` }],
        details: { files: params.files, owner, leaseSecs },
      };
    },
  } as ToolDefinition;
}

const FileReleaseParams = Type.Object({
  files: Type.Array(Type.String({ description: "List of file paths to release from exclusive editing" })),
});

/**
 * Create a file_release ToolDefinition that releases edit ownership of reserved files.
 *
 * Agents call this tool when done editing to allow other agents to edit the files.
 */
export function createFileReleaseTool(context: ForemanToolContext): ToolDefinition {
  return {
    name: "file_release",
    label: "File Release",
    description: "Release file edit reservations. Call when done editing to allow other agents to edit the reserved files.",
    promptSnippet: "Release file edit ownership after completing changes",
    promptGuidelines: [
      "Call file_release when done editing to release reserved files",
      "Releasing files allows other agents to reserve and edit them",
    ],
    parameters: FileReleaseParams,
    async execute(_toolCallId: string, params: Static<typeof FileReleaseParams>) {
      const owner = `${context.phase}-${context.taskId}`;
      if (context.onFileRelease) {
        context.onFileRelease(params.files, owner);
      }
      await appendToolLog(context, `file_release files=${params.files.length} owner=${owner}`);
      return {
        content: [{ type: "text" as const, text: `Released ${params.files.length} file(s) from ${owner}` }],
        details: { files: params.files, owner },
      };
    },
  } as ToolDefinition;
}

const FileChangesParams = Type.Object({
  files: Type.Array(Type.String({ description: "List of file paths that were changed" })),
  operation: Type.Optional(Type.Union([
    Type.Literal("created", { description: "Files were created" }),
    Type.Literal("modified", { description: "Files were modified" }),
    Type.Literal("deleted", { description: "Files were deleted" }),
  ], { description: "Type of change made to the files" })),
});

/**
 * Create a file_changes ToolDefinition that reports files modified during the phase.
 *
 * Agents call this tool to report files they changed, which are tracked in
 * progress.filesChanged for downstream phases and reporting.
 */
export function createFileChangesTool(context: ForemanToolContext): ToolDefinition {
  return {
    name: "file_changes",
    label: "File Changes",
    description: "Report files that were changed during this phase. Tracks modifications in progress.filesChanged for downstream phases and reporting.",
    promptSnippet: "Report changed files for progress tracking",
    promptGuidelines: [
      "Call file_changes to report files you created, modified, or deleted",
      "Files are added to progress.filesChanged for QA and finalize verification",
      "The operation parameter categorizes the type of change",
    ],
    parameters: FileChangesParams,
    async execute(_toolCallId: string, params: Static<typeof FileChangesParams>) {
      if (context.onFileChanges) {
        context.onFileChanges(params.files);
      }
      await appendToolLog(context, `file_changes files=${params.files.length} operation=${params.operation ?? "modified"}`);
      return {
        content: [{ type: "text" as const, text: `Reported ${params.files.length} file change(s): ${params.operation ?? "modified"}` }],
        details: { files: params.files, operation: params.operation ?? "modified" },
      };
    },
  } as ToolDefinition;
}

