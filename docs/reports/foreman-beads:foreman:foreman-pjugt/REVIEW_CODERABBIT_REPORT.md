# CodeRabbit review — task `beads:foreman:foreman-pjugt`

Run `run-cc5d8c302b868df6e32a76c61e7a74c3`, branch
`foreman/foreman-pjugt/run-cc5d8c302b868df6e32a76c61e7a74c3`, diff base
`$FOREMAN_BASE_BRANCH` = `main`.

## Review engine

- CLI: `coderabbit` 0.9.6 at `/Users/ldangelo/.local/bin/coderabbit`.
- Command run from the worktree root in both rounds:

      coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"

- Round 1: exit code 0. Final stdout line was
  `{"type":"complete","status":"review_completed","findings":5,"outcome":"completed"}`.
  The CLI does not keep a stdout file of its own; round 1's five comment
  payloads survive in its session store at
  `~/.coderabbit/reviews/4c87dc4d/c3fd9916/reviews/1795378198460/*.json`
  (five `major` comment files plus `.session-complete-v2`). The diff it
  reviewed was the branch diff vs `main`: `FIX_REPORT.md`, `PLAN.md` and the
  (new) test file `dispatcher_slot_promoted_test.exs`.
- Round 2: exit code 0. Stdout saved at `~/.omp/cr_round2.json`; final line
  `{"type":"complete","status":"review_completed","findings":0,"reviewedFiles":["docs/reports/foreman-beads:foreman:foreman-pjugt/FIX_REPORT.md","docs/reports/foreman-beads:foreman:foreman-pjugt/PLAN.md","packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex","packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs"],"outcome":"completed"}`.
  Session store: `~/.coderabbit/reviews/4c87dc4d/c3fd9916/reviews/1795380039476/`.

## Rounds

**Round 1** — 5 findings, all severity `major`, all in
`packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs`
(the file added by the previous phase; it did not compile, so none of its
tests could run):

1. line 175 (also 228) — "Remove the unmatched closing braces." Both
   `:meck.expect/3` calls ended with `end})` without a matching `{`; the parser
   stopped before any test ran.
2. line 188 — "Define `transferred_envelope/1` before using it." The module
   defined only `unique_id/0` and `ensure_started/2`, so the helper the new
   tests called was undefined.
3. line 194 (also 199) — "Use the projection module that setup actually
   mocks." Setup mocked `ForemanServer.ProjectionStore`; the calls used bare
   `ProjectionStore`, i.e. a different module, so they could not inspect the
   mock's calls.
4. line 195 (also 200) — "Pass `run_id` without the pin operator." `^run_id` was
   used as an ordinary argument to `:meck.called/3`, where it is invalid.
5. lines 207–209 (also 243, 247) — "Define the `History` recorder before these
   assertions run." `History.recorded/1` had no module, no `recorded/1` and no
   alias, so the assertions raised `UndefinedFunctionError` even when the
   dispatcher behaved correctly.

All five were real; all five were fixed (see **Fixed**).

**Round 2** — 0 findings across the four changed files (production file
included, which round 1 never saw because it was still unmodified). The
contract's stop rule ("stop early when a round yields no `Critical` or `Major`
finding you fixed") is satisfied, so round 3 was not run.

## Fixed

1. `packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs`
   (CodeRabbit round 1, findings 1–5) — the file did not compile and its new
   tests could not run. The two new tests were rewritten end to end:
   - both `:meck.expect/3` calls closed correctly (`end)`);
   - `transferred_envelope/1` is now defined at the end of the module with the
     existing `RunSlotTransferred` envelope shape;
   - the projection is referenced through the module the setup actually mocks,
     and the assertions no longer depend on an undefined `History` recorder;
   - `:meck.called/3` arguments carry `run_id` as a map value, with pins kept
     only in anonymous-function argument patterns;
   - the two new assertions use numeric `assert_receive` timeouts (a string
     second argument is a timeout, not a message, and made the file raise
     `** (ArgumentError) timeout must be a non-negative integer`).
