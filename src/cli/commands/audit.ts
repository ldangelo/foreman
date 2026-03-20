/**
 * audit.ts
 *
 * `foreman audit <seedId>` — reads JSONL audit files written by the
 * foreman-audit extension and displays them in a human-readable table or raw
 * JSON.
 *
 * Options:
 *   --phase <phase>        Filter by pipeline phase (explorer/developer/qa/reviewer)
 *   --event-type <type>    Filter by event type (tool_call/turn_end/agent_end/etc.)
 *   --since <timestamp>    ISO timestamp lower bound
 *   --until <timestamp>    ISO timestamp upper bound
 *   --search <text>        Case-insensitive text search
 *   --json                 Output raw JSON array instead of formatted table
 *   --blocked              Show only blocked tool calls
 */

import { Command } from "commander";
import chalk from "chalk";
import {
  readAuditEntries,
  type AuditEntry,
  type AuditFilter,
} from "../../lib/audit-reader.js";
import {
  AgentMailClient,
  type AgentMailMessage,
} from "../../orchestrator/agent-mail-client.js";

// ── Formatting helpers ────────────────────────────────────────────────────────

const SEPARATOR = chalk.dim("─".repeat(72));

function formatTimestamp(ts: string): string {
  return chalk.dim(ts);
}

function formatPhase(phase: string): string {
  const colors: Record<string, (s: string) => string> = {
    explorer: chalk.cyan,
    developer: chalk.green,
    qa: chalk.yellow,
    reviewer: chalk.magenta,
    finalize: chalk.blue,
  };
  const color = colors[phase] ?? chalk.white;
  return color(phase.padEnd(10));
}

function formatEventType(eventType: string): string {
  return chalk.white(eventType.padEnd(12));
}

function formatBlockStatus(entry: AuditEntry): string {
  if (entry.eventType !== "tool_call") {
    return chalk.dim("   —  ");
  }
  if (entry.blocked) {
    const reason = entry.blockReason ? ` ${entry.blockReason}` : "";
    return chalk.red(`BLOCKED:${reason}`);
  }
  return chalk.green("OK");
}

function renderEntry(entry: AuditEntry): string {
  const parts: string[] = [
    formatTimestamp(entry.timestamp),
    formatPhase(entry.phase),
    formatEventType(entry.eventType),
  ];

  if (entry.toolName) {
    parts.push(chalk.cyan(entry.toolName.padEnd(20)));
  } else {
    parts.push(" ".repeat(20));
  }

  parts.push(formatBlockStatus(entry));

  return parts.join("  ");
}

function renderTable(seedId: string, entries: AuditEntry[], sourceNote?: string): void {
  // Derive runId from the first entry (all entries share the same run).
  const runId = entries[0]?.runId ?? "unknown";

  const headerSuffix = sourceNote !== undefined ? `  ${sourceNote}` : "";
  console.log(
    chalk.bold(`Audit log for seed ${chalk.cyan(seedId)} (run: ${chalk.dim(runId)})`) + headerSuffix,
  );
  console.log(SEPARATOR);

  for (const entry of entries) {
    console.log(renderEntry(entry));
  }

  console.log(SEPARATOR);

  // Summary footer
  const blockedCount = entries.filter(
    (e) => e.eventType === "tool_call" && e.blocked === true,
  ).length;

  const phases = [...new Set(entries.map((e) => e.phase))].join(", ");

  console.log(
    `Total: ${chalk.white(entries.length)} entries | ` +
      `Blocked: ${chalk.red(blockedCount)} tool calls | ` +
      `Phases: ${chalk.cyan(phases)}`,
  );
}

// ── Agent Mail search ─────────────────────────────────────────────────────────

/**
 * Attempt to search audit entries via Agent Mail FTS5.
 *
 * Returns an array of matching AuditEntry objects when Agent Mail is available
 * and successfully returns results.  Returns null when Agent Mail is
 * unreachable or any error occurs — the caller must fall back to the local
 * JSONL path in that case.
 */
