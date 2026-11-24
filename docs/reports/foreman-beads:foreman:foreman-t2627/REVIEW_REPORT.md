# Repo-rules review — `beads:foreman:foreman-t2627`

Run: `run-9bd4754a53b29513f8d1477bff7dc4fe` · Phase 4 of the `fix` workflow
(`repo-rules-review`) · Base branch: `main` (`$FOREMAN_BASE_BRANCH`).

## Review engine

- **Reviewer**: the repository-rules reviewer of this run — the diff is reviewed
  against the rules this repository states for itself, not against an external
  style guide.
- **Rules applied**: `AGENTS.md` (Working Rules, Documentation Gate, Typed
  Boundaries §5, Invariants, Testing and Safety) and, for the code it touches,
  the conventions already established in
  `packages/foreman_server/lib/foreman_server/questions/deliverer.ex` and its
  test file: a `GenServer` that reports a failure at `:error` instead of
  degrading it to a success value, a closed `Dispatch` command list, and a
  bounded retry of the kind `PrReport.Publisher` already uses for its start-up
  scan.
- **Diff range reviewed**: `git diff "$FOREMAN_BASE_BRANCH"...HEAD` with
  `$FOREMAN_BASE_BRANCH=main`; merge base `c209f8b4`. The committed range holds
  five files:
  - `docs/reports/foreman-beads:foreman:foreman-t2627/FIX_REPORT.md`
  - `docs/reports/foreman-beads:foreman:foreman-t2627/PLAN.md`
  - `docs/reports/foreman-beads:foreman:foreman-t2627/REVIEW_CODERABBIT_REPORT.md`
  - `ops/herdr-sidebar/keys.layout-foreman.json`
  - `ops/herdr-sidebar/mods/foreman-run/main.js`

  The two `ops/herdr-sidebar/` files are the operator's next/prev-tab change
  (`018da6b1`), byte-identical to what `main` already carries (`ddb31e80`,
  PR #960): pre-existing work in the run's base history, not this run's work.
- **Previous phase carry-forward**: `REVIEW_CODERABBIT_REPORT.md` contains **no
  machine-readable findings block** — the whole file is one line
  (`Confirmed: the run's diff contains zero implementation — PLAN.md exists but
  no code. Now running round 1 review.`), so there was no `findings` array to
  copy and **nothing is carried forward**. `FIX_REPORT.md`'s whole content is
  `Now read remaining files needed.` — the fix phase shipped no implementation.
- **What the review changed**: the committed range contained no product code at
  all, so the bead (`Questions.Deliverer` must retry a failed steer/resume while
  the server is up) was unimplemented and this phase — the last one, the one the
  pull request is opened from — would have opened a pull request with an empty
  diff. The finding was therefore fixed here, from the design the run's own
  plan phase committed in `PLAN.md`.

## Findings

| # | Severity | Finding | Source | Disposition |
| --- | --- | --- | --- | --- |
| F1 | major | The run's committed diff contained no implementation of the bead: `deliver/5`'s outcome was discarded (`_ = deliver(...)`) and `recover/1` ran only from `handle_continue(:recover, …)` at boot, so a transient refusal left the answer recorded and the run paused until the next start. | repo-rules | **fixed** |
| F2 | major | The repository's own documentation (`CLAUDE.md`, the deliverers' recovery semantics) described no such retry, so the behaviour this diff adds was undocumented. | repo-rules | **fixed** |
| F3 | minor | `docs/decisions/phase-0-durable-execution-engine.md` still listed `foreman-t2627` as an open gap with no pointer to where it is closed. | repo-rules | **fixed** |
| F4 | minor | `docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md` repeats the same gap in two places (`:641`, `:733`). | repo-rules | **declined** |
| F5 | nitpick | The two `ops/herdr-sidebar/` files in the review range restate the next/prev-tab change `main` already carries (`018da6b1` == `ddb31e80`). | repo-rules | **declined** |

Findings received from the previous phase: none (no machine-readable findings
block to carry forward — see *Review engine*).

## Fixed

