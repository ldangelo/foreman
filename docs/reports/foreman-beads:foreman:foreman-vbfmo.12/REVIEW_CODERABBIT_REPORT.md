# CodeRabbit review — `beads:foreman:foreman-vbfmo.12`

Run `run-8b082d394baee424caa1ed9299ff2022` · phase 3 (`coderabbit-review`) · workflow `fix`
Branch `foreman/foreman-vbfmo.12/run-8b082d394baee424caa1ed9299ff2022` · diff base `main` (`0988b071`, `FOREMAN_BASE_BRANCH=main`)

## Review engine

Command run from the worktree root, twice (round 1 and round 2), both exit 0:

```
coderabbit review --agent --base main
```

- Round 1: head `df38cb84` + uncommitted working tree — 2 findings, both `minor`, no `Critical`/`Major`.
- Round 2: after applying the round-1 fixes — 1 finding, `minor`, on a report document only.

The tool reviewed these files both times: `docs/reports/foreman-beads:foreman:foreman-vbfmo.12/FIX_REPORT.md`,
`docs/reports/foreman-beads:foreman:foreman-vbfmo.12/PLAN.md`,
`docs/reports/foreman-beads:foreman:foreman-vbfmo.12/REVIEW_CODERABBIT_REPORT.md`,
`packages/foreman_server/lib/foreman_server/coordinator/context.ex`,
`packages/foreman_server/test/foreman_server/coordinator/context_test.exs`.

This report file replaces the phase-1 review report of the same name (committed at `91fc4f8f`);
that one reviewed a different artifact set and claimed the "active threads now" count
(`packages/foreman_server/lib/foreman_server/coordinator/context.ex:440`) still counted cancelled
threads. It did not: `limits_section/1` counts only `:working` and `:waiting_on_you`, so the card
state fix already removes cancelled threads from that count. Round 2's only finding is that stale
claim, corrected here.

## Rounds

**Round 1** — findings received: 2 (`minor` × 2). Fixed: 2. Declined: 0.

1. `packages/foreman_server/test/foreman_server/coordinator/context_test.exs:363` — "Assert required
   cancelled disposition, not fallback." The assertion accepted `:idle` although the plan requires
   `:resolved`, so the test passed against an incomplete implementation; it also asked for a
   cancelled-with-`last_report` assertion to catch clause ordering. → **Fix** (real: the test pinned
   the fallback, not the required contract, and the bead's "or idle" alternative is what let the
   gap through).
2. `packages/foreman_server/lib/foreman_server/coordinator/context.ex:138` — "Classify cancelled
   threads explicitly as `:resolved`." Removing `"cancelled"` from the `waiting_on_you` guard left a
   cancelled thread falling through to `:idle`, or — once it had posted a run report — matching the
   `last_report` clause as `:ready_for_review`, which keeps it protected from normal card eviction.
   → **Fix** (real, and the `:ready_for_review` path contradicts the bead directly).

Both findings are `minor`, but each fix is local (one clause, one assertion block), was already the
plan recorded in `PLAN.md` for this bead, and was proven by the tests in the same step — so they
were fixed rather than declined.

**Round 2** — findings received: 1 (`minor` × 1). Fixed: 0 (see Declined). Declined: 1.

1. `docs/reports/foreman-beads:foreman:foreman-vbfmo.12/REVIEW_CODERABBIT_REPORT.md:45-47` —
   "Correct the remaining-active-count finding": the phase-1 report directs the operator to fix an
   inflated "active threads now" count that the code already excludes, and recommends dropping
   cancelled threads from `open_threads`. → **Fixed by rewrite** — this file is the phase's own
   report artifact, not source, and it was rewritten from scratch this phase, so the stale claim no
   longer exists. Recorded as fixed with no code change rather than as a code fix.

No `Critical` or `Major` finding was found or fixed in either round, so the stop-early rule applies
after round 2; no round 3 was run.

## Fixed

- `packages/foreman_server/lib/foreman_server/coordinator/context.ex` (before the `:waiting_on_you`
  guard, now line 137-142) — **what was wrong:** a cancelled thread had no classification of its
  own, so it resolved by fallthrough: `:idle` with no run report, `:ready_for_review` once it had
  one (that clause sits above the status clauses), which also exempts it from the `:resolved` →
  `:idle` card eviction. **What changed:** an explicit clause ahead of the `last_report` clause.

  ```elixir
    # An operator-cancelled thread is terminal by the operator's own decision: it needs no
    # attention. `Overview.Group.classify/1` groups it `:resolved` too, so this clause must sit
    # above the `last_report` clause, or a cancelled thread that already reported would classify
    # `:ready_for_review`.
    def card_state(%Thread{status: "cancelled"}), do: :resolved
  ```

  The returned atom set is unchanged (`:waiting_on_you | :ready_for_review | :working | :idle |
  :resolved`), so no `@spec` change.
