# Repo-rules review — `beads:foreman:foreman-f6zmv`

Phase 4 (`repo-rules-review`) of run `run-ec499920490857a5227e8fbddb92d9d0`.

## Review engine

No external CLI in this phase. One pass over this run's own diff, reviewed
against `AGENTS.md` (Working Rules, Documentation Gate, §5 Typed Boundaries /
Loud Failures, Invariants, Testing and Safety), with the rules' own checks run
where they are executable:

- Diff range: `git diff main...HEAD` — merge-base `c209f8b4` → HEAD `5c0d080f`,
  7 files changed, 280 insertions(+), 3 deletions(-).
  - `ops/herdr-sidebar/keys.layout-foreman.json` (+2/-0)
  - `ops/herdr-sidebar/mods/foreman-run/main.js` (+17/-1)
  - `packages/foreman_server/lib/foreman_server/approvals/sweeper.ex` (+20/-2)
  - `packages/foreman_server/test/foreman_server/approvals/sweeper_test.exs` (+37/-0)
  - `docs/reports/foreman-beads:foreman:foreman-f6zmv/FIX_REPORT.md` (added)
  - `docs/reports/foreman-beads:foreman:foreman-f6zmv/PLAN.md` (added)
  - `docs/reports/foreman-beads:foreman:foreman-f6zmv/REVIEW_CODERABBIT_REPORT.md` (added)
- Previous phase's findings: read with the server's own
  `ForemanServer.Workflow.ReviewFindings.read/1` → `:absent`, so no machine
  block was carried automatically. Its single prose finding (documentation-gate
  outcome in `FIX_REPORT.md`) is carried forward by hand with source
  `coderabbit`. The parser verdict is also why one of this phase's own findings
  exists — see below.

Rule-by-rule verdict on the code change:

- **§5.2 Total result handling / loud failures.** Compliant. The invalid
  `on_timeout` raise is an explicit `ArgumentError` naming the option, the
  accepted values and the rejected value — no catch-all, no degrade to a
  plausible success.
- **§5.3 Absent ≠ malformed.** Compliant. An absent `:on_timeout` falls back to
  `Config.on_timeout/0` (default `:surface`) via `Keyword.get_lazy/2`; only a
  present-but-invalid value is rejected.
- **§5.1/§5.4/§5.7 boundaries.** Compliant. No new payload shapes, no new key
  convention, `TimeoutPolicy`/`OperatorTimeout` keep resolving `:on_timeout`
  lazily through the same `Config.on_timeout/0`. The two raise sites now have
  distinct prefixes (`ForemanServer.Approvals.Sweeper` vs `config
  :foreman_server, :approvals`), so a failure names the door it came through.
- **Surgical changes.** Compliant for the bead's fix; the branch also carries an
  unrelated commit — Finding 3.
- **Documentation gate.** Compliant (see Verification).
- **Testing.** Compliant: three tests added, all in the sweeper's own file,
  matching its existing conventions (same aliases/helpers, `async: false`,
  `Application.get_env`/`put_env` with an `on_exit` restore, no
  `rescue`/`catch`).
- **Invariants.** Untouched: phase execution, workflow vocabulary, PR base,
  merge gate, harness providers all unchanged.
- **Two runtime behaviours the change trades away** are recorded as declined
  nitpicks (Findings 4 and 5) rather than silently accepted.

## Findings

5 findings: 2 fixed, 2 declined, 1 open for the operator.

1. `minor` — `docs/reports/foreman-beads:foreman:foreman-f6zmv/FIX_REPORT.md:1`
   — documentation-gate outcome not recorded (carried from the `coderabbit`
   phase, whose copy was prose only). **fixed**
2. `minor` — `docs/reports/foreman-beads:foreman:foreman-f6zmv/REVIEW_CODERABBIT_REPORT.md:14`
   — that report states its machine blocks parsed as recorded; the file has
   none. **fixed**
