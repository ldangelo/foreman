# Review gap-bead loop guard: live re-test after PR #610 (2026-10-22)

Re-run of the live check in `review-gap-beads-live-run.md` against `origin/main` @ `37f3e3ff`
(contains #610, "loop guard also checks the source bead's foreman-gap label"). Everything below was
observed unless marked UNVERIFIED.

**Headline: #610 as merged did not work against the real `br 0.6.0`.** Its label read
(`BeadsAdapter.get/2` -> `br show --json`) failed on every bead with `BR_CONTRACT_MISMATCH`, so the
fail-closed branch fired for *every* review: no gap beads were ever created, including for normal
`foreman-exec` beads (the natural chain). Unit tests passed because they stub `br` with a
hand-written object payload. Fixed in this PR (see Fix). Scenarios 1 and 2 below were run with the
fix; the unfixed result is recorded as "run 0".

## Environment

- Worktree `foreman-wt/gapretest` off `origin/main` 37f3e3ff; real Foreman server
  (`mix phx.server`, dev env, via `devbox run`), throwaway Postgres DB `foreman_gapretest`
  (dropped afterwards), port 47772, `HOME` redirected to `gap-scratch2/home` (`~/.pi` symlinked).
- `FOREMAN_START_BEADS_WATCHER=true`; review capture + analysis are config defaults (on);
  `FOREMAN_REVIEW_PROVIDER=pi FOREMAN_REVIEW_MODEL=minimax/MiniMax-M2.7-highspeed`; worker is
  `pi`/minimax via a one-phase `gapimpl` workflow in the isolated `~/.foreman/workflows` (same as
  the previous run). All `br` calls hit the scratch project's own `br 0.6.0` database
  (`br init --prefix gap`); local bare `origin`; nothing touched GitHub or the real `.beads`.
- Project registered with `foreman project create --id gapscratch --path <repo> --task-provider beads --task-provider-database-path <repo>/.beads` (CLI pointed at the server with `FOREMAN_API_URL=http://localhost:47772`).
- ReviewRecorded notes were read from the `events` table (`event_type like '%ReviewRecorded'`, data
  is an Erlang-term binary, so the `summary`/note strings were read via `encode(data,'escape')`).
- Real model calls: the reviewer/worker failed with transient provider errors twice
  (`Anthropic stream ended before message_stop`; once a reviewer run failed within 1 s with no
  detail recorded). These produced `undetermined` verdicts (itself a useful live check: the comment
  was still posted, zero gap beads), and I retried with a fresh bead.

## Fix (small, clear)

`br 0.6.0 show <id> --json` returns a **one-element JSON array**, and omits `dependencies` /
`dependents` for an issue without relations. `BeadsAdapter.get/3` required an object and both keys:

```
BeadsAdapter.get("gap-z3e", %{database_path: ...})
=> {:error, %ProviderError{code: "BR_CONTRACT_MISMATCH", message: "Beads CLI contract does not match the adapter expectations.", ...}}
```

`beads_adapter.ex`: `get` now accepts `[%{} = payload]` (the other adapter parsers already did) and
treats absent `dependencies`/`dependents` as `[]`. Regression test
`beads_adapter_get_test.exs` "reads br 0.6.0 show output ..." (real `br 0.6.0 schema issue-details`
requires only 8 fields, which the test's schema fixture mirrors). Mutation check: reverting the
array clause fails that test (10/11); reverting the `|| []` fails it (10/11). Only `Review.BeadSink`
calls `provider.get` in `lib/`.

## Results

| # | Scenario | Result |
|---|----------|--------|
| 0 | Unfixed #610 vs real br 0.6.0 (hand-labelled bead) | **FAIL**: note `could not read the source bead's labels (BR_CONTRACT_MISMATCH ...); failing closed`; 3 gaps found, 0 beads |
| 1 | Hand-labelled `foreman-exec,foreman-gap`, no prior ReviewRecorded (with fix) | PASS |
| 2 | Natural chain, event-log suppression of the gap bead's own review | PASS (label-stripped variant UNVERIFIED) |
| 3 | Fail closed live (`br show` fails, comment still posts) | PASS (fault injected with a `br` shim) |
| 4 | Project git history unchanged by the reviewer | PASS |

### Before / after (hand-labelled bead, `br list -l foreman-gap -a` count)

| Run | Bead | Reviewer gaps | New gap beads |
|-----|------|---------------|---------------|
| Previous run (pre-#610) | `gap-9kp` | 2 | **2** (`gap-qgy`, `gap-n4m`): bug |
| This run, #610 unfixed (run 0) | `gap-z3e` | 3 | **0**, but only because the read errored for every bead (fail-closed misfire) |
| This run, with the fix | `gap-crm` | 2 | **0**, suppressed for the right reason |

### 1. Regression of the found bug (with fix)

Scratch DB had no `foreman-gap` beads beyond the earlier hand-labelled attempts; count before the
bead = 3 (`gap-z3e`, `gap-rns`, `gap-bgx`, all hand-labelled; two of them `undetermined`).

```
br list -l foreman-gap -a --json | ...len   -> BEFORE 3
br create "Add rate limiting, request logging and a /metrics endpoint (retry 3)" -t task -p 2 \
  -l foreman-exec,foreman-gap -d "In app.py add per-client rate limiting (429 after 5 req/s) ... Add unit tests ... README.md." -> gap-crm
```

Tries: 3 hand-labelled beads were needed after the first (the first, `gap-z3e`, ran against unfixed
code: gaps found but the label read failed; `gap-rns` and `gap-bgx` ended `undetermined` because the
reviewer/worker hit provider errors). `gap-crm` is the try that ran with the fix and a clean
reviewer verdict. The reviewer found gaps on its own each time; no harder request was needed.

- Dispatched by the **watcher**: server log
  `BeadsWatcher project=gapscratch bead=gap-crm dispatching task.create workflow_type=gapimpl`
  (06:14:04, one second after `br create`; I never submitted a run).
- `analysis.json` for run `run-b1ce9a77...`: verdict `met`, 2 gaps
  (`Add a test asserting the structured request log line`, `Prune rate limiter state for idle clients`).
- ReviewRecorded: `summary` ends `gap creation suppressed: source bead carries the foreman-gap label`;
  `gap_bead_ids` is empty (`j`, the empty-list term).
- Comment WAS posted: `br comments list gap-crm` -> `# Review verdict: met ... ## Gaps ...`
  (see `Full analysis: .../analysis.md`).
- `br list -l foreman-gap -a --json | ...len` -> `AFTER 4` (= 3 before + `gap-crm` itself; no bead
  created by this review). `br list -a` shows no new bead.

### 2. Natural chain (with fix)

```
br create "Add a /version route and a /ready probe" -t task -p 2 -l foreman-exec -d "...tests...README..." -> gap-q6l
br list -l foreman-gap -a   -> BEFORE 4
```

- Watcher dispatched `gap-q6l` (`run-07d1f4a4`): verdict `met`, 2 gaps -> two beads created,
  `gap-jgv` ("Handle query strings and trailing slashes on the new routes") and `gap-e5g`
  ("Flip readiness only after the server is actually listening"), both labelled
  `['foreman-exec', 'foreman-gap']`, one per gap, comment posted on `gap-q6l`.
- The watcher dispatched both gap beads itself (`dispatching task.create` for `gap-e5g`/`gap-jgv`
  at 06:18:50). `gap-jgv` review (`run-8d30cfea`): verdict `met`, 2 gaps, ReviewRecorded note
  `gap creation suppressed: source bead is itself a foreman-gap bead` (the event-log path; the label
  path's wording is `source bead carries the foreman-gap label`), `gap_bead_ids` empty, comment
  posted, `br list -a` stayed at 7 beads, `foreman-gap` count unchanged.
- Label-stripped variant: I ran `br update gap-e5g --remove-label foreman-gap` while its run was in
  flight (labels then `['foreman-exec']`), but its review found 0 gaps (`met`), so it did not
  exercise suppression. **UNVERIFIED** that the event-log path suppresses with the label removed
  (and that it needs no provider call): the note text identifies the event-log path, but I did not
  observe the absence of a `br show` for it.

### 3. Fail closed live

Fault injection (this is not a natural failure): the server was restarted with a `br` shim first on
`PATH` (`gap-scratch2/shim/br`) that delegates to the real `br` except `br show ...`, which exits 1
with `{"error":{"code":"DATABASE_ERROR",...}}` while a marker file exists. That is the only way I
found to make `provider.get` fail while `provider.annotate` (`br comments add`) still works.

```
br create "Add /uptime and /build-info routes" -t task -p 2 -l foreman-exec -d "..." -> gap-zmv   (watcher dispatched it)
touch gap-scratch2/FAIL_SHOW   # armed as soon as the run's archive request.md appeared (reviewer still running)
```

- `shim.log`: exactly one intercepted call,
  `br show --db .../repo/.beads/beads.db gap-zmv --json` (the label read).
- ReviewRecorded note: `gap creation suppressed: could not read the source bead's labels
  (BR_ERROR_ENVELOPE: DATABASE_ERROR); failing closed so a gap loop cannot start`.
- Reviewer found 2 gaps (`__pycache__` artifacts, weak `/uptime` assertion); `gap_bead_ids` empty;
  `br list -a` stayed at 8 beads; `foreman-gap` count stayed at 5.
- The comment WAS posted (`br comments list gap-zmv` -> `# Review verdict: met ... ## Gaps ...`), so
  the `bead_write_failed` case (annotate also failing) was **not** exercised: UNVERIFIED.

### 4. Project git history

Project `main` stayed at `3f949ea init`, `git status --short` empty. All other commits are the
worker's `[pi] Done.` commits on `foreman/<bead>/<run>` branches; none authored by the reviewer
(UNVERIFIED beyond that outcome: reviewer writes were not traced).

## Not done / UNVERIFIED

- `get` against a bead that *has* dependencies/dependents (shape of `br 0.6.0` relation objects vs
  the adapter's nested-issue parser) was not exercised live.
- Reviewer provider errors (`Anthropic stream ended before message_stop`, one 1-second reviewer
  failure with no detail) are environmental; not investigated.
- Real GitHub/PR behaviour (none used).