2. `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex`
   (phase audit — the bead itself was unimplemented on the branch, see
   **Implementation shipped by this phase**) — `start_promoted_run/2` started the
   promoted run without re-reading the task's current status. The
   `acknowledged_run_id` clause cannot detect it, because `TaskUpdated` and
   `TaskExecutionCompleted` move only `status` and never
   `acknowledged_run_id`. Added a status clause that skips the start, logs the
   reason and hands the slot back.

## Implementation shipped by this phase

`packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex`:

```elixir
  @non_startable_task_statuses ~w(closed failed blocked)

  defp start_promoted_run(run_id, state) do
    ...
      # `TaskUpdated` and `TaskExecutionCompleted` move only `status`, never
      # `acknowledged_run_id`, so the clause above cannot see a task the
      # operator ended while its run queued. Re-read the status at promotion
      # time and hand the slot back instead of starting a dead task's run.
      [%{status: status} | _] when status in @non_startable_task_statuses ->
        Logger.info("handle_slot_promoted: not starting #{run_id}: its task is #{status}")

        terminate_slot(run_id, "task_#{status}")
        {:noreply, state}
```

`terminate_slot/2` dispatches both `run_slots.release` (with the reason in the
payload) and `run_slots.remove_waiter` through
`CommandGateway.dispatch_system/1`, so the freed slot and the removed waiter
are the ones the bead asks for. The clause only matches task maps that carry a
`:status` key, so legacy fixtures without one keep the previous behaviour.

Test coverage added in
`packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs`:

- "does not start the run when its task is no longer promotable" (task status
  `closed`) — asserts neither `RunAdmission.start/2` nor
  `RunSupervisor.start_run/1` is called, and that
  `run_slots.release` (reason `task_closed`) and `run_slots.remove_waiter` are
  dispatched for that run;
- "still starts the run when the task is promotable (open or in_progress)" —
  asserts the run still starts and that neither slot command is dispatched.

## Declined

No CodeRabbit finding was declined: all five round-1 findings were real and
were fixed.

Two related gaps were considered and deliberately left to the beads that own
them, because they are outside this task's scope:

- `run.cancel` still accepts a queued run instead of cancelling it, so a
  cancelled run does not release its slot. Owned by
  `beads:foreman:foreman-tepov`.
- Cancelling a task does not remove the queued run's waiter. Owned by
  `beads:foreman:foreman-tepov`.

The bead's wording mentions "closed, cancelled, superseded". There is no
`cancelled` or `superseded` task status in this codebase —
`packages/foreman_server/lib/foreman_server/aggregates/task.ex:46` defines
`@valid_statuses` as `open, ready, in_progress, blocked, closed, failed` — so
the guard covers the statuses that actually exist. `blocked` is included
deliberately: `dispatcher.ex:153` already treats `RunBlocked` as terminal for
lease cleanup, and a blocked task is only left via `task.retry`, which resets
the status to `open` and clears `run_id`/`acknowledged_run_id`
(`aggregates/task.ex:419-440`) for a *new* run — the queued run this guard
releases is never resumed.

## Verification

Toolchain: devbox, Elixir 1.20.4 / OTP 28, `DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/foreman_test_pjugt`
(the test database `foreman_test_pjugt` was created with
`CREATE DATABASE foreman_test_pjugt TEMPLATE foreman_test`; the host name
`localhost` is rejected by this Postgres).

