# CodeRabbit review report — beads:foreman:foreman-laju1 (run-ea2a2369059c083d826f0a32d81edd98)

## Review engine

```
coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"
```

with `FOREMAN_BASE_BRANCH=main` (the branch this run was cut from; it was set
and non-empty, so the review ran against the correct range). The command was
run from the worktree root
`/Users/ldangelo/.foreman/worktrees/foreman/foreman-laju1/run-ea2a2369059c083d826f0a32d81edd98/workspace`
with CodeRabbit CLI 0.9.6 on `PATH`; it exited `0` in every round and produced
findings against the working tree, so no round was skipped for engine reasons.
Three rounds were run (the maximum allowed).

## Rounds

### Round 1 — 1 finding

- **minor** `docs/reports/foreman-beads:foreman:foreman-laju1/FIX_REPORT.md:1` —
  "Complete the fix report."
  The file contained a single chat reply ("I'll start by reading the plan."),
  not a report. → **Fixed** (rewritten; see *Fixed*).

### Round 2 — 1 finding

- **major** `docs/reports/foreman-beads:foreman:foreman-laju1/PLAN.md:3` —
  "Restore the plan content that this artifact describes, and correct its line
  count."
  The committed plan was 12 lines of chat summary while describing itself as a
  273-line plan; the original text survived in git history. → **Fixed**
  (restored from `git show c5e41c70:…PLAN.md`, 273 lines).

### Round 3 — 3 findings

- **minor** `docs/reports/foreman-beads:foreman:foreman-laju1/PLAN.md:255` —
  "Unset `DATABASE_URL` in the full validation command too." → **Fixed**.
- **minor** `docs/reports/foreman-beads:foreman:foreman-laju1/FIX_REPORT.md:5-7` —
  "Update the report to match the supplied implementation." → **Fixed**.
- **major** `packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs:356` —
  "Unload the `CommandGateway` mock in the test that creates it." → **Fixed**
  (and it was the most consequential finding of the review: the leak broke 168
  unrelated tests in the first full-suite attempt).

### Stopping condition

Round 3 was the third and last allowed round. No finding was left unfixed, so
nothing remains open from CodeRabbit.

## Fixed

1. `docs/reports/foreman-beads:foreman:foreman-laju1/FIX_REPORT.md`
   - Wrong: the "fix" artifact was a one-line chat reply instead of a report,
     so the phase produced no evidence of what had been done.
   - Changed: rewritten as a real report (status, per-item verdicts for the
     three requested regression tests, verbatim red-then-green output, the
     validation commands, the documentation-gate note, environment caveats).
     Rewritten again in round 3 to match the implementation that is now on the
     branch.
2. `docs/reports/foreman-beads:foreman:foreman-laju1/PLAN.md`
   - Wrong: a truncated commit had replaced the 273-line plan with 12 lines of
     chat summary, so the plan no longer described the work.
   - Changed: restored verbatim from git history
     (`git show c5e41c70:docs/reports/foreman-beads:foreman:foreman-laju1/PLAN.md`),
     and the full-gate command in its validation section now unsets
     `DATABASE_URL` (round 3).
3. `packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs:356`
   - Wrong: the new test created `:meck.new(ForemanServer.CommandGateway,
     [:no_link])` and never unloaded it. Because a `:no_link` meck mock replaces
     the module globally, every later test that called a `CommandGateway`
     function the mock did not stub failed with
     `** (UndefinedFunctionError) function ForemanServer.CommandGateway.dispatch_operator/1 is undefined or private`.
     The first full-suite attempt failed 168 unrelated tests because of it.
   - Changed: `[:passthrough, :no_link]` plus
     `on_exit(fn -> :meck.unload(ForemanServer.CommandGateway) end)`, matching
     the convention already used in `dispatcher_slot_release_test.exs:44`,
     `dispatcher_slot_rebalance_test.exs:193` and
     `run_admission_slot_gate_test.exs:226`.

## Declined

None — every CodeRabbit finding in all three rounds was legitimate against the
code as it stood and was fixed.

## Verification

```
devbox run -- bash -c 'cd packages/foreman_server && export DATABASE_URL="postgres://postgres:postgres@127.0.0.1:55432/foreman_test_laju1" && MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/dispatcher_slot_promoted_test.exs test/foreman_server/mcp/tools_test.exs'
```
exit 2 — `Result: 37/39 passed`, `Failed: 2 tests`: the two new regression tests
failed for the right reason (behaviour missing, not a broken test):

- `test RunSlotTransferred with failed admission logs warning does NOT admit a promoted run whose task was closed, and drops its slot (ForemanServer.Workflow.DispatcherSlotPromotedTest)` —
  `test/foreman_server/workflow/dispatcher_slot_promoted_test.exs:338`,
  "a closed task must not have its queued run admitted",
  code `refute :meck.called(ForemanServer.RunAdmission, :start, :_)`
- `test foreman_run_status returns the queued pending projection instead of NOT_FOUND for a run waiting on a slot (ForemanServer.MCP.ToolsTest)` —
  `test/foreman_server/mcp/tools_test.exs:346`,
  `match (=) failed`,
  `right: {:error, %ForemanServer.MCP.ToolError{code: "NOT_FOUND", message: "Run not found"}}`

