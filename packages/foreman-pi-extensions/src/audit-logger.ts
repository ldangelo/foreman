/**
 * foreman-audit extension
 *
 * Writes structured JSONL entries to ~/.foreman/audit/{runId}.jsonl for every
 * Pi event. The extension is observer-only: it never blocks tool calls and
 * silently swallows write errors so it can never stall the pipeline.
 */

import { appendFileSync, mkdirSync } from 'node:fs';
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

// ── Factory ───────────────────────────────────────────────────────────────────

/**
 * Creates a new audit extension instance.
 *
 * @param outputDir - Directory to write JSONL files into.
 *   Defaults to `~/.foreman/audit/`. Each run gets its own file:
 *   `{outputDir}/{FOREMAN_RUN_ID}.jsonl`.
 */
export function createAuditExtension(outputDir?: string): ForemanExtension {
  const auditDir = outputDir ?? join(homedir(), '.foreman', 'audit');

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

  function writeEntry(entry: AuditEntry): void {
    try {
      appendFileSync(getAuditFile(), JSON.stringify(entry) + '\n', 'utf-8');
    } catch {
      // Silent failure — audit must never block the pipeline.
    }
  }

  function makeBase(eventType: string): AuditEntry {
    return {
      timestamp: new Date().toISOString(),
      runId: process.env['FOREMAN_RUN_ID'] ?? 'unknown',
      seedId: process.env['FOREMAN_SEED_ID'] ?? 'unknown',
      phase: process.env['FOREMAN_PHASE'] ?? 'unknown',
      eventType,
    };
  }

  return {
    name: 'foreman-audit',
    version: '1.0.0',

    onToolCall(event: ToolCallEvent, _ctx: ExtensionContext) {
      writeEntry({ ...makeBase('tool_call'), toolName: event.toolName });
      return undefined; // Observer only — never blocks.
    },

    onTurnEnd(event: TurnEndEvent, _ctx: ExtensionContext) {
      writeEntry({
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
      writeEntry(entry);

      // Drain any buffered entries (buffer is always empty in Phase 1 since
      // we write synchronously, but retained for Phase 3 async-flush support).
      for (const buffered of buffer) {
        writeEntry(buffered);
      }
      buffer.length = 0;
    },

    onToolExecutionStart(event: ToolExecutionStartEvent, _ctx: ExtensionContext) {
      writeEntry({
        ...makeBase('tool_execution_start'),
        toolName: event.toolName,
        details: { toolCallId: event.toolCallId },
      });
    },

    onToolExecutionEnd(event: ToolExecutionEndEvent, _ctx: ExtensionContext) {
      writeEntry({
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
