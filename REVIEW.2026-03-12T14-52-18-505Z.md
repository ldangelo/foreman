# Code Review: Task groups for batch coordination

## Verdict: FAIL

## Summary

The implementation adds a solid data model layer (schema, CRUD, types) and a working `dispatchGroups()` method with parent-based grouping, parallel/sequential coordination, and proper agent-limit enforcement. Tests pass cleanly for all new code (17 new tests, 9 pre-existing unrelated failures). However, there are two WARNING-level issues: the `ungrouped` field in `GroupedDispatchResult` is always empty and misleading (real ungrouped beads are included in `groups` as a named group), and a new group DB record is created on every `dispatchGroups()` call with no deduplication check, causing duplicate group rows on repeated runs. There is also a dead variable and a minor sequential-mode edge case worth noting.

## Issues

- **[WARNING]** `src/orchestrator/types.ts:86` / `src/orchestrator/dispatcher.ts:356-361` — `GroupedDispatchResult.ungrouped` field is always an empty `DispatchResult` (zero dispatched, zero skipped, zero resumed). Beads with no parent are collected under the `null` key and emitted as a `"ungrouped"` group inside `groups[]`, not in `ungrouped`. The field is also unused at the call site in `run.ts`. This is misleading to future consumers and wastes interface space. The field should either be removed, or the actual ungrouped beads should be moved into it consistently.

- **[WARNING]** `src/orchestrator/dispatcher.ts:267-273` — A new `task_groups` DB row is created on every non-dry-run invocation of `dispatchGroups()` for each group key found in the ready list. There is no lookup to check whether a group for that parent already exists. Running `foreman run --group-mode parallel` twice in succession (e.g., the watch-loop continuation path) creates duplicate group rows for the same parent, making `listGroups()` and group-status tracking unreliable. The fix is to query for an existing pending/running group with the same `name` + `project_id` before inserting.

- **[NOTE]** `src/lib/store.ts:330` — `const statuses = new Set(runs.map((r) => r.status));` is computed but never read. The subsequent logic uses `runs.every(...)` directly. Dead variable; should be removed.

- **[NOTE]** `src/orchestrator/dispatcher.ts:250` — Sequential mode checks `totalDispatched > 0` (tasks dispatched in the current call only). If there are pre-existing active runs from a prior batch (`activeRuns.length > 0`), sequential mode still proceeds to dispatch the first group in the new call. This may be intentional, but it is inconsistent with the stated semantics of "each group must fully complete before the next one starts." Consider checking `activeRuns.length > 0 || totalDispatched > 0` for stricter enforcement.

- **[NOTE]** `src/cli/commands/run.ts:97-100` — Runtime string validation of `--group-mode` is done manually after the cast to `GroupCoordinationMode`. Commander's `.choices()` method would provide declarative validation and proper help text without a manual check.

## Positive Notes

- Data model follows existing store patterns exactly: prepared statements, `randomUUID()`, `DEFAULT NULL` migrations, FK constraints — no shortcuts taken.
- `syncGroupStatus()` correctly handles all terminal run states (`merged`, `pr-created`, `conflict`, `test-failed`, `stuck`) and introduces a useful `"partial"` status for mixed outcomes.
- Test coverage is thorough: all `syncGroupStatus` edge cases are covered, group CRUD round-trips are verified, and dispatcher dry-run tests clearly validate grouping, agent limits, sequential blocking, and coordination-mode propagation.
- Existing tests (`watch-ui`, `monitor`) were properly updated with the new `group_id: null` field with no regressions.
- `dispatchGroups()` is an entirely additive, opt-in code path — non-group-mode behavior is unchanged.
- TypeScript compiles cleanly with no errors.
