# CodeRabbit review — beads:foreman:foreman-zv8bi (run-59f7dec0c17ee9867d8c48735ac5416d)

Phase 3 (`coderabbit-review`), 3 of 3 rounds run. Diff base: `$FOREMAN_BASE_BRANCH` = `main`.

Scope note that governs every finding below: this run's diff against `main` is
`docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md` (+163) and
`FIX_REPORT.md` (+1). The `base_ref_policy` feature the task asks for is **not**
implemented by any phase of this run — `grep -rn base_ref_policy
packages/foreman_server/lib packages/foreman_server/test` returns zero hits. So
the reviewable surface is the plan document, and a review phase must not turn
into an implementation phase.

## Review engine

Command, run from the worktree root each round:

```
coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"
```

`$FOREMAN_BASE_BRANCH` = `main` (non-empty, so the phase ran). Exit code `0` on
all three rounds; `coderabbit auth status` reported authenticated (CLI 0.9.6 at
`/Users/ldangelo/.local/bin/coderabbit`). No authentication failure, so no
`Review engine` fallback path was taken.

Round timings: ~200 s, ~45 s, ~110 s. The CLI renders long comment bodies as
`<<ccr:…>>` placeholders in terminal output, so every finding quoted below was
re-read from CodeRabbit's own review cache
(`~/.coderabbit/reviews/14e5cb67/ad5e1c13/reviews/<ts>/<uuid>.json`) rather than
from the placeholder text.

## Rounds

**Round 1** — 1 finding received, 1 fixed, 0 declined.

- `minor` · `docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md:5` —
  "This file contains 20 lines, not the stated 215-line plan. It summarizes
  edits but does not contain the promised numbered plan. Restore the plan from
  commit `9db30e48` so readers can use it without recovering it from Git
  history." Verified: the phase-2 commit `3c5aa4eb` overwrote the 215-line plan
  with a 20-line summary. Fixed.

**Round 2** — 1 finding received, 1 fixed, 0 declined.

- `minor` · `docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md:113-114` —
  "The snippet reads `@base_ref_policy_id` for both the label `for=` and the
  `select` `id=`. The plan adds no such assign and `project_settings_live.ex`
  has no `@base_ref_policy_id`; the template raises `undefined assign` when the
  settings page renders. Use the existing fields' literal-id/matching-label
  pattern." Verified: no `@base_ref_policy_id` exists in the LiveView and the
  plan never assigns it. Fixed.

**Round 3** — 2 findings received, 2 fixed, 0 declined.

- `minor` · `docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md:84` —
  "This clause omits `when` before `is_binary(value)`. Copying it into
  `settings.ex` prevents the module from compiling. Use `defp
  validate(:base_ref_policy, value) when is_binary(value) do`." Verified: the
  line was `defp validate(:base_ref_policy, value) is_binary(value) do`, which
  is a syntax error. Fixed.
- `minor` · `docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md:116` —
  "The help text says the selection controls the PR base, but Line 17 says no
  run code reads the new key. A user can select `checkout` and still get the
  existing behavior. Mark the form and user-guide description as inactive until
  the reader is implemented." Verified: plan §1 states "Nothing in this task
  makes the selection change any behavior." Fixed.

Stopping condition: round 3 produced no `Critical`/`Major` finding, and no round
did, so the round cap is the only reason a 4th round was not run. All four
findings were `minor` and each fix was a local, single-line-or-single-section
edit to a markdown plan, which is the "obviously safe and local" case the phase
contract allows.

## Fixed

1. `docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md` (whole file) —
   what was wrong: the phase-2 commit replaced the executable 215-line plan with
   a 20-line abstract, so the contract "later phases read this exact path" was
   satisfied by a document that could not be executed. What changed: added a §0
   recovery note recording who overwrote what and the `git show 9db30e48:…`
   command, restored the full plan body (verdict, root cause, the failing
   check, the 11 numbered edits re-numbered as §4.1–§4.11, docs gate), and
   preserved the phase-2 note verbatim as §5. File is now 163 lines, 145
   insertions / 2 deletions over HEAD.
