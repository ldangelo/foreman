# Repo-rules review — beads:foreman:foreman-pjugt

## 1. Review engine

- **Reviewer**: the `repo-rules-review` phase agent for run `run-cc5d8c302b868df6e32a76c61e7a74c3` (phase 4 of 4). A single in-process review pass against this repository's own rules — no external CLI, no CodeRabbit round.
- **Diff range reviewed**: `FOREMAN_BASE_BRANCH=main` (set), so `git diff main...HEAD` = `git diff 796c888c75c4f5a6dbf33b09027d31fea9af7b1f...705d2909` — 5 files, 336 insertions, 0 deletions:
  - `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex` (+13)
  - `packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs` (+113)
  - `docs/reports/foreman-beads:foreman:foreman-pjugt/PLAN.md` (+187)
  - `docs/reports/foreman-beads:foreman:foreman-pjugt/FIX_REPORT.md` (+2)
  - `docs/reports/foreman-beads:foreman:foreman-pjugt/REVIEW_CODERABBIT_REPORT.md` (+21)
  - Plus this phase's own uncommitted change: `CLAUDE.md` (+1 bullet, section 18).
- **Rules applied, in this order**: `AGENTS.md` (working rules 1–4, §5 typed boundaries, documentation gate, invariants), `CLAUDE.md` (durable architecture conventions, §17 BeadsDbLease, §18 per-project run slots), `docs/lessons/*` (architecture-and-events, phase-execution-and-pr-mechanics, typed-boundaries-full), then the established patterns of the code the diff touches.
- **Carried-forward findings**: the previous phase's `REVIEW_CODERABBIT_REPORT.md` in the same directory contains prose only — it has no `FOREMAN_REVIEW_FINDINGS` block, so there is no findings array to carry forward.
- **Not reviewed / limits** (stated rather than silently skipped):
  - The **BeadsDbLease promotion path** (`re_dispatch_promoted/3`, `dispatcher.ex:1725`) has the same defect this diff fixes for run-slot promotion: it starts a run for a task that is no longer startable. It is out of this run's scope (`PLAN.md` scopes the change to the run-slot promotion path) and is tracked in `beads:foreman:foreman-tepov`. Declined as F4.
  - The pre-existing clause `[%{acknowledged_run_id: ^run_id} | _]` in `start_promoted_run/2` is unreachable: `ProjectionStore.tasks_by_run_id/1` filters out tasks whose `acknowledged_run_id` equals the run. Pre-existing dead code, not created by this diff — left alone per `AGENTS.md` rule 4.
  - The `[]` branch of `start_promoted_run/2` (a task that was retried or terminated is no longer returned by `tasks_by_run_id/1`) logs `handle_slot_promoted: no task found for run …` and releases neither slot nor waiter. Pre-existing behaviour, outside this diff.
  - The three report files under `docs/reports/foreman-beads:foreman:foreman-pjugt/` are earlier-phase artifacts; they were checked for consistency with the code, not treated as behaviour.

## 2. Findings

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| F1 | minor | `CLAUDE.md` §18 documents run-slot promotion as capacity-driven only; the diff adds a task-status gate to promotion and nothing in the repository documented that behavior. | **fixed** |
| F2 | minor | `dispatcher.ex:1438` — `@non_startable_task_statuses` duplicates the task-status vocabulary the Task aggregate already owns (`aggregates/task.ex:46` `@valid_statuses`). | **declined** |
| F3 | nitpick | `dispatcher_slot_promoted_test.exs:190`/`:248` — raw `:meck.new(ForemanServer.CommandGateway, …)` instead of the repository's `ForemanServer.TestSupport.MeckScope` helper. | **declined** |
| F4 | minor | `dispatcher.ex:1725` — the BeadsDbLease promotion path (`re_dispatch_promoted/3`) still starts a run for a task that is no longer startable. | **declined** |

## 3. Fixed

**F1 — `CLAUDE.md` (section 18, new bullet after line 1020)**

- **What was wrong**: the diff changes when a promoted run starts — a run whose task was closed, failed or blocked while it waited for a slot is now skipped and its slot handed back. `CLAUDE.md` §18 ("Per-project run slots") is the repository's durable architecture-conventions file for exactly this mechanism, and it described promotion only as capacity-driven ("Release promotes only below capacity."). `README.md`, `docs/user-guide.md` and `docs/cli-reference.md` contain no run-slot-promotion coverage at all (`grep -c promot` → 0 in the two `docs/` files; the two `README.md` hits are about the unrelated BeadsDbLease path, which this diff does not touch). So the new behavior had no documentation anywhere, which `AGENTS.md`'s documentation gate treats as a defect of the diff.
- **What changed**: one bullet added to §18, no other line touched:

  > `- **Promotion re-reads the task.** A promoted run starts only while its task is still startable; a task that was closed, failed or blocked while its run waited for a slot is skipped — the slot is released and the waiter removed, never a run for a dead task (`Workflow.Dispatcher.start_promoted_run/2`). Task status changes move only the status, never `acknowledged_run_id`, so the check happens at slot handoff rather than at approval time.`

  The wording matches the diff exactly: the statuses are the ones in `@non_startable_task_statuses` (`closed`, `failed`, `blocked`), the outcome is slot release + waiter removal via `terminate_slot/2`, and the reason for re-reading at handoff is the fact that task status events never move `acknowledged_run_id`.

