/**
 * agent-mail-helpers.ts — Testable Agent Mail helper functions.
 *
 * Extracted from agent-worker.ts to allow unit testing without triggering
 * agent-worker's main() at import time.
 *
 * TRD-2026-003: TRD-002 [satisfies REQ-002, REQ-026, AC-022-3]
 */

import type { AgentMailClient } from "./agent-mail-client.js";

// Re-export log type for use in agent-worker.ts
type LogFn = (msg: string) => void;

/**
 * Fetch the most recent unacknowledged message matching a subject prefix from an Agent Mail inbox.
 *
 * Resolution logic:
 *   1. If client is null, return null immediately (no API calls)
 *   2. Fetch up to 20 unacknowledged messages from the inbox
 *   3. Filter by subject prefix (and optionally by runId in subject or body)
 *   4. Sort by receivedAt descending, take the most recent
 *   5. Acknowledge the match (errors non-fatal — body still returned)
 *   6. Return the message body
 *
 * Uses AbortSignal.timeout(5000) indirectly via the client's timeout mechanism.
 * Returns null within 5 seconds if Agent Mail is unreachable (REQ-022/AC-022-3).
 *
 * @param client       The Agent Mail client (null = Agent Mail disabled)
 * @param inboxRole    Logical role name for the inbox (e.g. "developer-bd-abc1")
 * @param subjectPrefix Subject prefix to match (e.g. "Explorer Report", "QA Feedback")
 * @param runId        Optional run ID to filter stale messages from previous runs
 * @param log          Optional log function (defaults to stderr)
 * @returns            Message body string, or null if not found / error
 */
export async function fetchLatestPhaseMessage(
  client: AgentMailClient | null,
  inboxRole: string,
  subjectPrefix: string,
  runId?: string,
  log: LogFn = (msg: string) => process.stderr.write(`[agent-mail] ${msg}\n`),
): Promise<string | null> {
  if (!client) return null;

  try {
    // Fetch inbox (client uses AbortController timeout internally)
    const messages = await client.fetchInbox(inboxRole, { limit: 20 });

    // Filter: unacknowledged + subject starts with prefix
    let candidates = messages.filter(
      (m) => !m.acknowledged && m.subject.startsWith(subjectPrefix),
    );

    // If runId provided, further filter to only messages containing that runId
    if (runId !== undefined) {
      candidates = candidates.filter(
        (m) => m.subject.includes(runId) || m.body.includes(runId),
      );
    }

    if (candidates.length === 0) return null;

    // Sort by receivedAt descending, take most recent
    candidates.sort(
      (a, b) => new Date(b.receivedAt).getTime() - new Date(a.receivedAt).getTime(),
    );
    const match = candidates[0];

    // Acknowledge (non-fatal — still return body on error)
    try {
      await client.acknowledgeMessage(inboxRole, parseInt(match.id, 10));
    } catch (ackErr: unknown) {
      const msg = ackErr instanceof Error ? ackErr.message : String(ackErr);
      log(`acknowledgeMessage failed (non-fatal): ${msg}`);
    }

    log(`fetchLatestPhaseMessage: matched "${match.subject}" for inbox "${inboxRole}"`);
    return match.body;
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`fetchLatestPhaseMessage failed (non-fatal): ${msg}`);
    return null;
  }
}