2. `docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md:116-119` (§4.9) —
   what was wrong: the proposed HEEx used `@base_ref_policy_id`, an assign that
   neither the plan nor `project_settings_live.ex` defines, and the plan never
   told the implementer to supply the option list. What changed: the snippet now
   uses the module's existing `field/1` shape with
   `options={@base_ref_policies}`, and §4.9 adds the instruction to put
   `base_ref_policies: Settings.base_ref_policies(),` into the `render/1`
   `assign(...)` block at lines 828-838, the same way line 833 already supplies
   `notification_preferences: Settings.notification_preferences(),`.
3. `docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md:84` (§4.6) — what
   was wrong: a guard clause with no `when`, which would not compile if copied
   verbatim. What changed: `defp validate(:base_ref_policy, value) when
   is_binary(value) do`.
4. `docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md:116` (§4.9 help
   text) — what was wrong: the help text promised the setting steers the PR base
   while §1 says no run code reads it, so an operator could set `checkout` and
   see no effect. What changed: the help string now reads "Registered only: no
   run code reads it yet (the sibling bead that consumes it is not in this
   task)." and §1's scope paragraph carries the same warning for the
   user-guide row §4.11 tells the implementer to add.

## Declined

None. Every finding was real against the file as it currently stands and each
had a narrow fix inside this run's own artifact.

## Verification

Changed files: `docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md` only
(this report is written by this phase and is not part of the reviewed diff). No
Elixir, Go, or config file was touched, so no `.ex`/`.exs` file was edited and
there is no code path of the application affected by this phase.

- `git diff main --stat` → exit 0: only `FIX_REPORT.md` (+1) and `PLAN.md`
  (+163).
- `grep -rn base_ref_policy packages/foreman_server/lib packages/foreman_server/test`
  → exit 1 (no matches): the reviewed diff contains no implementation, so no
  implementation test can be made to cover it.
- `cd packages/foreman_server && mix format --check-formatted` → exit 0 (CI's
  exact command, `.github/workflows/ci.yml:138`). No `.ex`/`.exs` file was
  edited by this phase, so the formatter gate is unchanged by it.
- `cd packages/foreman_server && MIX_ENV=test mix test
  test/foreman_server/workflow/review_findings_test.exs
  test/foreman_server/pr_risk_test.exs --warnings-as-errors` → **105 passed,
  0 failures** (seed 436389; the two files are `async: true` and need no
  database). The worktree had no `deps/` and no `_build/`, so the run first did
  `HEX_OFFLINE=1 MIX_ENV=test mix deps.get` (exit 0; `mix.lock` is byte-identical
  to `main`) against a freshly created test database
  `foreman_test_zv8bi_review` on 127.0.0.1:55432 (`mix event_store.init` →
  "The EventStore database has been initialized."). The full suite was
  deliberately not run: nothing outside a markdown artifact changed.
- Machine-read blocks re-parsed from this file with an absolute path
  (`MIX_ENV=test mix run --no-start -e …`):
  `ForemanServer.Workflow.ReviewFindings.read/1` → `{:recorded, findings: 4}`
  with every finding `severity: :minor`, `disposition: :fixed`,
  `source: "coderabbit"`; `ForemanServer.PrRisk.parse_judgement/1` →
  `%{status: "recorded", level: "LOW", defect: nil}`. (The parser also returns
  an `artifact_sha256` of this file; it is not quoted here because any value
  written into the file changes it.)
- The phase's edits are left uncommitted as instructed; Foreman commits this
  phase.

## Machine-read blocks

Both blocks below are the parser's input. The markers are written bare, each on
its own line, as the last thing in this file.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md", "line": 5, "description": "The phase-2 commit replaced the 215-line executable plan with a 20-line summary, so the plan path later phases read contained no plan.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md", "line": 113, "description": "The proposed HEEx referenced an undefined @base_ref_policy_id assign and never supplied the option list, so the settings page would raise undefined assign.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md", "line": 84, "description": "The validator clause omitted `when` before is_binary(value), so the snippet would not compile if copied into settings.ex.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md", "line": 116, "description": "The form help text promised the selection controls the PR base although no run code reads the key, letting an operator choose checkout and see no effect.", "disposition": "fixed", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "The run's diff against main is two markdown artifacts (PLAN.md +163, FIX_REPORT.md +1) and no production code, so nothing compilable, deployable or runtime-reachable changed. All four CodeRabbit findings were minor and every one was fixed inside the plan document; no finding was declined. Residual risk is that the bead's feature remains unimplemented and a later phase still has to write the eleven edits the plan describes."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
