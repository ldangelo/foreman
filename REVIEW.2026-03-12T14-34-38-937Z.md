# Code Review: Inter-agent messaging system (SQLite mail)

## Verdict: FAIL

## Summary
The implementation is well-structured and covers the core requirements: a `messages` table in SQLite, `ForemanStore` messaging methods, a `MailClient` wrapper, and comprehensive tests. However, there is a critical data-loss bug in the migration approach: `DROP TABLE IF EXISTS messages` is placed in the MIGRATIONS array without any versioning guard, causing it to execute and destroy all message data on every store construction. The rest of the code — schema design, API surface, test coverage, and the `MailClient` abstraction — is solid.

## Issues

- **[CRITICAL]** `src/lib/store.ts:177` — `DROP TABLE IF EXISTS messages` in the MIGRATIONS array runs every time the `ForemanStore` constructor is called. Unlike the other migrations (`ALTER TABLE ADD COLUMN`, `RENAME COLUMN`) which are idempotent via failure (they throw on re-execution, are caught, and skipped), `DROP TABLE IF EXISTS` never throws — it silently succeeds on every run. This means all messages are deleted and the table recreated empty every time any component opens the store. The fix is to guard this migration: either add a `schema_migrations` tracking table (the proper solution), or move the drop/recreate into a one-time check using a user_version pragma (e.g., `PRAGMA user_version`) that gates execution.

- **[WARNING]** `src/lib/store.ts:530,538,551` — Message queries use `ORDER BY created_at ASC` without a secondary sort key. Unlike run queries elsewhere in the file that use `ORDER BY created_at DESC, rowid DESC`, messages have no tiebreaker. If two messages are inserted within the same millisecond (e.g., during fast test runs or concurrent agents), ordering is non-deterministic. Adding `, rowid ASC` as a tiebreaker would make ordering stable.

- **[WARNING]** `src/lib/store.ts:480-598` — `getMessage()`, `markMessageRead()`, and `deleteMessage()` perform no input validation and do not signal whether the operation found a record. If a caller passes an invalid `messageId`, the UPDATE silently affects 0 rows and the caller has no way to detect the failure. This is acceptable for internal tooling but `getMessage()` at least returns `null` for not-found, while the mutating methods give no feedback. Consider returning a boolean or the affected row count so callers can distinguish "no-op due to bad ID" from success.

- **[NOTE]** `src/lib/store.ts:570-574` — `markAllMessagesRead` skips already-deleted messages (`AND deleted_at IS NULL`). This is correct behavior (no need to mark deleted messages read), but it is different from how a typical email client would behave. The behavior is fine; it just deserves a comment explaining the intent since it looks like an oversight without one.

- **[NOTE]** `src/lib/mail.ts:159` — The `allRunMessages` test in `mail.test.ts` has `devMail.delete(msg.id)` where `msg` was sent by `leadMail` to `explorer` — a message `developer` neither sent nor received. The `deleteMessage` implementation has no ownership check, so any agent with the message ID can soft-delete any message in the run. This is likely acceptable for an internal system, but it is worth documenting that `delete()` in `MailClient` is not scoped to the caller's own messages.

## Positive Notes
- The decision to separate `MESSAGES_SCHEMA` from the main `SCHEMA` constant is the right architectural call — applying it post-migrations is the correct ordering. The approach would be correct if only the migration guard were fixed.
- The `Message` interface uses `read: number` (SQLite integer) at the store layer and `MailClient` converts it to `read: boolean` at the API layer. This is the right abstraction boundary.
- Run scoping is enforced consistently at the SQL level via `run_id` predicates; agents cannot accidentally read messages across runs.
- Test coverage is comprehensive: run isolation, agent isolation, soft delete, unread filtering, ordering, and `formatInbox` formatting are all directly tested.
- The `MailClient` wrapper is clean — it adds a developer-friendly API (`from`/`to` instead of `sender_agent_type`/`recipient_agent_type`, `boolean` read status, `Date` objects) without leaking store internals.
- Parameterized queries throughout; no string interpolation of user-supplied values in SQL.