## 4. Declined

- **F2 — `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex:1438`**: `@non_startable_task_statuses ~w(closed failed blocked)` restates a vocabulary the `Task` aggregate already owns at `aggregates/task.ex:46` (`@valid_statuses`), so the two lists can drift. Declined: the repository already keeps three parallel copies of the task-status vocabulary (`aggregates/task.ex:46`, `task_providers/beads_orphan_janitor.ex:139` terminal set, `mcp/tools.ex:823`), no repository rule designates one canonical list, and the aggregate's list is a private module attribute — exposing it would add public API that this diff does not need. The duplicated list is also *narrower* than the aggregate's on purpose: it lists statuses that must not start a run, not the full vocabulary.
- **F3 — `packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs:190`**: the new tests mock `CommandGateway` with a raw `:meck.new/2` rather than `ForemanServer.TestSupport.MeckScope`. Declined: no repository rule mandates `MeckScope` (26 test files use it, 30 use raw `:meck.new`), and the same file already mocks `RunAdmission`/`RunSupervisor` with raw `:meck.new` at lines 43–44, so the new code matches the surrounding established pattern.
- **F4 — `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex:1725`**: `re_dispatch_promoted/3` (BeadsDbLease promotion) starts the promoted run without re-reading the task status, so a lease-promoted run can still start for a closed task. Declined: it is the same class of defect but a different promotion path than the one this run changed; `PLAN.md` scopes the change to run-slot promotion, and the lease path is tracked as `beads:foreman:foreman-tepov`. Fixing it here would be work outside this run's scope.

## 5. Verification

Commands run from the run worktree (`/Users/ldangelo/.foreman/worktrees/foreman/foreman-pjugt/run-cc5d8c302b868df6e32a76c61e7a74c3/workspace`); `mix.exs` is per-package, so each runs with an inner `cd packages/foreman_server`.

| Command | Exit code | Result |
| --- | --- | --- |
| `devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/foreman_test_pjugt MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/dispatcher_slot_promoted_test.exs'` | 0 | `Result: 10 passed` — the file the diff touches |
| `devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=… MIX_ENV=test mix test --warnings-as-errors test/foreman_server/aggregates/task_test.exs test/foreman_server/aggregates/run_slots_test.exs test/foreman_server/aggregates/run_slots_promote_test.exs test/foreman_server/aggregates/run_slots_release_test.exs'` | 0 | `Result: 108 passed` — aggregates the diff's guard depends on |
| `devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted lib/foreman_server/workflow/dispatcher.ex test/foreman_server/workflow/dispatcher_slot_promoted_test.exs'` | 0 | formatter clean |
| `devbox run -- bash -c 'cd packages/foreman_server && mix credo --min-priority higher lib/foreman_server/workflow/dispatcher.ex test/foreman_server/workflow/dispatcher_slot_promoted_test.exs'` | 0 | `131 mods/funs, found no issues` (same invocation as `.github/workflows/ci.yml`) |
| `git diff --stat $(git merge-base main HEAD)...HEAD` | 0 | 5 files, 336 insertions — the range reviewed |
| `git status --short` | 0 | `M CLAUDE.md` (this phase's fix) + the untracked report — nothing committed, as the phase requires |

The first two commands were run before the fix and re-run after it; both runs exited 0 with the same counts. `CLAUDE.md` is documentation only, so no code path was changed by this phase — the re-read of the diff after the fix confirmed the only new hunk is the single documentation bullet above.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "minor", "path": "CLAUDE.md", "line": 1021, "description": "The diff changed run-slot promotion semantics (a promoted run is skipped and its slot released when the task is closed, failed or blocked) without updating CLAUDE.md section 18, the repository's durable architecture conventions for per-project run slots.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex", "line": 1438, "description": "The new @non_startable_task_statuses list restates the task-status vocabulary the Task aggregate already owns at aggregates/task.ex:46, so the two lists can drift apart.", "disposition": "declined", "source": "repo-rules"}, {"severity": "nitpick", "path": "packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs", "line": 190, "description": "The new tests mock CommandGateway with a raw :meck.new call instead of the repository's ForemanServer.TestSupport.MeckScope helper.", "disposition": "declined", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex", "line": 1725, "description": "The BeadsDbLease promotion path re_dispatch_promoted/3 still starts a run for a task that is no longer startable, so the defect this diff fixes for run-slot promotion still exists on the lease path.", "disposition": "declined", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The change makes run-slot promotion skip starting a run when the task is closed, failed or blocked, so it touches when runs start rather than only how they run; the guard is narrow, covered by 10 passing tests plus 108 aggregate tests, and the promotion rule is now documented in CLAUDE.md section 18. Residual risk is limited to the deferred BeadsDbLease promotion path, which still lacks the same guard."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