3. `minor` — `ops/herdr-sidebar/mods/foreman-run/main.js` — branch carries an
   unrelated commit that duplicates already-merged upstream work and breaks the
   merge with `main`. **open**
4. `nitpick` — `packages/foreman_server/lib/foreman_server/approvals/sweeper.ex:74`
   — the raise does not say whether the value came from the start option or the
   config. **declined**
5. `nitpick` — `packages/foreman_server/lib/foreman_server/approvals/sweeper.ex:55`
   — the policy is resolved once at init, so a later config change is not
   observed. **declined**

## Fixed

1. `docs/reports/foreman-beads:foreman:foreman-f6zmv/FIX_REPORT.md`
   - What was wrong: the file was one line of leftover plan narration ("Now Edit
     2 — insert the new `describe` block after line 155 in the test file.") —
     0 insertions in the diff, no report of what changed and no documentation
     gate outcome, which `AGENTS.md` makes a completion gate, not a suggestion.
   - What changed: rewritten as the run's fix report — the defect
     (`init/1` carried `:on_timeout` lazily, so `TimeoutPolicy.apply/3` →
     `Config.on_timeout/0` raised mid-sweep before any question expired), the
     change per file, the documentation-gate outcome (no externally visible
     identifier added/removed/renamed; `docs/user-guide.md:3427` still accurate;
     `CLAUDE.md`, `README.md`, `docs/cli-reference.md` need no edits;
     `docs/decisions/phase-0-durable-execution-engine.md` and
     `docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md` are point-in-time
     records and are left as written) and the verification commands with exit
     codes. A header states which phase wrote it and why.
2. `docs/reports/foreman-beads:foreman:foreman-f6zmv/REVIEW_CODERABBIT_REPORT.md`
   - What was wrong: line 14 claims both machine blocks were parsed as recorded
     (`ReviewFindings.parse/1` → `{:recorded, ...}`,
     `PrRisk.parse_judgement/1` → `status: "recorded", level: "LOW"`) and the
     closing line claims the artifact is untracked. Neither is true: parsed with
     the server's own code, `ReviewFindings.read/1` and `parse/1` both return
     `:absent` and `PrRisk.parse_judgement/1` returns
     `%{status: "absent", level: nil, defect: nil, defect_detail: nil, rationale: nil}`;
     the file is committed by the phase 3 commit `5c0d080f`. A reader — or
     Foreman's risk roll-up — would take a recorded LOW judgement that does not
     exist.
   - What changed: a dated **Correction** appended, naming both false
     statements with the actual parser output. The `minor` finding is preserved
     as carried Finding 1 rather than dropped. No other line of that report was
     touched; the review-phase findings and risk blocks now live in this file.

## Declined

4. `packages/foreman_server/lib/foreman_server/approvals/sweeper.ex:74` — the
   `ArgumentError` does not say whether the rejected value came from the
   `start_link` option or from `config :foreman_server, :approvals`. Declined:
   no repository rule requires it, the message already names the option, the
   accepted values and the value, and the two raise sites have distinct
   prefixes, so the source is distinguishable from the message alone. Adding a
   "came from config" clause is an adjacent improvement the bead did not ask for
   (`AGENTS.md`: don't change lines that don't trace to the request).
5. `packages/foreman_server/lib/foreman_server/approvals/sweeper.ex:55` —
   resolving the policy once at init means a runtime
   `Application.put_env(:foreman_server, :approvals, on_timeout: …)` is no longer
   observed by a running sweeper. Declined: nothing in `lib/` writes that config
   at runtime (only `config/*.exs` and tests, and the tests restore it via
   `on_exit`); the bead asked for validation *in* `Sweeper.init`, and per-subject
   re-resolution would re-introduce the mid-sweep raise the bead is about. The
   trade is recorded here because it is invisible otherwise.

## Verification

Run from `packages/foreman_server` with
`DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test`
(`devbox run`, Elixir 1.20.4 / OTP 28):

- `mix deps.get` → exit 0
- `mix format --check-formatted lib/foreman_server/approvals/sweeper.ex test/foreman_server/approvals/sweeper_test.exs` → exit 0
- `mix compile --warnings-as-errors` → exit 0
- `mix test --warnings-as-errors test/foreman_server/approvals/sweeper_test.exs test/foreman_server/approvals/config_test.exs` → exit 0, 15 tests passed (0.8s)
- `mix test --warnings-as-errors test/foreman_server/approvals/` → exit 0, 75 tests passed (the `[warning] handle_run_resumed: no task found for run …` lines in that output are the suite's own expected log noise, not warnings-as-errors failures)
- Parser check of both artifacts with the server's own code (`mix run --no-start`):
  `ReviewFindings.read/1` → `:absent` for `REVIEW_CODERABBIT_REPORT.md`;
  `PrRisk.parse_judgement/1` → `%{status: "absent", …}`; this file's own blocks
  are what Foreman will read next.
- Merge check for Finding 3, run in a detached probe worktree at `5c0d080f`
  under `/Users/ldangelo/.foreman/tmp/` (removed afterwards; nothing created in
  `/tmp`): `git merge --no-commit --no-ff main` → exit 1,
  `CONFLICT (content): Merge conflict in ops/herdr-sidebar/keys.layout-foreman.json`,
  1 conflicted file.
- Documentation gate: identifiers added/removed/renamed — none.
  `grep -n on_timeout` over `CLAUDE.md`, `README.md`, `docs/user-guide.md`,
  `docs/cli-reference.md` → only `docs/user-guide.md:3427`, which still
  describes `on_timeout: :surface | :deny` correctly. No doc file needed an
  edit; the two point-in-time specs that list limitation (xiv) for this bead are
  left as written per `AGENTS.md`.

Both fixes are report files only; no source or test line was changed by this
phase, and the fixes are left uncommitted for Foreman to commit.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema":"foreman.review_findings/1","reviewed":true,"findings":[{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-f6zmv/FIX_REPORT.md","line":1,"description":"Fix report was one line of plan narration: no record of what changed and none of the documentation-gate outcome AGENTS.md requires.","disposition":"fixed","source":"coderabbit"},{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-f6zmv/REVIEW_CODERABBIT_REPORT.md","line":14,"description":"Report claims its machine blocks parsed as recorded; ReviewFindings.read/1 and PrRisk.parse_judgement/1 both return absent, so the claimed LOW judgement does not exist.","disposition":"fixed","source":"repo-rules"},{"severity":"minor","path":"ops/herdr-sidebar/mods/foreman-run/main.js","line":null,"description":"Branch carries unrelated commit 018da6b1 (herdr-sidebar next/prev tab keys) that duplicates already-merged PR #960 and conflicts with main in keys.layout-foreman.json; merging needs manual resolution that keeps main's newer cmd-shift keys.","disposition":"open","source":"repo-rules"},{"severity":"nitpick","path":"packages/foreman_server/lib/foreman_server/approvals/sweeper.ex","line":74,"description":"The ArgumentError does not say whether the rejected on_timeout value came from the start option or from the approvals config.","disposition":"declined","source":"repo-rules"},{"severity":"nitpick","path":"packages/foreman_server/lib/foreman_server/approvals/sweeper.ex","line":55,"description":"Resolving the policy once at init means a later runtime change of the approvals on_timeout config is no longer observed by a running sweeper.","disposition":"declined","source":"repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema":"foreman.risk_judgement/1","level":"LOW","rationale":"The code change is 20 lines in approvals/sweeper.ex plus 37 test lines: it moves an existing ArgumentError from mid-sweep to sweeper start, adds no interface, and fails loudly at boot instead of silently never expiring questions. Remaining exposure is the branch's duplicated herdr-sidebar commit, which conflicts with main in keys.layout-foreman.json and must be resolved by hand before merge."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
