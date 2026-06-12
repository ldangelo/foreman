# Documentation Report: Fix task status after PR creation and merge

## Verdict: PASS

## Documentation Updated

Earlier sessions (04-17, 04-42) already made required documentation updates:

- `docs/PRD/PRD-2026-006-multi-project-native-task-management.md` — REQ-018 section: updated terminal post-merge task status from `'merged'` to `'closed'` to match implementation. Also updated component replacement table reference and sprint completion criteria.

## Documentation Not Needed

- `CLAUDE.md` — No references to specific task status names that would conflict with the fix. Internal behavior changes (create-pr returning "review", post-merge using "closed") are consistent with existing documentation. The single "merged" reference (line 246) refers to git branch merge, not native task status.
- `AGENTS.md` — No references to task status names "merged" or "closed" in operator-facing context. Task lifecycle is described in terms of phase transitions, not specific status values.
- `README.md` — Describes task statuses in general terms (backlog, ready, in progress, needs attention, closed) without referencing "merged" as a native task status. Native status `review` correctly documented as "branch/PR is awaiting review or merge".
- `docs/user-guide.md` — Describes task statuses (backlog, ready, in progress, needs attention, closed) without referencing "merged" as a native task status. Board usage and status expectations are correctly documented.
- `docs/cli-reference.md` — Command documentation uses `foreman task close` for task closure, not `--status merged`. No update required.

## Summary

The fix corrects internal task status transitions to match already-documented behavior:

| Event | Previously (bug) | Now (fixed) | Already documented |
|-------|------------------|-------------|---------------------|
| PR created via create-pr phase | Status unchanged | → "review" | Yes (review = "branch/PR is awaiting review or merge") |
| PR created via finalize fallback | Status unchanged | → "review" | Yes (same) |
| PR merged | → "merged" (inconsistent) | → "closed" | Yes (closed = terminal) |

No new user-facing behavior was introduced. The implementation now matches the documented behavior.

## Checks

- Diff reviewed: yes
- User-facing behavior changed: no (implementation now matches already-documented behavior)
- Workflow/prompt behavior changed: no
- PRD/TRD updated by prior session: yes