```
devbox run -- bash -c 'cd packages/foreman_server && export DATABASE_URL="postgres://postgres:postgres@127.0.0.1:55432/foreman_test_laju1" && MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/dispatcher_slot_promoted_test.exs test/foreman_server/mcp/tools_test.exs test/foreman_server/command_gateway_cancel_queued_run_test.exs'
```
exit 0 — `Result: 44 passed`, `ProjectionLeakGuard: judged 3 of 3 modules, no run left behind`
(re-run after the round-3 mock-unload fix).

```
devbox run -- bash -c 'cd packages/foreman_server && mix format'
```
exit 0 — no reformat diff in the changed files.

```
devbox run -- bash -c 'cd packages/foreman_server && export DATABASE_URL="postgres://postgres:postgres@localhost:55432/foreman_test_laju1" && MIX_ENV=test mix test --warnings-as-errors'
```
exit 0 — `Finished in 1380.3 seconds (57.1s async, 1323.1s sync)`,
`Result: 9172 passed (8 properties, 9164 tests), 11 excluded`,
`ProjectionLeakGuard: judged 355 of 553 modules, no run left behind`.

An earlier full-suite run of the same tree exited 2 with
`Result: 9169/9172 passed` and three failures, none of them caused by this
change:

- `ForemanServer.ConfigTest` "dev env (TRD-022) EventStore reads DATABASE_URL
  with localhost default" and the same for `Repo`
  (`packages/foreman_server/test/foreman_server/config_test.exs:73` and `:87`,
  `assert url =~ "localhost"`) — that run pointed `DATABASE_URL` at
  `127.0.0.1:55432`, so the dev-env default could not contain `localhost`. The
  passing run above uses `localhost`.
- `ForemanServer.ProjectMemory.StoreTest` "a write rejected by :index_full
  leaves the directory byte-identical" —
  `** (ExUnit.TimeoutError) test timed out after 60000ms` at
  `packages/foreman_server/test/foreman_server/project_memory/store_test.exs:106`
  (via `packages/foreman_server/lib/foreman_server/project_memory/store.ex:144`
  `read_raw/2` ← `store.ex:331` `list_entries/1` ← `store.ex:82` `write/3`).
  A file-I/O timeout under the load of a 9 000-test suite; it did not
  reproduce in isolation.

Both files were then re-run on their own with the same `DATABASE_URL`:
`Result: 21 passed`, exit 0 — that is how both were classified as
environmental rather than as defects in this change.

Environment notes: the ambient `DATABASE_URL` points at
`postgres://postgres:postgres@localhost:55434/foreman_dev` and makes `mix test`
fail with `FATAL 28P01` (`mix.exs:203 claim_database!/2`), so it is overridden
above. That same function claims the test database with a Postgres advisory
lock, and the lock is per database: a concurrent Foreman run held
`foreman_test`, so this run used its own database
`postgres://postgres:postgres@127.0.0.1:55432/foreman_test_laju1` (schema
replicated from `foreman_test`).

## Changes reviewed

The branch diff reviewed by CodeRabbit covers the implementation this phase
fixed alongside the earlier phases' work:

- `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex` —
  `start_promoted_run/2` gained a clause that refuses to promote a run whose
  task is `closed`/`failed`/`merged`, releasing the slot and dropping the
  waiter instead.
- `packages/foreman_server/lib/foreman_server/mcp/tools.ex` —
  `tool_foreman_run_status/1` falls back to the pending projection, so a run
  waiting for a slot reports `status: "queued"`, `terminal: false` and
  `current_phase: nil`; `NOT_FOUND` now means "unknown run id".
- `packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs` —
  new test for the closed-task case.
- `packages/foreman_server/test/foreman_server/mcp/tools_test.exs` —
  new test for the queued-status case.
- `docs/cli-reference.md`, `docs/user-guide.md`, `CLAUDE.md` — behaviour
  sentences only; no command, event, MCP tool, route, CLI verb, env var,
  config key, workflow or prompt name was added, removed or renamed.
- `docs/reports/foreman-beads:foreman:foreman-laju1/{PLAN,FIX_REPORT}.md` —
  the plan artifact restored and the fix report written.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-laju1/FIX_REPORT.md", "line": 1, "description": "The fix report contained only a chat reply instead of a report of the work.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "docs/reports/foreman-beads:foreman:foreman-laju1/PLAN.md", "line": 3, "description": "The plan artifact was a truncated chat summary that no longer described the work.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-laju1/PLAN.md", "line": 255, "description": "The plan's full validation command did not unset DATABASE_URL, so it cannot succeed in this environment.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-laju1/FIX_REPORT.md", "line": 5, "description": "The fix report did not match the implementation now present in the branch.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/test/foreman_server/workflow/dispatcher_slot_promoted_test.exs", "line": 356, "description": "The new test created a CommandGateway meck mock without unloading it, which broke 168 unrelated tests with UndefinedFunctionError on dispatch_operator/1.", "disposition": "fixed", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The change touches the slot-promotion path and the MCP run-status boundary: a closed task now drops its queued run instead of admitting it, and foreman_run_status reports queued runs instead of NOT_FOUND. Both are covered by new failing-first tests and the full suite, and the one severe defect this run introduced (a leaked meck mock that broke 168 unrelated tests) was found and fixed before the final validation. Remaining risk is behavioural drift in the promotion path for tasks that already carry a terminal status."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
