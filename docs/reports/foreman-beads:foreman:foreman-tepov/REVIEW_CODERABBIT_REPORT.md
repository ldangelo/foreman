# CodeRabbit Review — beads:foreman:foreman-tepov

Run: `run-64e944e0b6ab3b61eabc61b250737f9c` · Phase 3 (`fix` :: `coderabbit-review`) · 2026-11-22

## Review engine

Command run from the worktree root, repeated for each round:

```
coderabbit --version && coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"
```

- `$FOREMAN_BASE_BRANCH` = `main` (`796c888c`) — non-empty, so the phase was not blocked.
- Engine: CodeRabbit CLI `v0.9.6` at `/Users/ldangelo/.local/bin/coderabbit`. Every round exited `0`.
- Diff under review: `git diff --name-status main...HEAD` returns only
  `docs/reports/foreman-beads:foreman:foreman-tepov/FIX_REPORT.md` and
  `docs/reports/foreman-beads:foreman:foreman-tepov/PLAN.md`. **Zero code changes on this branch**, so the
  engine's `reviewedFiles` were the two report files. `code` findings it emitted therefore describe
  *pre-existing* code quoted in those reports, not code this run wrote.
- Round 5 also reported `Context skipped: GitHub app authentication unavailable — remote reviews disabled`.
  Local review still ran; noted for completeness.

## Rounds

**Round 1 — 1 finding, 1 fixed, 0 declined.**

| Severity | Location | Finding | Disposition |
| --- | --- | --- | --- |
| minor | `docs/reports/foreman-beads:foreman:foreman-tepov/FIX_REPORT.md:13` | "Reconcile the report with the plan": the committed report claims `6` files changed (`+352/−8`) and `9` tests added in a new `test/foreman_server/run_cancel_test.exs`, while `PLAN.md` §1/§5 on the same branch says the task was already implemented upstream and no test file was added; "Pick one account: either the task needed work and record the real diff, or it was already fixed and remove the false implementation claims." | **fixed** |

**Round 2 — 1 finding, 1 fixed, 0 declined.** (Round 1's fix had not yet been picked up by the working-tree
review because the run committed the truncated report; the engine re-raised the same contradiction at the
post-restore line number.)

| Severity | Location | Finding | Disposition |
| --- | --- | --- | --- |
| minor | `docs/reports/foreman-beads:foreman:foreman-tepov/FIX_REPORT.md:13` | "Record the deviation from the plan": report still asserted implementation work (`6` files / `+352/−8` / `9` new tests / `RunSlotQueue.cancel_queued/3`) contradicting `PLAN.md` §1 and §6. | **fixed** (same restore as round 1) |

**Round 3 — 2 findings, 0 fixed, 2 declined.** No Critical, no Major fixed → stop condition met. Two
further confirmatory rounds were run anyway to check the round-3 findings were stable and to catch
regression introduced by the report edit.

**Round 4 — 1 finding, 0 fixed, 1 declined** (restates round 3's retry finding as major at
`FIX_REPORT.md:36`).

**Round 5 — 2 findings, 1 fixed, 1 declined.**

| Severity | Location | Finding | Disposition |
| --- | --- | --- | --- |
| minor | `FIX_REPORT.md:36` | "Make a retried cancel complete the task acknowledgement" — same `command_gateway.ex` retry gap as rounds 3/4, downgraded to minor by the engine. | declined |
| minor | `FIX_REPORT.md:139` | "Reconcile the postscript's account of the truncated report": the postscript said `dfb441fe` replaced the report with the fragment *and* that no such commit existed on this branch — both cannot be true. | **fixed** |

## Fixed

1. `docs/reports/foreman-beads:foreman:foreman-tepov/FIX_REPORT.md` (rounds 1 and 2, minor). What was
   wrong: the report committed by `dfb441fe` was a truncated 14-line copy of the real phase-2 report, and
   the surviving fragment asserted implementation work that never happened — `6` files at `+352/−8`, a new
   `test/foreman_server/run_cancel_test.exs` with `9` tests, and `RunSlotQueue.cancel_queued/3` /
   `RunCancelAdapter`. None of those exist anywhere in this repository's history
   (`git cat-file -e HEAD:packages/foreman_server/test/foreman_server/run_cancel_test.exs` → exit 128;
   `git grep -l -E 'cancel_queued|run_cancel_test' $(git rev-list --all)` returns only the three beads
   ledger commits), and the diff under review contains no code at all. What changed: restored the real
   report body verbatim from `96f162d0` (`git cat-file -p
   '96f162d0:docs/reports/foreman-beads:foreman:foreman-tepov/FIX_REPORT.md'`), whose verdict is
   "Already fixed. No code change.", and appended a §7 postscript recording the fragment's provenance so
   the false claim is not silently deleted. §1–§6 are byte-for-byte the `96f162d0` version.
2. `docs/reports/foreman-beads:foreman:foreman-tepov/FIX_REPORT.md:139` (round 5, minor). What was wrong:
   the postscript attributed the fragment to `dfb441fe` and then said no such commit existed on the branch.
   What changed: named `dfb441fe` as the commit that replaced the report with the 14-line fragment (confirmed
   by `git show --stat dfb441fe` — one file, the report), and replaced the contradictory sentence with the
   direct evidence that the fragment is not real work: none of the artefacts it names exist in this
   repository's history.

## Declined

