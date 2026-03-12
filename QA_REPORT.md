# QA Report: Inter-agent messaging system (SQLite mail)

## Verdict: PASS

## Test Results
- Test suite (messaging-related files): 47 passed, 0 failed
  - `src/lib/__tests__/mail.test.ts`: 18 passed (13 original + 5 new edge-case tests)
  - `src/lib/__tests__/store.test.ts`: 29 passed (11 new messaging tests + 1 migration guard test + 17 existing)
- Overall suite: 259 passed, 9 failed
  - The 9 failures are **pre-existing infrastructure issues** unrelated to the messaging work (missing `tsx` binary in worktree `node_modules/.bin`, CLI build unavailable in sandbox). These failures existed on the base branch before any messaging changes (verified by `git stash` test run which showed 22 failures / 230 passing).
- New tests added: 5 (edge cases in `mail.test.ts`)

## Implementation Summary

The developer implemented:

1. **`src/lib/store.ts`** — Added `Message` interface, `messages` table DDL (`MESSAGES_SCHEMA`), two covering indexes, and a versioned migration guard (`SCHEMA_VERSION = 1`) using SQLite `user_version` pragma to ensure legacy tables are dropped only once. New store methods:
   - `sendMessage()` — inserts a message, returns the `Message` record
   - `getMessages()` — retrieves messages for a recipient, with optional `unreadOnly` filter
   - `getAllMessages()` — retrieves all non-deleted messages in a run (for lead visibility)
   - `markMessageRead()` — marks a single message read, returns `boolean`
   - `markAllMessagesRead()` — bulk-marks all messages for an agent as read
   - `deleteMessage()` — soft-delete (sets `deleted_at`), returns `boolean`
   - `getMessage()` — fetch a single message by ID (returns soft-deleted records too — intentional for audit)

2. **`src/lib/mail.ts`** — New `MailClient` class providing an agent-scoped higher-level API wrapping the store methods. Key design: `MailClient.markRead()` returns `void` (unlike `store.markMessageRead()` which returns `boolean`).

3. **`src/lib/__tests__/store.test.ts`** — 12 new tests covering all store messaging methods including the migration guard (verifies messages persist across store re-open).

4. **`src/lib/__tests__/mail.test.ts`** — 13 original tests + 5 new edge-case tests.

## Issues Found

No correctness issues or regressions in the messaging implementation. One test authoring issue was caught and fixed:

- **Edge case test (self-corrected)**: Initial draft of `markRead on soft-deleted message` incorrectly asserted the return value of `MailClient.markRead()` (which returns `void`) as `true`. Test was corrected to call `expect(() => devMail.markRead(msg.id)).not.toThrow()` and separately verify `store.markMessageRead()` returns `true` to confirm the row still exists.

## Notes

- The migration guard (`user_version` gating) correctly prevents the `DROP TABLE IF EXISTS messages` from running on subsequent store opens — verified by the persistence test.
- `getMessage()` intentionally returns soft-deleted records (audit trail); `getMessages()` and `allMessages()` correctly exclude them via `deleted_at IS NULL`.
- Message ordering uses `created_at ASC, rowid ASC` as a stable tie-breaker for concurrent inserts in the same millisecond — good design.
- No integration into `agent-worker.ts` or role prompts yet (out of scope for this task per explorer report's phased approach).

## Files Modified
- `/Users/ldangelo/Development/Fortium/foreman/.foreman-worktrees/foreman-3527/src/lib/__tests__/mail.test.ts` — Added 5 edge-case tests, corrected one test assertion