- `packages/foreman_server/test/foreman_server/coordinator/context_test.exs:352-366` — **what was
  wrong:** the `card_state/1` classification test asserted `:idle` for `"cancelled"`, pinning the
  fallthrough instead of the required disposition, and had no case for a cancelled thread that
  already posted a report. **What changed:** the assertion now expects `:resolved` for both shapes.

  ```elixir
      assert Context.card_state(thread(1, "cancelled")) == :resolved
      assert Context.card_state(thread(1, "cancelled", last_report: %{verdict: "ok", summary: "s"})) ==
               :resolved
  ```

  The existing `blocked` and `failed` → `:waiting_on_you` assertions already cover the "failed ones
  still need attention" half of the Done criteria; the `deleted` and `removed` → `:waiting_on_you`
  assertions were left as they are.

Both fixes are left uncommitted for Foreman to commit, as this phase requires.

## Declined

- None that touched source. The single round-2 finding was on this report file (see Rounds); its
  substance is corrected by the rewrite in place of a code change.
- Out of scope, deliberately untouched (not review findings, recorded so the next phase does not
  re-open them):
  - `docs/reports/foreman-beads:foreman:foreman-vbfmo.12/FIX_REPORT.md` holds a 169-byte
    tool-error fragment instead of the phase-2 fix report (committed at `df38cb84`), and
    `PLAN.md:48`/`:129` describe non-existent functions (`Context.summary/1`, `groups.done`,
    `groups.needs_attention`, "context.ex:434"). These are prior phases' report artifacts; a
    review phase editing another phase's report would falsify its record, so they are reported here
    instead.
  - `packages/foreman_server/test/foreman_server/coordinator/context_contract_test.exs:29` still
    maps `"cancelled"` to `:waiting_on_you` — a fixture for a budget/eviction test, not a
    classification expectation; it stays green and is unrelated to this bead.

## Verification

All commands run through `devbox run` (Elixir 1.20.4 / OTP 28), from the worktree root:

| Command | Exit | Result |
| --- | --- | --- |
| `cd packages/foreman_server && MIX_ENV=test mix compile --warnings-as-errors` | 0 | clean |
| `cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/coordinator/context_test.exs` | 0 | 17 tests, 0 failures |
| `cd packages/foreman_server && mix format --check-formatted lib/foreman_server/coordinator/context.ex test/foreman_server/coordinator/context_test.exs` | 0 | no diffs |
| `cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/coordinator` | 0 | 219 tests, 0 failures |
| `coderabbit review --agent --base main` (round 1) | 0 | 2 minor findings |
| `coderabbit review --agent --base main` (round 2) | 0 | 1 minor finding (report doc) |

Both test runs used `DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test`
(test DB in docker `foreman-postgres`, port 55432); the suite is not async in these files, so they
take ~60s under devbox. The touched-directory run covers every other `cancelled`-related
coordinator test (`harness_usage_test.exs`, `reporter_test.exs`, `context_contract_test.exs`).

Documentation gate — identifiers added/removed/renamed by this diff: none. `card_state/1` keeps its
name, arity and return set; no route, config key, env var, CLI verb, command/event type or MCP tool
was added or changed. `grep` of `card_state`, `waiting_on_you` and `active threads now` across
`CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`: the only hits
(`CLAUDE.md:1157`, `docs/cli-reference.md:860`, `docs/user-guide.md:422,454,458`) describe
`Overview.Group.classify/1`, which this diff does not touch and which already groups cancelled as
`:resolved`. So none of the four documentation files needed edits — no operator-visible change.

Risk: the change is one pattern-match clause plus two assertions. Consequence surface is the
coordinator's per-thread card state — card ordering/eviction priority (`context.ex:158` →
`drop_order/1`) and the "active threads now" count (`context.ex:440`) — both of which move in the
direction the bead asks for and are covered by the coordinator suite. The Overview grouping and the
`waiting_on_you` count for blocked/stuck/needs_recovery/paused/failed are untouched, and there is no
evidence in this diff of a regression, so: LOW.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "minor", "path": "packages/foreman_server/test/foreman_server/coordinator/context_test.exs", "line": 363, "description": "The cancelled card_state assertion accepted :idle although :resolved is required, so the test passed against an incomplete implementation and never caught the report-posted case.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/coordinator/context.ex", "line": 138, "description": "Removing cancelled from the waiting_on_you guard left cancelled threads classified by fallthrough — :idle with no report, :ready_for_review once one exists — instead of the required :resolved.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-vbfmo.12/REVIEW_CODERABBIT_REPORT.md", "line": 45, "description": "The prior phase-1 report told the operator that cancelled threads still inflate the active-threads count and recommended dropping them from open_threads, which this patch already handles via card_state.", "disposition": "fixed", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "One added pattern-match clause returning an atom already in card_state/1's spec, plus two assertions in one existing test; the Overview grouping and every non-cancelled status path are untouched. The only behavioural surface touched is the coordinator's card state, whose eviction and active-count consumers moved as intended and are covered by 219 coordinator tests, all green."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