- **`packages/foreman_server/lib/foreman_server/questions/deliverer.ex`**
  (F1) — *what was wrong*: the delivery outcome was thrown away
  (`_ = deliver(run_id, id, text, answered_by(event), state.opts)`) and the
  recovery pass only ran at boot (`handle_continue(:recover, state)`), so a
  refused `run.steer`/`run.resume` was never retried while the server was up —
  exactly the gap the bead names.
  *What changed*: the deliverer now keeps the outcome and re-runs its recovery
  pass on a bounded backoff while the server is up.
  - `@retry_delays_ms [1_000, 5_000, 30_000, 120_000]` (`:50`) and the
    `:retry_delays_ms` start option, documented in `start_link/1`'s `@doc`
    (`:52`).
  - `init/1` starts with `%{opts: opts, retry_ref: nil, retry_attempt: 0}`.
  - `handle_continue(:recover, state)` arms the retry from the pass's outcomes
    (`:68`).
  - The `QuestionAnswered` branch captures the outcome and arms the retry
    (`:77`); a malformed event still logs at `:error` and reports no delivery.
  - `handle_info({:questions_retry, attempt}, state)` (`:89`) re-runs the pass
    and keeps the backoff only while a delivery still fails.
  - `recover/1` keeps its contract (the number of answers attempted, `:117`)
    and now delegates to `recover_outcomes/1` (`:121`), which returns the
    outcomes of the pass.
  - `arm_retry/2` (`:338`), `schedule_retry/1` (`:346`) and `retry_delays/1`
    (`:361`): `Process.send_after(self(), {:questions_retry, attempt + 1},
    delay)`, and one `:error` log — `questions: answer delivery still failing
    after N retries; it is retried again at the next start` — when the delay
    list is exhausted. The failure is never reported as delivered.
  - The pass is idempotent: the command ids stay deterministic
    (`question-steer:<run>:<question>`, `question-resume:<run>:<question>`) and
    `paused?`/`steer_pending?` still gate the resume. A failed bus reply (a
    question of no run) is not part of the pass and is not retried — that is
    stated in the module doc rather than silently swallowed.
- **`packages/foreman_server/test/foreman_server/questions/deliverer_test.exs`**
  (F1) — *what was wrong*: no test covered a retry while the server is up.
  *What changed*: the `FlakySteerGateway` double (`:114`, the first
  `run.steer` is refused, the rest goes through the real gateway) plus two
  tests in a new `describe "a delivery that fails while the server is up"`:
  `"a transient steer failure is retried without a restart"` (`:582` — the
  answer is steered and the run resumed without a restart, and the steer is
  delivered exactly once) and `"the retries are bounded and the last one says
  so"` (`:606` — one attempt plus two retries, then the exhaustion log and no
  further attempt). The helper `dispatched_steers/0` (`:1038`) counts the
  dispatched `run.steer` commands from the test process's mailbox.
- **`CLAUDE.md`** (F2) — *what was wrong*: the deliverers' recovery semantics
  were documented without any retry, so the behaviour the diff adds was
  missing from the repository's own description of the module.
  *What changed*: the "Approvals questions (E8)" bullet (`:1164`) now states
  that `Questions.Deliverer` retries a failed delivery while the server is up,
  with the backoff (`@retry_delays_ms` `[1_000, 5_000, 30_000, 120_000]`, the
  `:retry_delays_ms` start option), the idempotence of a pass (deterministic
  command ids; `paused?`/`steer_pending?` gate the resume), the single `:error`
  log after the last delay, and that a bus reply (a question of no run) is not
  replayed by a pass and so is not retried.
- **`docs/decisions/phase-0-durable-execution-engine.md`** (F3) — *what was
  wrong*: the limitation (xii) at `:151` lists `foreman-t2627` as an open gap
  with no pointer to its closure, so the live decision record and the code
  disagreed.
  *What changed*: a forward pointer was appended to that limitation — the
  claim itself is left as written, because it is a point-in-time record.

## Declined

- **`docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md`** (F4, `:641`
  and `:733`) — the same gap is stated twice in the TRD.
  *Reason*: `AGENTS.md` — `docs/TRD/*` are point-in-time specs, their claims
  stay as written and the forward pointer lives in the live decision record
  (`docs/decisions/phase-0-durable-execution-engine.md:151`). Rewriting the
  TRD's acceptance list would rewrite a locked spec for a change that did not
  touch the TRD's subject.
