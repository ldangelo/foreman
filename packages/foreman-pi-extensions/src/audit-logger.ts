/**
 * foreman-audit extension
 *
 * Writes structured JSONL entries to ~/.foreman/audit/{runId}.jsonl for every
 * Pi event.  Additionally streams each event to the Agent Mail "audit-log"
 * inbox as the primary store, with local JSONL as the always-on fallback.
 *
 * Failure handling:
 *   - If Agent Mail send_message fails the entry is appended to
 *     ~/.foreman/audit-buffer/{runId}.jsonl (buffer).
 *   - On the next event, if the buffer file exists and Agent Mail healthCheck
 *     passes, all buffered entries are flushed before the new event is sent.
 *   - Buffer flush is best-effort: silent failure, buffer deleted on success.
 *
 * The extension is observer-only: it never blocks tool calls and silently
 * swallows all I/O and network errors so it can never stall the pipeline.
 */

import { appendFileSync, mkdirSync, readFileSync, unlinkSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import type {
  ForemanExtension,
  ToolCallEvent,
  TurnEndEvent,
  AgentEndEvent,
  ToolExecutionStartEvent,
  ToolExecutionEndEvent,
  ExtensionContext,
} from './types.js';

// ── Public types ──────────────────────────────────────────────────────────────

export interface AuditEntry {
  timestamp: string;                      // ISO 8601
  runId: string;                          // from FOREMAN_RUN_ID env
  seedId: string;                         // from FOREMAN_SEED_ID env
  phase: string;                          // from FOREMAN_PHASE env
  eventType: string;                      // discriminant field
  model?: string;                         // from FOREMAN_MODEL env — active model at event time
  toolName?: string;                      // tool_call / tool_execution_* events
  blocked?: boolean;                      // tool_call events that were blocked
  blockReason?: string;                   // reason a tool_call was blocked
  turnNumber?: number;                    // turn_end events
  totalTokens?: number;                   // turn_end / agent_end events
  reason?: string;                        // agent_end events
  durationMs?: number;                    // tool_execution_end events
  sessionId?: string;                     // switch_session / session_fork
  parentSessionId?: string;              // session_fork events
  details?: Record<string, unknown>;     // catch-all for extra data
}

// ── Agent Mail helpers ────────────────────────────────────────────────────────

/**
 * Resolve Agent Mail base URL from env var or default.
 * Always strips trailing slash.
 */
function resolveAgentMailUrl(): string {
  const env = process.env['AGENT_MAIL_URL'];
  if (env !== undefined && env !== '') {
    return env.replace(/\/$/, '');
  }
  return 'http://localhost:8765';
}

/**
 * Post a single audit entry to the Agent Mail send_message endpoint.
 * Throws on network error or timeout — callers must catch.
 */
async function postAuditToAgentMail(baseUrl: string, entry: AuditEntry): Promise<void> {
  const payload: Record<string, unknown> = {
    to: 'audit-log',
    subject: entry.eventType,
    body: JSON.stringify(entry),
    metadata: {
      runId: entry.runId,
      seedId: entry.seedId,
      phase: entry.phase,
    },
  };
  await fetch(`${baseUrl}/send_message`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(500),
  });
}

/**
 * Check whether Agent Mail is reachable.
 * Returns false on any error.
 */
async function agentMailHealthCheck(baseUrl: string): Promise<boolean> {
  try {
    const response = await fetch(`${baseUrl}/health`, {
      method: 'GET',
      signal: AbortSignal.timeout(500),
    });
    return response.ok;
  } catch {
    return false;
  }
}

// ── Factory ───────────────────────────────────────────────────────────────────

/**
 * Creates a new audit extension instance.
 *
 * @param outputDir  - Directory to write JSONL files into.
 *   Defaults to `~/.foreman/audit/`. Each run gets its own file:
 *   `{outputDir}/{FOREMAN_RUN_ID}.jsonl`.
 * @param bufferDir  - Directory to write buffered (unsent) Agent Mail entries.
 *   Defaults to `~/.foreman/audit-buffer/`.
 */
