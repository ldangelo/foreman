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
import type { ForemanStore } from "../lib/store.js";

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
          beadId: run.task_id,
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

// ── close-bead tool ─────────────────────────────────────────────────────

const CloseBeadParams = Type.Object({
  beadId: Type.Optional(Type.String({ description: "The bead ID to close (e.g. 'bd-abc')" })),
  taskId: Type.Optional(Type.String({ description: "Legacy alias for beadId" })),
  reason: Type.String({ description: "Brief reason for closing (e.g. 'Work already merged into dev')" }),
});

/**
 * Create a close_bead ToolDefinition that runs `br close <beadId>`.
 *
 * Used by the troubleshooter agent to mark a bead complete when the work has
 * been confirmed as done (e.g. already merged into the target branch).
 */
export function createCloseBeadTool(projectPath: string): ToolDefinition {
  return {
    name: "close_bead",
    label: "Close Bead",
    description: "Mark a bead as complete using the br CLI. Only call this when you have confirmed the work is done and merged.",
    promptSnippet: "Close a completed bead using br",
    promptGuidelines: [
      "Only close a bead when the work is confirmed complete and merged into the target branch",
    ],
    parameters: CloseBeadParams,
    async execute(
      _toolCallId: string,
      params: Static<typeof CloseBeadParams>,
    ) {
      const beadId = params.beadId ?? params.taskId;
      if (!beadId) {
        return {
          content: [{ type: "text" as const, text: "Failed to close bead: missing beadId" }],
          details: undefined,
        };
      }
      try {
        const brBin = process.env["BR_BIN"] ?? "br";
        const { stdout } = await execFileAsync(
          brBin,
          ["close", beadId, "--reason", params.reason],
          { cwd: projectPath },
        );
        return {
          content: [{ type: "text" as const, text: `Bead ${beadId} closed: ${stdout.trim()}` }],
          details: undefined,
        };
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text" as const, text: `Failed to close bead ${beadId}: ${msg}` }],
          details: undefined,
        };
      }
    },
  } as ToolDefinition;
}
