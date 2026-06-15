# Documentation Report: Fix task status after PR creation and merge

## Verdict: PASS

## Documentation Updated

- `docs/PRD/PRD-2026-006-multi-project-native-task-management.md` — AC-018 section (REQ-018): Updated post-merge task status from `'merged'` to `'closed'` in acceptance criteria and component replacement table. Sprint 3 completion criteria updated to reflect "closed" terminal status.

- `docs/TRD/TRD-2026-006-multi-project-native-task-management.md` — TRD-011 and TRD-011-TEST sections: Updated implementation ACs and test descriptions to use `'closed'` instead of `'merged'`. Sequence description in section 4 updated.

## Documentation Not Needed

- `CLAUDE.md` — No operator/agent contract changes. Internal implementation details (create-pr returning "review", post-merge using "closed") are consistent with existing documentation. The single "merged" reference (line 246) refers to git branch merge, not native task status.

- `AGENTS.md` — No agent workflow, prompt, or instruction changes. Task lifecycle is described in terms of phase transitions, not specific status values.

- `README.md` — Already uses "closed" as the terminal task status (see `foreman task close` command examples). The fix aligns implementation with this existing documentation.

- `docs/user-guide.md` — Describes task statuses in general terms (backlog, ready, in progress, needs attention, closed) without referencing "merged" as a native task status. Board usage and status expectations are correctly documented.

- `docs/cli-reference.md` — Uses "closed" as the terminal task status in command examples. No update required.

- `docs/workflow-yaml-reference.md` — Document is about workflow configuration (phases, models, retries), not task status lifecycle. No update required.

## Notes

The implementation fix aligns with existing documentation:
- Task lifecycle (backlog → in-progress → review → closed) was already correctly documented
- "review" was already the expected status after PR creation
- "closed" was already the documented terminal status for merged runs
- Reconciliation behavior (repairing stale tasks) is an internal repair mechanism, not new user-facing behavior

The `src/defaults/prompts/default/finalize-bug.md` changes (target drift detection) are part of the same commit but represent a separate fix from the PR creation/merge status issue.

## Checks

- Diff reviewed: yes
- User-facing behavior changed: no — implementation aligned with existing documentation
- Workflow/prompt behavior changed: no — phase behavior unchanged; task status bookkeeping paths aligned
- Design doc accuracy restored: yes — PRD and TRD now match implementation