export function createAuditExtension(outputDir?: string, bufferDir?: string): ForemanExtension {
  const auditDir = outputDir ?? join(homedir(), '.foreman', 'audit');
  const agentMailBufferDir = bufferDir ?? join(homedir(), '.foreman', 'audit-buffer');

  // Lazily resolved on first write so tests can mutate env before the first call.
  let auditFile: string | null = null;

  // Accumulated entries kept in memory for potential future async-flush (Phase 3).
  // In Phase 1 we write synchronously, so this buffer stays empty after each flush.
  const buffer: AuditEntry[] = [];

  function getAuditFile(): string {
    if (!auditFile) {
      const runId = process.env['FOREMAN_RUN_ID'] ?? 'unknown';
      mkdirSync(auditDir, { recursive: true });
      auditFile = join(auditDir, `${runId}.jsonl`);
    }
    return auditFile;
  }

  function getBufferFile(): string {
    const runId = process.env['FOREMAN_RUN_ID'] ?? 'unknown';
    return join(agentMailBufferDir, `${runId}.jsonl`);
  }

  function writeEntry(entry: AuditEntry): void {
    try {
      appendFileSync(getAuditFile(), JSON.stringify(entry) + '\n', 'utf-8');
    } catch {
      // Silent failure — audit must never block the pipeline.
    }
  }

  /** Append a single entry to the Agent Mail buffer file. */
  function appendToBuffer(entry: AuditEntry): void {
    try {
      mkdirSync(agentMailBufferDir, { recursive: true });
      appendFileSync(getBufferFile(), JSON.stringify(entry) + '\n', 'utf-8');
    } catch {
      // Silent failure.
    }
  }

  /**
   * Fire-and-forget: send entry to Agent Mail.
   * On failure, buffer the entry for later retry.
   * Before sending, checks if a buffer exists and Agent Mail is healthy;
   * if so, flushes the buffer first.
   */
  function sendToAgentMail(entry: AuditEntry): void {
    const baseUrl = resolveAgentMailUrl();

    void (async () => {
      try {
        // If a buffer file exists, attempt flush before sending the new entry.
        const bufferFile = getBufferFile();
        if (existsSync(bufferFile)) {
          const healthy = await agentMailHealthCheck(baseUrl);
          if (healthy) {
            await flushBuffer(baseUrl, bufferFile);
          }
        }

        // Send the current entry.
        await postAuditToAgentMail(baseUrl, entry);
      } catch {
        // Agent Mail unreachable — buffer this entry for later retry.
        appendToBuffer(entry);
      }
    })();
  }

  /**
   * Flush all entries from the buffer file to Agent Mail.
   * Deletes the buffer file on success. Silent failure otherwise.
   */
  async function flushBuffer(baseUrl: string, bufferFile: string): Promise<void> {
    try {
      const raw = readFileSync(bufferFile, 'utf-8');
      const lines = raw.split('\n').filter(l => l.trim().length > 0);
      for (const line of lines) {
        const bufferedEntry = JSON.parse(line) as AuditEntry;
        await postAuditToAgentMail(baseUrl, bufferedEntry);
      }
      // All entries sent — remove the buffer file.
      unlinkSync(bufferFile);
    } catch {
      // Best-effort: silent failure leaves buffer intact for next attempt.
    }
  }

  function makeBase(eventType: string): AuditEntry {
    return {
      timestamp: new Date().toISOString(),
      runId: process.env['FOREMAN_RUN_ID'] ?? 'unknown',
      seedId: process.env['FOREMAN_SEED_ID'] ?? 'unknown',
      phase: process.env['FOREMAN_PHASE'] ?? 'unknown',
      model: process.env['FOREMAN_MODEL'] ?? 'unknown',
      eventType,
    };
  }

  /** Write to local JSONL and fire-and-forget to Agent Mail. */
  function recordEntry(entry: AuditEntry): void {
    writeEntry(entry);
    sendToAgentMail(entry);
  }

  return {
    name: 'foreman-audit',
    version: '1.0.0',

    onToolCall(event: ToolCallEvent, _ctx: ExtensionContext) {
      recordEntry({ ...makeBase('tool_call'), toolName: event.toolName });
      return undefined; // Observer only — never blocks.
    },

    onTurnEnd(event: TurnEndEvent, _ctx: ExtensionContext) {
      recordEntry({
        ...makeBase('turn_end'),
        turnNumber: event.turnNumber,
        totalTokens: event.contextUsage.totalTokens,
      });
    },

    onAgentEnd(event: AgentEndEvent, _ctx: ExtensionContext) {
      const entry: AuditEntry = {
        ...makeBase('agent_end'),
        reason: event.reason,
      };
      if (event.finalContextUsage !== undefined) {
        entry.totalTokens = event.finalContextUsage.totalTokens;
      }
      recordEntry(entry);

      // Drain any buffered entries (buffer is always empty in Phase 1 since
      // we write synchronously, but retained for Phase 3 async-flush support).
      for (const buffered of buffer) {
        writeEntry(buffered);
      }
      buffer.length = 0;
    },

    onToolExecutionStart(event: ToolExecutionStartEvent, _ctx: ExtensionContext) {
      recordEntry({
        ...makeBase('tool_execution_start'),
        toolName: event.toolName,
        details: { toolCallId: event.toolCallId },
      });
    },

    onToolExecutionEnd(event: ToolExecutionEndEvent, _ctx: ExtensionContext) {
      recordEntry({
        ...makeBase('tool_execution_end'),
        toolName: event.toolName,
        durationMs: event.durationMs,
        details: { toolCallId: event.toolCallId, success: event.success },
      });
    },
  };
}

// ── Standalone helper ─────────────────────────────────────────────────────────

/**
 * Records a blocked tool call directly (called by foreman-tool-gate via an
 * audit callback rather than through the hook system).
 *
 * This is a stub in Phase 1. Phase 2 (TRD-006) will wire this to the shared
 * audit extension instance so gate-blocked calls appear in the same JSONL log.
 */
export function recordBlockedToolCall(_entry: {
  toolName: string;
  phase: string;
  reason: string;
  runId?: string;
  seedId?: string;
}): void {
  // No-op in Phase 1 — tool-gate correlation is implemented in TRD-006.
}

// ── Default singleton ─────────────────────────────────────────────────────────

/**
 * Default shared audit extension instance writing to `~/.foreman/audit/`.
 * Most consumers should use this directly rather than calling
 * `createAuditExtension()`.
 */
export const audit = createAuditExtension();