1. `packages/foreman_server/lib/foreman_server/command_gateway.ex` (round 3 major, `FIX_REPORT.md:36`) —
   "Cancelling a queued run can still start it after promotion": if slot promotion commits before the
   waiter removal, the removal is a no-op, the promotion event can be processed by the dispatcher before the
   `task.run_terminated` acknowledgement is applied, and `start_promoted_run/2` may start the run while the
   later `run_slots.release` frees a slot the started run still uses. **Declined — outside this run's
   scope.** The branch changed no code; this describes upstream code shipped in `6bb64a52` ("fix(server):
   cancelling a run that waits for a run slot removes it from the waiting list", PR #904) and reworked in
   `4099cce4` (#918), both ancestors of `main`. The phase-1 plan §6 explicitly scopes this task to
   "confirm the existing behaviour" and names `command_gateway.ex` as a file not to touch. The finding is
   also only half-true as written: `dispatcher.ex:1452`
   (`[%{acknowledged_run_id: ^run_id} | _] -> terminate_slot(run_id, "run_cancelled")`) plus
   `release_if_promoted/4` already close the common case, so acting on it needs a designed concurrency
   test, not the two-line reorder the finding implies. Recorded as unresolved so it reaches the operator.
2. `packages/foreman_server/lib/foreman_server/command_gateway.ex` (rounds 3 + 4 major, round 5 minor,
   `FIX_REPORT.md:36`) — "Make a retried queued-run cancel still acknowledge the bound task":
   `remove_slot_waiter_and_ack_task/4` removes the waiter before it acks, so if
   `ack_cancelled_queued_tasks/4` fails after the removal succeeded, a retried `run.cancel` finds no waiter,
   `cancel_queued_run/2` returns `:not_queued`, the command reaches the Run aggregate which has no state for
   a never-promoted run, and the task can stay `in_progress` bound to a run that will never start.
   **Declined — outside this run's scope, and the engine itself does not specify the fix.** Same upstream
   provenance (`6bb64a52`, PR #904); not this run's diff. Round 4 explicitly instructs "Keep the
   removal-before-acknowledgement order … The exact mechanism is left to the implementer", i.e. it asks for
   design work on the retry/idempotency path of a shipped PR rather than a local correction, which is a
   separate change. Recorded as unresolved.

## Verification

No `.ex`/`.exs`/`.go`/`.yaml` file was edited, so no formatter applies (`mix format` does not handle
Markdown). Commands run, with exit codes:

| Command | Exit | Result |
| --- | --- | --- |
| `coderabbit --version && coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` (rounds 1–5, five invocations) | 0 | 1, 1, 2, 1, 2 findings; `reviewedFiles` = the two report files |
| `devbox run -- bash -c 'unset DATABASE_URL; cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/command_gateway_cancel_queued_run_test.exs --warnings-as-errors'` | 0 | `Result: 5 passed`, no warnings |
| `devbox run -- bash -c 'unset DATABASE_URL; cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/command_gateway_cancel_queued_run_test.exs test/foreman_server/projection_store_run_slots_test.exs test/foreman_server/projection_store_queue_status_test.exs test/foreman_server/aggregates/run_slots_release_test.exs --warnings-as-errors'` | 0 | `Result: 56 passed`, no warnings |
| `git cat-file -e HEAD:packages/foreman_server/test/foreman_server/run_cancel_test.exs` | 128 | `fatal: path ... does not exist in HEAD` — confirms the restored report's negative claim |

`DATABASE_URL` is unset inside each test command because the worktree exports a `DATABASE_URL` pointing at
port `55434` that fails authentication; `config/test.exs` defaults to
`postgres://postgres:postgres@localhost:55432/foreman_test`, which is up. `git status --short` shows only
`M docs/reports/foreman-beads:foreman:foreman-tepov/FIX_REPORT.md` — fixes left uncommitted as instructed.

Documentation gate: this phase added, removed or renamed no externally visible identifier (no route, config
key, env var, CLI verb, MCP tool or command/event type), so `CLAUDE.md`, `README.md`, `docs/user-guide.md`
and `docs/cli-reference.md` needed no edits — no operator-visible change.

## Follow-up findings, not fixed here

Both declined findings concern the already-shipped queued-cancel path in `command_gateway.ex`. They are
listed in the findings block below so they stay visible. If the operator wants them addressed, the honest
route is a new bead scoped to the queued-cancel retry/concurrency path with a test that drives the
promotion-vs-acknowledgement race, not an edit inside this review phase.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-tepov/FIX_REPORT.md", "line": 13, "description": "The committed report asserted implementation work (6 files, +352/-8, 9 new tests in a run_cancel_test.exs, RunSlotQueue.cancel_queued/3) that contradicts PLAN.md and exists nowhere in the repository, while the branch diff contains no code.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-tepov/FIX_REPORT.md", "line": 139, "description": "The postscript both attributed the truncated report to commit dfb441fe and denied that such a commit exists on the branch.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/command_gateway.ex", "line": 221, "description": "If slot promotion commits before the waiter removal, the removal is a no-op and the dispatcher can start a cancelled run before the task acknowledgement is applied, leaving a started run whose slot was released.", "disposition": "declined", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/command_gateway.ex", "line": 257, "description": "If task.run_terminated fails after run_slots.remove_waiter succeeded, a retried run.cancel finds no waiter and no Run aggregate, so the bound task is never acknowledged and stays in_progress against a run that will never start.", "disposition": "declined", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "This branch carries no code change: the diff against main is two Markdown report files, and the queued-run cancel the bead asked for already ships upstream (6bb64a52 / PR #904) with a green regression suite (5 passed narrow, 56 passed adjacent). The only edit is restoring a truthful report, so nothing runtime can break; the two declined majors are pre-existing concurrency and retry gaps in shipped gateway code, flagged for separate work rather than touched here."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