async function searchViaAgentMail(searchTerm: string): Promise<AuditEntry[] | null> {
  try {
    const client = new AgentMailClient();
    const available = await client.healthCheck();
    if (!available) {
      return null;
    }

    const messages: AgentMailMessage[] = await client.fetchInbox("audit-log", { limit: 1000 });

    const lowerSearch = searchTerm.toLowerCase();
    const entries: AuditEntry[] = [];

    for (const msg of messages) {
      try {
        const entry = JSON.parse(msg.body) as AuditEntry;
        // Apply case-insensitive search across the serialized entry.
        const serialized = JSON.stringify(entry).toLowerCase();
        if (serialized.includes(lowerSearch)) {
          entries.push(entry);
        }
      } catch {
        // Malformed body — skip.
      }
    }

    return entries;
  } catch {
    return null;
  }
}

// ── Command definition ────────────────────────────────────────────────────────

interface AuditOptions {
  phase?: string;
  eventType?: string;
  since?: string;
  until?: string;
  search?: string;
  json?: boolean;
  blocked?: boolean;
}

export const auditCommand = new Command("audit")
  .description("Display audit log entries for a completed agent run")
  .argument("<seedId>", "The seed (bead) ID to inspect")
  .option("--phase <phase>", "Filter by pipeline phase (explorer/developer/qa/reviewer)")
  .option("--event-type <type>", "Filter by event type (tool_call/turn_end/agent_end/etc.)")
  .option("--since <timestamp>", "ISO timestamp lower bound (inclusive)")
  .option("--until <timestamp>", "ISO timestamp upper bound (inclusive)")
  .option("--search <text>", "Case-insensitive text search across all fields")
  .option("--json", "Output raw JSON array instead of formatted table")
  .option("--blocked", "Show only blocked tool calls (eventType=tool_call AND blocked=true)")
  .action(async (seedId: string, opts: AuditOptions) => {
    try {
      // Build the filter to pass to readAuditEntries.
      const filter: AuditFilter = {};

      if (opts.phase) filter.phase = opts.phase;
      if (opts.eventType) filter.eventType = opts.eventType;
      if (opts.since) filter.since = opts.since;
      if (opts.until) filter.until = opts.until;
      if (opts.search) filter.search = opts.search;

      // --blocked implies we only care about tool_call events; we post-filter
      // for blocked=true after readAuditEntries returns.
      if (opts.blocked) {
        filter.eventType = "tool_call";
      }

      // When --search is provided, try Agent Mail FTS5 first.
      // If Agent Mail is unavailable or returns null, fall through to the
      // local JSONL path (seamless fallback — no error is shown to the user).
      let agentMailEntries: AuditEntry[] | null = null;
      if (opts.search) {
        agentMailEntries = await searchViaAgentMail(opts.search);
      }

      const entries = agentMailEntries !== null
        ? agentMailEntries
        : await readAuditEntries(seedId, filter);

      // Apply --blocked post-filter (readAuditEntries doesn't have a blocked
      // field filter — we filter ourselves after receiving the results).
      const filtered = opts.blocked
        ? entries.filter((e) => e.blocked === true)
        : entries;

      // ── JSON output ──────────────────────────────────────────────────────
      if (opts.json) {
        console.log(JSON.stringify(filtered, null, 2));
        return;
      }

      // ── No entries ───────────────────────────────────────────────────────
      if (filtered.length === 0) {
        console.log(chalk.dim("No audit entries found"));
        return;
      }

      // ── Tabular output ───────────────────────────────────────────────────
      const sourceNote = agentMailEntries !== null
        ? chalk.dim("(via Agent Mail FTS5)")
        : undefined;
      renderTable(seedId, filtered, sourceNote);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      if (opts.json) {
        console.error(JSON.stringify({ error: message }));
      } else {
        console.error(chalk.red(`Error: ${message}`));
      }
      process.exit(1);
    }
  });