- **`ops/herdr-sidebar/keys.layout-foreman.json`,
  `ops/herdr-sidebar/mods/foreman-run/main.js`** (F5) — the review range
  restates the next/prev-tab keys.
  *Reason*: pre-existing operator work in the run's base history (`018da6b1`),
  byte-identical to the change `main` already carries (`ddb31e80`, PR #960).
  It is outside this bead's scope, and dropping it would rewrite the
  operator's commit rather than this run's work.

## Verification

Commands run from the worktree root (all inside `devbox run -- bash -c '…'`):

| Command | Exit code | Result |
| --- | --- | --- |
| `cd packages/foreman_server && MIX_ENV=test mix deps.get` | 0 | dependencies fetched |
| `cd packages/foreman_server && MIX_ENV=test mix compile --warnings-as-errors` | 0 | `Generated foreman_server app`, no warnings |
| `cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/questions/deliverer_test.exs` | 0 | 33 tests, 0 failures (the two new retry tests pass: 114.6 ms, 162.8 ms) |
| `cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/questions/ test/foreman_server/approvals/` | 0 | 109 tests, 0 failures (6.5 s) |
| `cd packages/foreman_server && mix format lib/foreman_server/questions/deliverer.ex test/foreman_server/questions/deliverer_test.exs && mix format --check-formatted` | 0 | formatted, `--check-formatted` clean |
| `git diff "$FOREMAN_BASE_BRANCH"...HEAD` (re-read after the fixes) | 0 | the committed range is the five files listed above; the fixes themselves are uncommitted in the working tree and were re-read there (`deliverer.ex`, `deliverer_test.exs`, `CLAUDE.md`, `docs/decisions/phase-0-durable-execution-engine.md`) — no new violation of the same rules: the failure is still reported at `:error`, the boundary stays typed (`@type outcome`, `{:failed, reason}`), the option that the code reads is the one that is documented, and the documentation matches the code. |

### Documentation gate

- **Externally visible identifiers added**: `Questions.Deliverer`'s start option
  `:retry_delays_ms` (and the module attribute `@retry_delays_ms`). Nothing
  else: no new route, CLI verb, MCP tool, command, event, config key or env
  var; no identifier removed or renamed.
- **Grep of the four documentation files** for `Deliverer`, `recover`,
  `retry_delays_ms`:
  - `CLAUDE.md` — hit at `:1164` (the deliverers' recovery semantics); **edited**
    (F2).
  - `README.md`, `docs/user-guide.md`, `docs/cli-reference.md` — no hit for the
    deliverer, its recovery or the new option; **no edit needed** (no
    operator-visible surface there).
  - `docs/decisions/phase-0-durable-execution-engine.md` — hit at `:21`, `:42`,
    `:151`, `:243`, `:307`; **edited** at `:151` (F3, the live gap statement);
    the other hits are dated enumerations of open beads ("read with `br show`
    on 2026-11-11") and the Phase-1 scoping table, left as written.
  - `docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md` — hit at `:641`
    and `:733`; **declined** (F4), point-in-time spec.
- The `:retry_delays_ms` option is documented where it is read: in
  `start_link/1`'s `@doc` (`deliverer.ex:52`) and in `CLAUDE.md:1164`.

### Left uncommitted

The four changed files are left in the working tree for Foreman to commit:
`packages/foreman_server/lib/foreman_server/questions/deliverer.ex`,
`packages/foreman_server/test/foreman_server/questions/deliverer_test.exs`,
`CLAUDE.md`, `docs/decisions/phase-0-durable-execution-engine.md`.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/lib/foreman_server/questions/deliverer.ex", "line": 77, "description": "The run's committed diff contained no implementation of the bead: the delivery outcome was discarded and a refused run.steer or run.resume was never retried while the server was up.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "major", "path": "CLAUDE.md", "line": 1164, "description": "The repository's own documentation of the deliverers' recovery semantics did not describe the retry this diff adds.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/decisions/phase-0-durable-execution-engine.md", "line": 151, "description": "The live decision record still listed foreman-t2627 as an open gap with no pointer to where it is closed.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md", "line": 641, "description": "The TRD repeats the same gap in two places, and a point-in-time spec is left as written.", "disposition": "declined", "source": "repo-rules"}, {"severity": "nitpick", "path": "ops/herdr-sidebar/mods/foreman-run/main.js", "line": null, "description": "The review range restates the operator's next/prev-tab change that main already carries, which is outside this bead's scope.", "disposition": "declined", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The change adds a timer-driven retry to the live answer-delivery path: a refused run.steer or run.resume is re-attempted on a bounded backoff (four delays, 120 s at the end) and then logged once at :error, so the worst case is repeated refused commands against an already-paused run, not a lost or mis-delivered answer. No schema, event, command or public API changes; the pass stays idempotent through deterministic command ids and the paused?/steer_pending? gates."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
