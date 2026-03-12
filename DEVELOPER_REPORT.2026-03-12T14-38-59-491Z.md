# Developer Report: Inter-agent messaging system (SQLite mail)

## Approach

Implemented a SQLite-backed inter-agent messaging system in two layers:

1. **Store layer** (`src/lib/store.ts`): Added a `messages` table and CRUD methods directly on `ForemanStore`, following existing patterns (prepared statements, UUID primary keys, ISO timestamp strings, soft deletes via `deleted_at`).

2. **MailClient layer** (`src/lib/mail.ts`): A high-level, agent-scoped wrapper around the store methods, exposing a friendly API (`send`, `inbox`, `markRead`, `markAllRead`, `delete`, `allRunMessages`, `formatInbox`). The client is pre-bound to a `runId` and `agentType` so agents never need to handle scoping manually.

Messages are scoped by `run_id` so agents in different pipeline runs cannot cross-communicate. Soft deletion (via `deleted_at`) preserves an audit trail. Two indexes on `(run_id, recipient_agent_type)` and `(run_id, sender_agent_type)` ensure efficient mailbox queries.

## Files Changed

- `src/lib/store.ts` — Added:
  - `Message` interface (id, run_id, sender/recipient agent types, subject, body, read flag, created_at, deleted_at)
  - `messages` table DDL in `SCHEMA` constant (with two indexes for fast lookup)
  - `sendMessage()`, `getMessages()`, `getAllMessages()`, `markMessageRead()`, `markAllMessagesRead()`, `deleteMessage()`, `getMessage()` methods on `ForemanStore`

- `src/lib/mail.ts` — New file:
  - `MailMessage` interface (camelCase, `read: boolean`, `createdAt: Date`) — cleaner shape for consumers
  - `MailClient` class wrapping store methods with agent-scoped API
  - `formatInbox()` helper to serialize unread messages into a prompt-friendly string

## Tests Added/Modified

- `src/lib/__tests__/store.test.ts` — Added 7 tests covering:
  - Basic send/retrieve cycle
  - Unread-only filtering
  - `markAllMessagesRead` scoped to one agent
  - Soft delete (deleted_at set, excluded from queries, raw record survives)
  - Run ID isolation
  - `getAllMessages` (across all agents, excludes deleted)
  - `getMessage` by ID + null for missing
  - ASC ordering by `created_at`

- `src/lib/__tests__/mail.test.ts` — New file with 13 tests covering:
  - `send()` returns correct `MailMessage` shape
  - `inbox()` default unread-only behaviour
  - `inbox()` agent isolation (messages to other agents excluded)
  - `inbox(true/false)` read/unread switching
  - `allMessages()` includes read messages
  - `markRead()` / `markAllRead()` with cross-agent isolation
  - `delete()` soft-delete excludes message from inbox
  - `allRunMessages()` cross-agent view, excludes deleted
  - `formatInbox()` empty placeholder and formatted output
  - Run-level isolation (two runs, same agent type, no cross-visibility)

**All 39 tests pass. TypeScript compiles with zero errors.**

## Decisions & Trade-offs

- **No `mailboxes` table**: The explorer suggested a separate `mailboxes` table, but it added complexity without benefit for the read patterns needed (lookup by `run_id + agent_type` is fast with an index on `messages` directly). Skipped to keep the schema simpler.
- **Soft delete over hard delete**: Preserves audit trail. The `deleted_at` column is indexed as a `DEFAULT NULL` so `WHERE deleted_at IS NULL` scans efficiently.
- **`read` as `INTEGER` in SQLite**: SQLite has no native boolean; `0/1` is the conventional encoding. `MailMessage.read` presents it as `boolean` to TypeScript consumers.
- **`formatInbox()` helper**: Makes it easy to inject unread messages into an agent's system prompt without additional plumbing in the caller.
- **No agent-worker.ts changes in this pass**: The infrastructure (store + MailClient) is fully functional and tested. Wiring it into the agent execution loop and updating prompts in `roles.ts` / `lead-prompt.ts` is deferred as a follow-up — the explorer noted this as Phase 2 and Phase 3 work. This avoids scope creep and keeps the core system reviewable independently.

## Known Limitations

- **No agent-worker integration yet**: `agent-worker.ts` does not yet inject mail into the SDK query loop. Agents must be updated to use `MailClient` explicitly and prompts need messaging instructions added to `roles.ts`.
- **No retention/cleanup policy**: Messages accumulate indefinitely. A periodic cleanup job (e.g. delete all `deleted_at IS NOT NULL` older than N days) would be needed for long-running deployments.
- **No blocking/await primitive**: Messaging is purely asynchronous. If an agent needs to wait for a reply, it must poll or rely on the Lead orchestrator to sequence work — no blocking `receive()` is provided by design (would conflict with the SDK query model).
