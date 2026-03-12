# Code Review: Task groups for batch coordination

## Verdict: PASS

## Summary

The implementation is clean, well-structured, and fully satisfies the requirements. Task groups are correctly implemented as a foreman-only coordination primitive stored in SQLite, with a dedicated `group-manager.ts` orchestration layer, proper CLI commands, and monitor integration. The schema migrations are applied correctly, idempotency is handled via `INSERT OR IGNORE`, error handling is defensive throughout, and 38 new tests pass cleanly with no regressions. One notable gap is that `Monitor.checkGroups()` is exposed but never wired into the `monitor` command or the `run` command's watch loop — auto-close works only when code explicitly calls `checkGroups()`, which nothing in the current codebase does. This is a functional gap but acceptable for an initial implementation if callers plan to invoke it manually or wire it later.

## Issues

- **[NOTE]** `src/cli/commands/monitor.ts:24` — `Monitor.checkGroups()` is implemented but never called from the `monitor` CLI command or the `run` watch loop. Auto-close of task groups will not fire during normal `foreman run` or `foreman monitor` usage. If background auto-close is the intended behavior (as described in the Explorer report), this needs to be wired into `monitor.ts`'s action handler (after `checkAll`) and/or into `run.ts`'s watch loop.

- **[NOTE]** `src/orchestrator/group-manager.ts:38` — Seed fetch failures during `checkAndAutoClose` silently treat the member as "not done" (`done: false`). This is the right safety default, but a group whose member seed was deleted will never auto-close. Acceptable for v1, but worth documenting.

- **[NOTE]** `src/cli/commands/group.ts:26` — The `group create` success output prints the group ID twice: once inline (`Created group <id>`) and once at the bottom (`Group ID: <id>`). Minor UX inconsistency.

- **[NOTE]** `src/lib/store.ts` (updateGroup) — `updateGroup` only permits updating `status` and `completed_at`. This is intentional by type signature but means `name` and `parent_seed_id` are immutable after creation. That's fine for v1 but worth noting if editing groups is later needed.

## Positive Notes

- Schema design is solid: `UNIQUE (group_id, seed_id)` constraint enforces idempotency at the DB layer, and `INSERT OR IGNORE` is the correct pattern to exploit it without application-level duplication checks.
- Both SCHEMA and MIGRATIONS are kept in sync — new tables appear in both, which is the correct pattern for this codebase (SCHEMA handles fresh installs, MIGRATIONS handles upgrades).
- GroupManager is properly isolated from the CLI: the CLI delegates to GroupManager, GroupManager delegates to store + seeds. Clean separation of concerns.
- `checkAndAutoClose` guards on `group.status !== "active"` first, making repeated calls safe without hitting the Seeds API unnecessarily.
- `getGroupStatus` gracefully handles missing seeds (returns `"unknown"` / `"(not found)"`) so `foreman group status` doesn't crash when a seed has been deleted.
- Tests cover all critical paths: empty group, partial completion, full completion, parent-seed close, idempotent re-close, null group, progress percentage math, and cross-project isolation.
- No breaking changes to any existing API surface.