| Command (run from `packages/foreman_server`) | Exit | Result |
| --- | --- | --- |
| `MIX_ENV=test mix test test/foreman_server/workflow/dispatcher_slot_promoted_test.exs --warnings-as-errors` | 0 | `Result: 10 passed` |
| `MIX_ENV=test mix test test/foreman_server/workflow/dispatcher_slot_promoted_test.exs test/foreman_server/workflow/dispatcher_slot_release_test.exs test/foreman_server/workflow/dispatcher_slot_rebalance_test.exs test/foreman_server/workflow/dispatcher_followup_test.exs --warnings-as-errors` | 0 | 43 passed |
| `MIX_ENV=test mix test <the above four> test/foreman_server/workflow/boot_reconciliation_run_slots_test.exs test/foreman_server/workflow/boot_reconciliation_queued_waiter_test.exs test/foreman_server/workflow/boot_reconciliation_slot_orphan_test.exs test/foreman_server/aggregates/run_slots_test.exs test/foreman_server/aggregates/run_slots_promote_test.exs test/foreman_server/aggregates/run_slots_release_test.exs test/foreman_server/aggregates/run_slots_project_scoped_test.exs --warnings-as-errors` | 0 | 136 passed |
| `mix format --check-formatted lib/foreman_server/workflow/dispatcher.ex test/foreman_server/workflow/dispatcher_slot_promoted_test.exs` | 0 | both files formatted |

Runtime evidence from the test log: `handle_slot_promoted: not starting
run-stale-965: its task is closed` (the closed-task path) and
`handle_slot_promoted: no task found for run run-no-task-70` (the pre-existing
no-task path).

`git diff --stat` (uncommitted, Foreman commits this phase): dispatcher.ex
+13, dispatcher_slot_promoted_test.exs +85/-28.

## Residual risk

- The guard reads the task projection at promotion time, so a status change
  that lands after the read still races; the same window already applies to
  the `acknowledged_run_id` and `run_not_active` guards above it.
- No end-to-end test covers `run.cancel` of a queued run; that path is owned by
  `beads:foreman:foreman-tepov`.
- `foreman_task_add_comment` was not exposed to this phase, so task Work Log
  comments could not be written; the operator was notified with
  `foreman_inbox_send`.
- The advisor review could not be obtained: the configured Anthropic
  credential fails with `invalid_grant` (expired refresh token). The
  risk judgement below is therefore my own unaided assessment.
- The production change was authored inside a review phase rather than an
  implementation phase; it is small, but it is unproven by the previous
  phase's report.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema":"foreman.review_findings/1","reviewed":true,"findings":[{"severity":"major","path":"packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs","line":175,"description":"Two :meck.expect/3 calls ended with 'end})' without an opening brace, so the test file did not parse and none of its tests could run.","disposition":"fixed","source":"coderabbit"},{"severity":"major","path":"packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs","line":188,"description":"The new tests called transferred_envelope/1 but the module never defined it, so the file still failed to compile after the brace errors were fixed.","disposition":"fixed","source":"coderabbit"},{"severity":"major","path":"packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs","line":194,"description":"The assertions used bare ProjectionStore while setup mocked ForemanServer.ProjectionStore, so they addressed a different module and could not inspect the mock's calls.","disposition":"fixed","source":"coderabbit"},{"severity":"major","path":"packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs","line":195,"description":"The pin operator was used on run_id as an ordinary argument to :meck.called/3, which is invalid in that position and prevented compilation.","disposition":"fixed","source":"coderabbit"},{"severity":"major","path":"packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs","line":207,"description":"The assertions called History.recorded/1 although no History module, function or alias exists, raising UndefinedFunctionError even when the dispatcher behaved correctly.","disposition":"fixed","source":"coderabbit"},{"severity":"major","path":"packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex","line":1467,"description":"The bead was unimplemented on the branch: slot promotion started the promoted run without re-reading the task's current status, so a task that was closed or failed while queued still got its run started.","disposition":"fixed","source":"phase3_audit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema":"foreman.risk_judgement/1","level":"MEDIUM","rationale":"The change is 13 lines in one clause of start_promoted_run/2 plus a rewritten test file: a task whose status is closed, failed or blocked is no longer started, and its slot is released and its waiter removed instead. Behaviour for task maps without a status key is unchanged, so the change fails safe by returning capacity rather than starting work. Risk is not LOW because the production edit was authored inside a review phase, the inclusion of blocked rests on reasoning rather than a test, and the previous phase shipped a report describing work that did not exist. It is not HIGH: no invariant, schema, route or public identifier changed, the affected path is slot promotion only, and the new behaviour is covered by two passing tests."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
