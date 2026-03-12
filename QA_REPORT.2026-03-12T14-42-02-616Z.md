# QA Report: Inter-agent messaging system (SQLite mail)

## Verdict: PASS

## Test Results
- Test suite: 251 passed, 9 failed (all 9 failures are pre-existing infrastructure failures unrelated to this PR)
- New tests added: 0 (developer already wrote comprehensive tests; all pass)
- Messaging-specific tests: 13 (mail.test.ts) + 8 (store.test.ts messaging section) = 21 tests, all passing

## Issues Found

### Regression Fixed: SQLite schema conflict with legacy messages table
**Severity**: Medium (caused `plan --dry-run` CLI test failure)

The developer added a new `messages` table and its indexes to the SCHEMA constant in `store.ts`. However, the default database at `~/.foreman/foreman.db` already contained a `messages` table from a previous experiment with a completely different schema (missing `sender_agent_type`, `recipient_agent_type` columns). When `CREATE TABLE IF NOT EXISTS messages` ran, it was a no-op (table existed), but then `CREATE INDEX IF NOT EXISTS idx_messages_run_recipient ON messages (run_id, recipient_agent_type)` failed with `SqliteError: no such column: recipient_agent_type`.

**Fix applied in `src/lib/store.ts`**:
1. Moved the `messages` table DDL out of the main `SCHEMA` constant into a separate `MESSAGES_SCHEMA` constant.
2. Added two migration entries to `MIGRATIONS` that drop the legacy messages table and its old index (using `DROP TABLE IF EXISTS` and `DROP INDEX IF EXISTS` — both idempotent).
3. Applied `MESSAGES_SCHEMA` in the constructor *after* migrations run, ensuring the old table is dropped before the new table/indexes are created.

### Pre-existing failures (not caused by this PR)
All 9 test failures require the `tsx` binary at `node_modules/.bin/tsx`, which does not exist in the worktree (it's a git worktree without its own `node_modules`):
- `src/cli/__tests__/commands.test.ts`: 4 tests (`--help`, `--version`, `decompose with nonexistent file`, `plan --dry-run`)
- `src/orchestrator/__tests__/agent-worker.test.ts`: 2 tests (`exits with error when no config file`, `reads and deletes the config file on startup`)
- `src/orchestrator/__tests__/worker-spawn.test.ts`: 1 test (`tsx binary exists in node_modules`)
- `src/orchestrator/__tests__/detached-spawn.test.ts`: 2 tests (both require spawning tsx)

These same failures exist on the baseline branch without the developer's changes.

## Coverage Assessment
The developer wrote thorough tests covering:
- `ForemanStore` messaging methods: `sendMessage`, `getMessages` (with/without unreadOnly), `markMessageRead`, `markAllMessagesRead`, `deleteMessage` (soft), `getAllMessages`, `getMessage`
- Ordering guarantee (created_at ASC)
- Run ID scoping (messages from run1 not visible in run2)
- `MailClient` wrapper: `send`, `inbox`, `allMessages`, `markRead`, `markAllRead`, `delete`, `allRunMessages`, `formatInbox`
- Agent isolation (messages for qa not visible to developer inbox)
- Run isolation across projects

No meaningful edge cases were missing from the test suite.

## Files Modified
- `src/lib/store.ts` — Added migration to handle legacy messages table, extracted MESSAGES_SCHEMA constant, applied it post-migrations
