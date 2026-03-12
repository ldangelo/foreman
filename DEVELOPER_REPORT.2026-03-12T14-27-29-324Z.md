# Developer Report: Inter-agent messaging system (SQLite mail)

## Approach

This iteration addressed all issues raised in the previous code review against the already-implemented messaging system. The implementation (SQLite `messages` table, `ForemanStore` messaging methods, `MailClient` wrapper, and tests) was already in place; this pass focused on correctness, stability, and documentation fixes.

## Files Changed

### `src/lib/store.ts`

1. **[CRITICAL fix]** `DROP TABLE IF EXISTS messages` was executing on every `ForemanStore` constructor call, silently wiping all messages.
   - Removed the destructive DROP statements from the `MIGRATIONS` array.
   - Introduced `SCHEMA_VERSION = 1`, `SCHEMA_UPGRADE_SQL`, and a `PRAGMA user_version` gate in the constructor.
   - The upgrade SQL (DROP TABLE + DROP INDEX) now only runs once — when `user_version < SCHEMA_VERSION` — and then sets `user_version = 1` so subsequent opens skip it entirely.

2. **[WARNING fix]** Message queries lacked a secondary sort key, making ordering non-deterministic for messages inserted within the same millisecond.
   - Updated all three message `ORDER BY` clauses (`getMessages` unread path, `getMessages` all path, `getAllMessages`) from `ORDER BY created_at ASC` to `ORDER BY created_at ASC, rowid ASC`.

3. **[WARNING fix]** `markMessageRead()` and `deleteMessage()` returned `void`, giving callers no way to detect a no-op against an invalid ID.
   - Both methods now return `boolean` (`result.changes > 0`), signalling whether a row was actually affected.

4. **[NOTE fix]** `markAllMessagesRead` skipped deleted messages (`AND deleted_at IS NULL`) without explanation — this looked like an oversight.
   - Added an explanatory JSDoc comment clarifying that the guard is intentional: soft-deleted messages should not be resurected by a bulk-read operation.

### `src/lib/mail.ts`

5. **[NOTE fix]** `MailClient.delete()` has no ownership check — any agent can soft-delete any message by ID.
   - Added a JSDoc NOTE documenting this behavior explicitly, explaining that the intentional design relies on all agents sharing the same trust boundary.

### `src/lib/__tests__/store.test.ts`

- Added `markMessageRead returns true when message exists, false otherwise` test.
- Updated `soft-deletes a message` test to assert `deleteMessage` returns `true`.
- Added `deleteMessage returns false for a non-existent message id` test.
- Added `migration guard — messages survive store re-open` test: opens a store, sends a message, closes it, re-opens the same DB file, and asserts the message is still present. This directly guards against the critical regression.

## Tests Added/Modified

| File | Coverage |
|------|---------|
| `src/lib/__tests__/store.test.ts` | Boolean return from `markMessageRead` + `deleteMessage`; regression guard for re-open message persistence via `user_version` |

All 42 tests pass (29 store + 13 mail).

## Decisions & Trade-offs

- **`PRAGMA user_version` over a `schema_migrations` table**: A tracking table would be the "proper" solution for a growing schema, but `user_version` is simpler, built into SQLite, and sufficient for the single one-time cleanup needed here. The comment in code explains the 0→1 progression clearly.

- **`boolean` instead of `number` (changes count)**: Returning `boolean` is a cleaner public API for callers who just need to know "did this work?" without coupling them to SQLite row-change semantics. The `changes > 0` conversion is done internally.

- **`rowid ASC` tiebreaker**: `rowid` is SQLite's implicit row identity, always monotonically increasing per insert order. This is the correct tiebreaker for insertion-ordered queries — more reliable than any application-level counter.

## Known Limitations

- `markMessageRead` marking a message that is already read returns `true` (the row exists and the UPDATE runs), not a "no-op" signal. This is acceptable — callers rarely need to distinguish "marked newly read" from "was already read".
- The `delete()` method in `MailClient` still has no ownership enforcement by design (trust-boundary rationale documented). Future work could add a sender/recipient filter if stricter scoping is needed.
